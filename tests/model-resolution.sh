#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$TEST_DIR/lib.sh"

# model set must update only the active model when server config already exists.
root_model_set_preserve=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-model-set-preserve.XXXXXX")
make_test_env "$root_model_set_preserve" old 9090
cat > "$root_model_set_preserve/cache/llama-server.env" <<ENVEOF
LLAMACPP_HOST='127.0.0.1'
LLAMACPP_PORT='9090'
LLAMACPP_CTX_SIZE='12345'
LLAMACPP_GPU_LAYERS='7'
LLAMACPP_API_KEY='old'
ENVEOF
chmod 600 "$root_model_set_preserve/cache/llama-server.env"
cp "$root_model_set_preserve/cache/llama-server.env" "$root_model_set_preserve/env.before"
run_model_set_path "$root_model_set_preserve"
assert_equals "$root_model_set_preserve/model.gguf" "$(cat "$root_model_set_preserve/cache/llama-server.model")" 'model set path state'
if ! cmp -s "$root_model_set_preserve/env.before" "$root_model_set_preserve/cache/llama-server.env"; then
  echo "model set rewrote existing llama-server.env" >&2
  exit 1
fi
assert_persisted_var "$root_model_set_preserve/cache/llama-server.env" LLAMACPP_PORT 9090
assert_persisted_var "$root_model_set_preserve/cache/llama-server.env" LLAMACPP_CTX_SIZE 12345
assert_persisted_var "$root_model_set_preserve/cache/llama-server.env" LLAMACPP_GPU_LAYERS 7
assert_persisted_var "$root_model_set_preserve/cache/llama-server.env" LLAMACPP_API_KEY old
assert_not_contains 'hf models ls' "$root_model_set_preserve/log"
assert_not_contains 'flox services' "$root_model_set_preserve/log"

# model set should create llama-server.env from defaults only for a fresh cache.
root_model_set_fresh=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-model-set-fresh.XXXXXX")
make_test_env "$root_model_set_fresh" old 9090
rm -f "$root_model_set_fresh/cache/llama-server.env"
run_model_set_path "$root_model_set_fresh"
assert_equals "$root_model_set_fresh/model.gguf" "$(cat "$root_model_set_fresh/cache/llama-server.model")" 'fresh model set path state'
assert_persisted_var "$root_model_set_fresh/cache/llama-server.env" LLAMACPP_PORT 8080
assert_persisted_var "$root_model_set_fresh/cache/llama-server.env" LLAMACPP_CTX_SIZE 65536
assert_persisted_var "$root_model_set_fresh/cache/llama-server.env" LLAMACPP_GPU_LAYERS 99
assert_persisted_var "$root_model_set_fresh/cache/llama-server.env" LLAMACPP_API_KEY llamacpp-local
assert_private_file "$root_model_set_fresh/cache/llama-server.env"
assert_no_env_temps "$root_model_set_fresh/cache"

# Relative local model specs must be canonicalized before persistence so service
# restarts from another working directory still load the intended file.
root_model_set_relative=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-model-set-relative.XXXXXX")
make_test_env "$root_model_set_relative" old 9090
mkdir -p "$root_model_set_relative/project/models"
: > "$root_model_set_relative/project/models/foo.gguf"
run_model_set_relative_path "$root_model_set_relative" "models/foo.gguf" "$root_model_set_relative/project"
expected_relative_model=$(cd "$root_model_set_relative/project/models" && printf '%s/foo.gguf' "$(pwd -P)")
assert_equals "$expected_relative_model" "$(cat "$root_model_set_relative/cache/llama-server.model")" 'relative model set canonicalizes path'
assert_not_contains 'hf models ls' "$root_model_set_relative/log"

