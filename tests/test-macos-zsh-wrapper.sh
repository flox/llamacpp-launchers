#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LLAMACPP_BIN="$ROOT_DIR/bin/llamacpp"
ZSH_WRAPPER_FIXTURE="$ROOT_DIR/tests/fixtures/llamacpp-zsh-wrapper.zsh"
TEST_ROOT=""
ORIGINAL_PATH="$PATH"

fail() {
  echo "test failed: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" needle="$2"
  grep -F -- "$needle" "$file" >/dev/null || {
    echo "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "expected to find: $needle"
  }
}

setup_case() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp macos zsh.XXXXXX")
  export TEST_ROOT
  export FLOX_ENV_CACHE="$TEST_ROOT/cache with spaces"
  export TEST_LOG="$TEST_ROOT/commands.log"
  export MODEL_PATH="$TEST_ROOT/model dir/local model.gguf"
  export STUB_DIR="$TEST_ROOT/stubs"
  mkdir -p "$FLOX_ENV_CACHE" "$STUB_DIR" "$(dirname "$MODEL_PATH")"
  : > "$MODEL_PATH"
  : > "$TEST_LOG"

  cat > "$STUB_DIR/stat" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'stat %s\n' "$*" >> "${TEST_LOG:?}"
if [ "${1:-}" = "-c" ]; then
  exit 1
fi
if [ "${1:-}" = "-f" ] && [ "${2:-}" = "%m" ]; then
  if command -v /usr/bin/stat >/dev/null 2>&1; then
    /usr/bin/stat -c %Y "${3:?}"
  else
    printf '1\n'
  fi
  exit 0
fi
echo "unexpected stat invocation: $*" >&2
exit 64
STUB

  cat > "$STUB_DIR/flox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'flox %s\n' "$*" >> "${TEST_LOG:?}"
case "$*" in
  "services status llama-server") exit 0 ;;
  "services restart llama-server") exit 0 ;;
  "services start llama-server") exit 0 ;;
  "services status llamacpp-proxy") exit 1 ;;
  "services restart llamacpp-proxy") exit 0 ;;
  "services start llamacpp-proxy") exit 0 ;;
  *) exit 0 ;;
esac
STUB

  cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${TEST_LOG:?}"
for arg in "$@"; do
  case "$arg" in
    */health)
      exit 0
      ;;
    */v1/models)
      printf '{"data":[{"id":"%s"}]}' "${EXPECTED_MODEL_ID:?}"
      exit 0
      ;;
  esac
done
exit 0
STUB

  cat > "$STUB_DIR/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'CLAUDE_CALLED %s\n' "$*" >> "${TEST_LOG:?}"
exit 0
STUB

  chmod +x "$STUB_DIR/stat" "$STUB_DIR/flox" "$STUB_DIR/curl" "$STUB_DIR/sleep" "$STUB_DIR/claude"
  export PATH="$STUB_DIR:$ORIGINAL_PATH"
}

assert_no_gnu_readlink_f() {
  if awk '
    /^[[:space:]]*#/ { next }
    /readlink[[:space:]]+-f/ { print FILENAME ":" FNR ":" $0; found=1 }
    END { exit found ? 0 : 1 }
  ' "$LLAMACPP_BIN" >/tmp/llamacpp-readlink-f.$$; then
    cat /tmp/llamacpp-readlink-f.$$ >&2
    rm -f /tmp/llamacpp-readlink-f.$$
    fail "GNU-only readlink -f must not be required by executable launcher code"
  fi
  rm -f /tmp/llamacpp-readlink-f.$$
}

assert_zsh_wrapper_fixture() {
  head -n 1 "$ZSH_WRAPPER_FIXTURE" | grep -F '#!/usr/bin/env zsh' >/dev/null     || fail "zsh wrapper fixture must declare zsh"
  grep -F 'exec bash -c' "$ZSH_WRAPPER_FIXTURE" >/dev/null     || fail "zsh wrapper fixture must delegate launcher execution to bash"
}

seed_state_with_macos_stat_fallback() {
  (
    set -euo pipefail
    source "$LLAMACPP_BIN"
    resolved=$(__llamacpp_model_resolve "$MODEL_PATH")
    __llamacpp_write_model_state "$resolved"
    __llamacpp_write_env "127.0.0.1" "8080" "8192" "1" "llamacpp-local"
    __llamacpp_write_live_state "$resolved" "127.0.0.1" "8080" "8192" "1" "llamacpp-local" "$resolved"
    printf '%s' "$resolved" > "$TEST_ROOT/resolved.txt"
  )
}

run_from_bash_in_path_with_spaces() {
  export EXPECTED_MODEL_ID
  EXPECTED_MODEL_ID=$(cat "$TEST_ROOT/resolved.txt")
  out="$TEST_ROOT/bash wrapper out.txt"
  err="$TEST_ROOT/bash wrapper err.txt"
  (
    set -euo pipefail
    source "$LLAMACPP_BIN"
    llamacpp launch claude --model "$MODEL_PATH" --gpu-layers 1 --ctx-size 8192
  ) >"$out" 2>"$err"
  assert_contains "$out" "Launching claude with verified model"
  assert_contains "$TEST_LOG" "stat -f %m"
  assert_contains "$TEST_LOG" "CLAUDE_CALLED"
}

run_from_zsh_wrapper_if_available() {
  if ! command -v zsh >/dev/null 2>&1; then
    echo "ok - zsh not available; dynamic zsh wrapper branch skipped"
    return 0
  fi

  : > "$TEST_LOG"
  export EXPECTED_MODEL_ID
  EXPECTED_MODEL_ID=$(cat "$TEST_ROOT/resolved.txt")
  out="$TEST_ROOT/zsh wrapper out.txt"
  err="$TEST_ROOT/zsh wrapper err.txt"
  zsh "$ZSH_WRAPPER_FIXTURE" "$LLAMACPP_BIN" launch claude --model "$MODEL_PATH" --gpu-layers 1 --ctx-size 8192 >"$out" 2>"$err"
  assert_contains "$out" "Launching claude with verified model"
  assert_contains "$TEST_LOG" "stat -f %m"
  assert_contains "$TEST_LOG" "CLAUDE_CALLED"
}

assert_no_gnu_readlink_f
assert_zsh_wrapper_fixture
setup_case
seed_state_with_macos_stat_fallback
run_from_bash_in_path_with_spaces
run_from_zsh_wrapper_if_available

echo "ok - macOS path and zsh-wrapper compatibility tests passed"
