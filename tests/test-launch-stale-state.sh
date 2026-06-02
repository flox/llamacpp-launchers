#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LLAMACPP_BIN="$ROOT_DIR/bin/llamacpp"
TEST_ROOT=""

fail() {
  echo "test failed: $*" >&2
  exit 1
}

assert_file_absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected absent: $1"
}

assert_file_present() {
  [ -e "$1" ] || fail "expected present: $1"
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
  unset CURL_HEALTH_SEQUENCE CURL_HEALTH_RC CURL_MODELS_RC \
    FLOX_STATUS_RC FLOX_RESTART_RC FLOX_START_RC FLOX_PROXY_RESTART_RC FLOX_PROXY_START_RC \
    CLAUDE_RC
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-launch-test.XXXXXX")
  export TEST_ROOT
  export FLOX_ENV_CACHE="$TEST_ROOT/cache"
  export TEST_LOG="$TEST_ROOT/commands.log"
  export MODEL_PATH="$TEST_ROOT/model.gguf"
  export STUB_DIR="$TEST_ROOT/stubs"
  mkdir -p "$FLOX_ENV_CACHE" "$STUB_DIR"
  : > "$MODEL_PATH"
  : > "$TEST_LOG"

  cat > "$STUB_DIR/flox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'flox %s\n' "$*" >> "${TEST_LOG:?}"
case "$*" in
  "services status llama-server") exit "${FLOX_STATUS_RC:-0}" ;;
  "services restart llama-server") exit "${FLOX_RESTART_RC:-0}" ;;
  "services start llama-server") exit "${FLOX_START_RC:-0}" ;;
  "services status llamacpp-proxy") exit 1 ;;
  "services restart llamacpp-proxy") exit "${FLOX_PROXY_RESTART_RC:-0}" ;;
  "services start llamacpp-proxy") exit "${FLOX_PROXY_START_RC:-0}" ;;
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
      if [ -n "${CURL_HEALTH_SEQUENCE:-}" ]; then
        state_file="${TEST_ROOT:?}/curl-health-count"
        count=0
        [ -f "$state_file" ] && count=$(cat "$state_file")
        next=$((count + 1))
        printf '%s' "$next" > "$state_file"
        IFS=',' read -r -a health_rcs <<< "$CURL_HEALTH_SEQUENCE"
        idx=$count
        if [ "$idx" -ge "${#health_rcs[@]}" ]; then
          idx=$((${#health_rcs[@]} - 1))
        fi
        rc="${health_rcs[$idx]}"
        exit "$rc"
      fi
      exit "${CURL_HEALTH_RC:-0}"
      ;;
    */v1/models)
      rc="${CURL_MODELS_RC:-0}"
      [ "$rc" -eq 0 ] || exit "$rc"
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
exit "${CLAUDE_RC:-0}"
STUB

  chmod +x "$STUB_DIR/flox" "$STUB_DIR/curl" "$STUB_DIR/sleep" "$STUB_DIR/claude"
  export PATH="$STUB_DIR:$PATH"
}

seed_matching_state() {
  local ctx_size="${1:-131072}" gpu_layers="${2:-99}"
  (
    set -euo pipefail
    source "$LLAMACPP_BIN"
    resolved=$(__llamacpp_model_resolve "$MODEL_PATH")
    __llamacpp_write_model_state "$resolved"
    __llamacpp_write_env "127.0.0.1" "8080" "$ctx_size" "$gpu_layers" "llamacpp-local"
    __llamacpp_write_live_state "$resolved" "127.0.0.1" "8080" "$ctx_size" "$gpu_layers" "llamacpp-local" "$resolved"
    mkdir -p "$FLOX_ENV_CACHE/model-locks" "$FLOX_ENV_CACHE/models"
    printf 'lock\n' > "$FLOX_ENV_CACHE/model-locks/search-keep.env"
    printf 'model-cache\n' > "$FLOX_ENV_CACHE/models/keep.gguf"
    printf 'proxy\n' > "$FLOX_ENV_CACHE/llamacpp-proxy.state"
    printf '%s' "$resolved" > "$TEST_ROOT/resolved.txt"
  )
}

run_launch() {
  local out="$1" err="$2"
  set +e
  (
    set -euo pipefail
    source "$LLAMACPP_BIN"
    llamacpp launch claude --model "$MODEL_PATH" --gpu-layers 99 --ctx-size 131072
  ) >"$out" 2>"$err"
  rc=$?
  set -e
  return "$rc"
}

test_failed_health_invalidates_stale_state() {
  setup_case
  seed_matching_state
  export EXPECTED_MODEL_ID
  EXPECTED_MODEL_ID=$(cat "$TEST_ROOT/resolved.txt")
  export CURL_HEALTH_RC=22 FLOX_STATUS_RC=0 FLOX_RESTART_RC=0

  out="$TEST_ROOT/out.txt"
  err="$TEST_ROOT/err.txt"
  if run_launch "$out" "$err"; then
    fail "launch succeeded despite failing health checks"
  fi

  assert_contains "$err" "health check timed out after service restart"
  assert_contains "$err" "Attempted config:"
  assert_contains "$err" "ctx-size=131072"
  assert_contains "$err" "gpu-layers=99"
  assert_contains "$err" "Preserved downloaded GGUFs and model-search locks."
  assert_contains "$TEST_LOG" "flox services restart llama-server"

  assert_file_absent "$FLOX_ENV_CACHE/llama-server.env"
  assert_file_absent "$FLOX_ENV_CACHE/llama-server.model"
  assert_file_absent "$FLOX_ENV_CACHE/llama-server.live.env"
  assert_file_absent "$FLOX_ENV_CACHE/llamacpp-proxy.state"
  assert_file_present "$FLOX_ENV_CACHE/model-locks/search-keep.env"
  assert_file_present "$FLOX_ENV_CACHE/models/keep.gguf"
}

test_restart_failure_invalidates_stale_state() {
  setup_case
  seed_matching_state
  export EXPECTED_MODEL_ID
  EXPECTED_MODEL_ID=$(cat "$TEST_ROOT/resolved.txt")
  export CURL_HEALTH_RC=22 FLOX_STATUS_RC=0 FLOX_RESTART_RC=1

  out="$TEST_ROOT/out.txt"
  err="$TEST_ROOT/err.txt"
  if run_launch "$out" "$err"; then
    fail "launch succeeded despite restart failure"
  fi

  assert_contains "$err" "service restart command failed"
  assert_contains "$err" "for OOM: lower --ctx-size"
  assert_file_absent "$FLOX_ENV_CACHE/llama-server.env"
  assert_file_absent "$FLOX_ENV_CACHE/llama-server.model"
  assert_file_absent "$FLOX_ENV_CACHE/llama-server.live.env"
  assert_file_present "$FLOX_ENV_CACHE/model-locks/search-keep.env"
  assert_file_present "$FLOX_ENV_CACHE/models/keep.gguf"
}

test_healthy_matching_state_launches_without_restart() {
  setup_case
  seed_matching_state
  export EXPECTED_MODEL_ID
  EXPECTED_MODEL_ID=$(cat "$TEST_ROOT/resolved.txt")
  export CURL_HEALTH_RC=0 FLOX_STATUS_RC=0 FLOX_RESTART_RC=0

  out="$TEST_ROOT/out.txt"
  err="$TEST_ROOT/err.txt"
  run_launch "$out" "$err" || {
    cat "$out" >&2 || true
    cat "$err" >&2 || true
    fail "healthy launch failed"
  }

  assert_contains "$out" "Launching claude with verified model"
  assert_contains "$TEST_LOG" "CLAUDE_CALLED"
  if grep -F "flox services restart llama-server" "$TEST_LOG" >/dev/null; then
    fail "unexpected llama-server restart on healthy matching state"
  fi
  assert_file_present "$FLOX_ENV_CACHE/llama-server.env"
  assert_file_present "$FLOX_ENV_CACHE/llama-server.model"
  assert_file_present "$FLOX_ENV_CACHE/llama-server.live.env"
}

test_harness_failure_gets_launcher_owned_diagnostic() {
  setup_case
  seed_matching_state
  export EXPECTED_MODEL_ID
  EXPECTED_MODEL_ID=$(cat "$TEST_ROOT/resolved.txt")
  export CURL_HEALTH_RC=0 FLOX_STATUS_RC=0 CLAUDE_RC=73

  out="$TEST_ROOT/out.txt"
  err="$TEST_ROOT/err.txt"
  set +e
  (
    set -euo pipefail
    source "$LLAMACPP_BIN"
    llamacpp launch claude --model "$MODEL_PATH" --gpu-layers 99 --ctx-size 131072
  ) >"$out" 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "launch succeeded despite failing harness"
  [ "$rc" -eq 73 ] || fail "expected harness exit 73, got $rc"

  assert_contains "$out" "Launching claude with verified model"
  assert_contains "$err" "Error: harness 'claude' exited with status 73 after server readiness passed."
  assert_contains "$err" "Harness command: __llamacpp_configure_claude"
  assert_contains "$err" "Server: http://127.0.0.1:8080/v1"
  assert_contains "$err" "Model: $EXPECTED_MODEL_ID"
  assert_contains "$TEST_LOG" "CLAUDE_CALLED"
  if grep -F "flox services restart llama-server" "$TEST_LOG" >/dev/null; then
    fail "unexpected llama-server restart on harness failure path"
  fi
}

test_unhealthy_matching_state_restart_success_launches_harness() {
  setup_case
  seed_matching_state
  export EXPECTED_MODEL_ID
  EXPECTED_MODEL_ID=$(cat "$TEST_ROOT/resolved.txt")
  export CURL_HEALTH_SEQUENCE=22,0 FLOX_STATUS_RC=0 FLOX_RESTART_RC=0

  out="$TEST_ROOT/out.txt"
  err="$TEST_ROOT/err.txt"
  run_launch "$out" "$err" || {
    cat "$out" >&2 || true
    cat "$err" >&2 || true
    fail "restart recovery launch failed"
  }

  assert_contains "$out" "Starting llama-server (server health check failed before harness launch)"
  assert_contains "$out" "Server ready."
  assert_contains "$out" "Launching claude with verified model"
  assert_contains "$TEST_LOG" "flox services restart llama-server"
  assert_contains "$TEST_LOG" "CLAUDE_CALLED"

  assert_file_present "$FLOX_ENV_CACHE/llama-server.env"
  assert_file_present "$FLOX_ENV_CACHE/llama-server.model"
  assert_file_present "$FLOX_ENV_CACHE/llama-server.live.env"
  assert_file_present "$FLOX_ENV_CACHE/model-locks/search-keep.env"
  assert_file_present "$FLOX_ENV_CACHE/models/keep.gguf"
  assert_file_present "$FLOX_ENV_CACHE/llamacpp-proxy.state"
}

test_failed_start_invalidates_stale_state() {
  setup_case
  seed_matching_state
  export EXPECTED_MODEL_ID
  EXPECTED_MODEL_ID=$(cat "$TEST_ROOT/resolved.txt")
  export CURL_HEALTH_RC=22 FLOX_STATUS_RC=1 FLOX_START_RC=1

  out="$TEST_ROOT/out.txt"
  err="$TEST_ROOT/err.txt"
  if run_launch "$out" "$err"; then
    fail "launch succeeded despite start failure"
  fi

  assert_contains "$err" "service start command failed"
  assert_contains "$TEST_LOG" "flox services start llama-server"
  assert_file_absent "$FLOX_ENV_CACHE/llama-server.env"
  assert_file_absent "$FLOX_ENV_CACHE/llama-server.model"
  assert_file_absent "$FLOX_ENV_CACHE/llama-server.live.env"
}

test_failed_health_invalidates_stale_state
test_restart_failure_invalidates_stale_state
test_healthy_matching_state_launches_without_restart
test_harness_failure_gets_launcher_owned_diagnostic
test_unhealthy_matching_state_restart_success_launches_harness
test_failed_start_invalidates_stale_state

echo "ok - stale-state launch recovery tests passed"