# Relative launch model specs must also persist and verify the absolute path.
root_launch_relative=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-launch-relative.XXXXXX")
make_test_env "$root_launch_relative" old 9090
mkdir -p "$root_launch_relative/project/models"
: > "$root_launch_relative/project/models/foo.gguf"
expected_launch_relative=$(cd "$root_launch_relative/project/models" && printf '%s/foo.gguf' "$(pwd -P)")
(
  cd "$root_launch_relative/project"
  PATH="$root_launch_relative/bin:$ORIG_PATH" \
  TEST_LOG="$root_launch_relative/log" \
  FLOX_ENV_CACHE="$root_launch_relative/cache" \
  HOME="$root_launch_relative/home" \
  XDG_CONFIG_HOME="$root_launch_relative/config" \
  MODEL="$expected_launch_relative" \
  TEST_SERVER_MODEL="$expected_launch_relative" \
  SCRIPT="$SCRIPT" \
  LLAMACPP_PROXY_PORT=8081 \
  bash -c 'source "$SCRIPT"; llamacpp launch claude --model models/foo.gguf'
)
assert_equals "$expected_launch_relative" "$(cat "$root_launch_relative/cache/llama-server.model")" 'relative launch canonicalizes model state'
assert_persisted_var "$root_launch_relative/cache/llama-server.live.env" LLAMACPP_LIVE_MODEL "$expected_launch_relative"
assert_contains "claude ANTHROPIC_API_KEY=old" "$root_launch_relative/log"
# Search-term model specs should lock to the first resolved repo:quant so repeated
# workflows do not drift when Hugging Face search ordering changes.
root_lock=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-lock.XXXXXX")
make_test_env "$root_lock" old 8080
run_model_search_query "$root_lock" qwen3-coder unsloth/SearchOnly-GGUF
assert_contains 'hf models ls --search qwen3-coder GGUF' "$root_lock/log"
if [ -d "$root_lock/cache/model-locks" ] && find "$root_lock/cache/model-locks" -type f -name 'search-*.env' | grep -q .; then
  echo "model search should not create search locks" >&2
  find "$root_lock/cache/model-locks" -type f -print >&2
  exit 1
fi

run_model_set_query "$root_lock" qwen3-coder unsloth/First-GGUF
assert_contains 'hf models ls --search qwen3-coder GGUF' "$root_lock/log"
assert_equals 'unsloth/First-GGUF:Q4_K_M' "$(cat "$root_lock/cache/llama-server.model")" 'initial model lock resolution'
lock_file=$(first_model_lock_file "$root_lock/cache")
if [ -z "$lock_file" ]; then
  echo "expected model search lock file" >&2
  exit 1
fi
assert_private_file "$lock_file"
assert_no_model_lock_temps "$root_lock/cache"
assert_equals qwen3-coder "$(read_lock_var "$lock_file" LLAMACPP_MODEL_QUERY)" 'locked query'
assert_equals Q4_K_M "$(read_lock_var "$lock_file" LLAMACPP_MODEL_QUANT)" 'locked quant'
assert_equals 'unsloth/First-GGUF:Q4_K_M' "$(read_lock_var "$lock_file" LLAMACPP_RESOLVED_MODEL)" 'locked model'

run_model_set_query "$root_lock" qwen3-coder unsloth/Second-GGUF
assert_not_contains 'hf models ls' "$root_lock/log"
assert_equals 'unsloth/First-GGUF:Q4_K_M' "$(cat "$root_lock/cache/llama-server.model")" 'locked model reuse'

run_model_pin_query "$root_lock" qwen3-coder unsloth/Second-GGUF
assert_contains 'hf models ls --search qwen3-coder GGUF' "$root_lock/log"
lock_file=$(first_model_lock_file "$root_lock/cache")
assert_equals 'unsloth/Second-GGUF:Q4_K_M' "$(read_lock_var "$lock_file" LLAMACPP_RESOLVED_MODEL)" 'repinned model'

run_model_set_query "$root_lock" qwen3-coder unsloth/Third-GGUF
assert_not_contains 'hf models ls' "$root_lock/log"
assert_equals 'unsloth/Second-GGUF:Q4_K_M' "$(cat "$root_lock/cache/llama-server.model")" 'repinned model reuse'


# Quant validation should cover every path that can persist a quant, not just
# model pull. Glob-like quant strings must fail before HF lookup or lock writes.
root_pin_quant=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-pin-quant.XXXXXX")
make_test_env "$root_pin_quant" old 8080
run_model_pin_expect_failure "$root_pin_quant" q 'Q4[KM]' 'quant may contain only letters'
assert_not_contains 'hf models ls' "$root_pin_quant/log"
if [ -d "$root_pin_quant/cache/model-locks" ] && find "$root_pin_quant/cache/model-locks" -type f -name 'search-*.env' | grep -q .; then
  echo "model pin wrote a lock for an invalid quant" >&2
  find "$root_pin_quant/cache/model-locks" -type f -print >&2
  exit 1
fi

root_resolve_quant=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-resolve-quant.XXXXXX")
make_test_env "$root_resolve_quant" old 8080
printf '%s' "$root_resolve_quant/model.gguf" > "$root_resolve_quant/model.before"
run_model_set_expect_failure "$root_resolve_quant" 'unsloth/R-GGUF:Q4[KM]' 'quant may contain only letters'
assert_not_contains 'hf models ls' "$root_resolve_quant/log"
assert_equals "$(cat "$root_resolve_quant/model.before")" "$(cat "$root_resolve_quant/cache/llama-server.model")" 'invalid repo-spec quant model state'


# Model pull should request only GGUF files whose filename includes the selected
# quant as a filename token, and quant strings must not be able to widen the HF
# include filter with glob syntax.
root_pull=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-pull.XXXXXX")
make_test_env "$root_pull" old 8080
run_model_pull_spec "$root_pull" 'unsloth/Repo-GGUF:Q4_K_M'
assert_contains 'hf download unsloth/Repo-GGUF --include \*-Q4_K_M\.gguf' "$root_pull/log"
assert_contains '--include \*-Q4_K_M-\*\.gguf' "$root_pull/log"
assert_contains '--include \*_Q4_K_M\.gguf' "$root_pull/log"
assert_not_contains '--include \*Q4_K_M\* --local-dir' "$root_pull/log"
assert_not_contains '--include \*Q4_K_M\*' "$root_pull/log"

if run_model_pull_spec "$root_pull" 'unsloth/Repo-GGUF:Q4[KM]'; then
  echo "model pull accepted a glob-like quant" >&2
  exit 1
fi
assert_not_contains 'hf download' "$root_pull/log"

root_pull_repo=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-pull-repo.XXXXXX")
make_test_env "$root_pull_repo" old 8080
run_model_pull_expect_failure "$root_pull_repo" '--help' "repo id must not start with '-'"
assert_not_contains 'hf download' "$root_pull_repo/log"
run_model_pull_expect_failure "$root_pull_repo" 'unsloth/Repo/Extra:Q4_K_M' 'repo id must have simple org/repo shape'
assert_not_contains 'hf download' "$root_pull_repo/log"
run_model_pull_expect_failure "$root_pull_repo" 'unsloth/-Repo:Q4_K_M' 'invalid repo name in repo id'
assert_not_contains 'hf download' "$root_pull_repo/log"

root_resolve_repo=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-resolve-repo.XXXXXX")
make_test_env "$root_resolve_repo" old 8080
printf '%s' "$root_resolve_repo/model.gguf" > "$root_resolve_repo/model.before"
run_model_set_expect_failure "$root_resolve_repo" 'unsloth/Repo/Extra:Q4_K_M' 'repo id must have simple org/repo shape'
assert_not_contains 'hf models ls' "$root_resolve_repo/log"
assert_equals "$(cat "$root_resolve_repo/model.before")" "$(cat "$root_resolve_repo/cache/llama-server.model")" 'invalid repo id model state'

printf 'model-resolution tests passed\n'
exit 0
