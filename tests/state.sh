#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$TEST_DIR/lib.sh"

assert_help_lists_all_harnesses() {
  local root="$1"
  local bin="$root/bin"
  local expected="Harnesses: claude, codex, opencode, aider, crush, deepseek, gemini"
  local help_file="$root/help"
  local unknown_file="$root/unknown"
  local unknown_status=0

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$root/cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  bash -c 'source "$SCRIPT"; llamacpp help' > "$help_file"
  assert_contains "$expected" "$help_file"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$root/cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  bash -c 'source "$SCRIPT"; llamacpp launch not-a-harness --model "$1"' _ "$root/model.gguf" > "$unknown_file" 2>&1 || unknown_status=$?
  if [ "$unknown_status" -eq 0 ]; then
    echo "unknown harness unexpectedly succeeded" >&2
    exit 1
  fi
  assert_contains "Supported: claude, codex, opencode, aider, crush, deepseek, gemini" "$unknown_file"
}

# Help and error text must list every supported harness.
root_help=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-help.XXXXXX")
make_test_env "$root_help" old 8080
assert_help_lists_all_harnesses "$root_help"

# API-key change must restart llama-server even when /health succeeds without auth.
root_api=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-api.XXXXXX")
make_test_env "$root_api" old 8080
run_launch "$root_api" claude new 8080
assert_contains 'flox services restart llama-server' "$root_api/log"
assert_not_contains '^sleep 4$' "$root_api/log"
assert_contains 'flox services restart llamacpp-proxy' "$root_api/log"
assert_contains 'claude ANTHROPIC_API_KEY=new' "$root_api/log"
assert_persisted_var "$root_api/cache/llama-server.env" LLAMACPP_API_KEY new
assert_persisted_var "$root_api/cache/llamacpp-proxy.state" LLAMACPP_PROXY_BACKEND_API_KEY new
assert_persisted_var "$root_api/cache/llama-server.live.env" LLAMACPP_LIVE_API_KEY new
assert_private_file "$root_api/cache/llama-server.live.env"
assert_private_file "$root_api/cache/llamacpp-proxy.state"
assert_no_proxy_state_temps "$root_api/cache"

# llama-server restart/start failures must abort before health polling or harness launch.
root_restart_fail=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-restart-fail.XXXXXX")
make_test_env "$root_restart_fail" old 8080
run_launch_service_failure "$root_restart_fail" restart
assert_contains 'flox services restart llama-server' "$root_restart_fail/log"
# initial health probe is expected before restart; assert no harness launch
assert_not_contains '^claude ' "$root_restart_fail/log"
assert_not_contains 'flox services restart llamacpp-proxy' "$root_restart_fail/log"
# stale-state fix invalidates server state on restart failure
if [ -e "$root_restart_fail/cache/llama-server.env" ]; then
  echo "llama-server.env should have been invalidated after restart failure" >&2
  exit 1
fi
if [ -e "$root_restart_fail/cache/llama-server.live.env" ]; then
  echo "live.env should have been invalidated after restart failure" >&2
  exit 1
fi

# A failed restart may commit desired inputs, but it must not mark them live. The
# next identical launch must restart instead of trusting desired state plus /health.
run_launch "$root_restart_fail" claude new 8080
assert_contains 'flox services restart llama-server' "$root_restart_fail/log"
assert_contains 'claude ANTHROPIC_API_KEY=new' "$root_restart_fail/log"
assert_persisted_var "$root_restart_fail/cache/llama-server.live.env" LLAMACPP_LIVE_API_KEY new
assert_private_file "$root_restart_fail/cache/llama-server.live.env"
assert_no_live_state_temps "$root_restart_fail/cache"

root_start_fail=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-start-fail.XXXXXX")
make_test_env "$root_start_fail" old 8080
run_launch_service_failure "$root_start_fail" start
assert_contains 'flox services status llama-server' "$root_start_fail/log"
assert_contains 'flox services start llama-server' "$root_start_fail/log"
# initial health probe may appear before start attempt; assert no harness launch
assert_not_contains '^claude ' "$root_start_fail/log"
assert_not_contains 'flox services restart llamacpp-proxy' "$root_start_fail/log"
# stale-state fix invalidates live.env on start failure
if [ -e "$root_start_fail/cache/llama-server.live.env" ]; then
  echo "live.env should have been invalidated after start failure" >&2
  exit 1
fi

# Unchanged backend config plus a healthy server should not restart services.
root_same=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-same.XXXXXX")
make_test_env "$root_same" same 8080
run_launch "$root_same" claude same 8080
assert_not_contains 'flox services restart llama-server' "$root_same/log"
assert_not_contains 'flox services restart llamacpp-proxy' "$root_same/log"
assert_contains 'claude ANTHROPIC_API_KEY=same' "$root_same/log"
assert_contains "claude .* --model $root_same/model.gguf" "$root_same/log"

# A healthy proxy with a stale backend marker must restart before a proxy harness reuses it.
root_stale_proxy=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-stale-proxy.XXXXXX")
make_test_env "$root_stale_proxy" current 8080
cat > "$root_stale_proxy/cache/llamacpp-proxy.state" <<STATEEOF
LLAMACPP_PROXY_HOST=127.0.0.1
LLAMACPP_PROXY_PORT=8081
LLAMACPP_PROXY_BACKEND_HOST=127.0.0.1
LLAMACPP_PROXY_BACKEND_PORT=7777
LLAMACPP_PROXY_BACKEND_API_KEY=stale
STATEEOF
chmod 600 "$root_stale_proxy/cache/llamacpp-proxy.state"
run_launch "$root_stale_proxy" claude current 8080
assert_not_contains 'flox services restart llama-server' "$root_stale_proxy/log"
assert_contains 'flox services restart llamacpp-proxy' "$root_stale_proxy/log"
assert_persisted_var "$root_stale_proxy/cache/llamacpp-proxy.state" LLAMACPP_PROXY_BACKEND_PORT 8080
assert_persisted_var "$root_stale_proxy/cache/llamacpp-proxy.state" LLAMACPP_PROXY_BACKEND_API_KEY current
assert_private_file "$root_stale_proxy/cache/llamacpp-proxy.state"
assert_no_proxy_state_temps "$root_stale_proxy/cache"

# A launch with no server flags must preserve persisted config instead of rewriting defaults.
root_persist=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-persist.XXXXXX")
make_test_env "$root_persist" old 9090
cat > "$root_persist/cache/llama-server.env" <<ENVEOF
LLAMACPP_HOST=127.0.0.1
LLAMACPP_PORT=9090
LLAMACPP_CTX_SIZE=12345
LLAMACPP_GPU_LAYERS=7
LLAMACPP_API_KEY=old
ENVEOF
cat > "$root_persist/cache/llama-server.live.env" <<LIVEEOF
LLAMACPP_LIVE_MODEL='$root_persist/model.gguf'
LLAMACPP_LIVE_HOST='127.0.0.1'
LLAMACPP_LIVE_PORT='9090'
LLAMACPP_LIVE_CTX_SIZE='12345'
LLAMACPP_LIVE_GPU_LAYERS='7'
LLAMACPP_LIVE_API_KEY='old'
LLAMACPP_LIVE_SERVER_MODEL='$root_persist/model.gguf'
LLAMACPP_LIVE_VERIFIED_AT='test'
LIVEEOF
chmod 600 "$root_persist/cache/llama-server.live.env"
run_launch_no_server_flags "$root_persist" claude
assert_persisted_var "$root_persist/cache/llama-server.env" LLAMACPP_PORT 9090
assert_persisted_var "$root_persist/cache/llama-server.env" LLAMACPP_CTX_SIZE 12345
assert_persisted_var "$root_persist/cache/llama-server.env" LLAMACPP_GPU_LAYERS 7
assert_persisted_var "$root_persist/cache/llama-server.env" LLAMACPP_API_KEY old
assert_contains 'claude ANTHROPIC_API_KEY=old' "$root_persist/log"
assert_not_contains 'vram-optimizer' "$root_persist/log"
assert_not_contains 'flox services restart llama-server' "$root_persist/log"

# Invalid launch numeric options must fail before writing persisted state or touching services.
root_invalid_port=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-invalid-port.XXXXXX")
make_test_env "$root_invalid_port" old 9090
cp "$root_invalid_port/cache/llama-server.env" "$root_invalid_port/env.before"
printf '%s' "$root_invalid_port/model.gguf" > "$root_invalid_port/model.before"
run_launch_expect_failure "$root_invalid_port" claude '--port must be a non-negative integer: notaport' --port notaport --ctx-size nope --gpu-layers -4
cmp -s "$root_invalid_port/env.before" "$root_invalid_port/cache/llama-server.env" || { echo "invalid --port rewrote llama-server.env" >&2; exit 1; }
assert_equals "$(cat "$root_invalid_port/model.before")" "$(cat "$root_invalid_port/cache/llama-server.model")" 'invalid --port model state'
assert_not_contains 'flox services' "$root_invalid_port/log"
assert_not_contains 'hf models ls' "$root_invalid_port/log"

root_invalid_ctx=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-invalid-ctx.XXXXXX")
make_test_env "$root_invalid_ctx" old 9090
cp "$root_invalid_ctx/cache/llama-server.env" "$root_invalid_ctx/env.before"
run_launch_expect_failure "$root_invalid_ctx" claude '--ctx-size must be a non-negative integer: nope' --port 8080 --ctx-size nope --gpu-layers 4
cmp -s "$root_invalid_ctx/env.before" "$root_invalid_ctx/cache/llama-server.env" || { echo "invalid --ctx-size rewrote llama-server.env" >&2; exit 1; }
assert_not_contains 'flox services' "$root_invalid_ctx/log"

root_invalid_ctx_zero=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-invalid-ctx-zero.XXXXXX")
make_test_env "$root_invalid_ctx_zero" old 9090
cp "$root_invalid_ctx_zero/cache/llama-server.env" "$root_invalid_ctx_zero/env.before"
run_launch_expect_failure "$root_invalid_ctx_zero" claude '--ctx-size must be greater than 0: 0' --port 8080 --ctx-size 0 --gpu-layers 0
cmp -s "$root_invalid_ctx_zero/env.before" "$root_invalid_ctx_zero/cache/llama-server.env" || { echo "zero --ctx-size rewrote llama-server.env" >&2; exit 1; }
assert_not_contains 'flox services' "$root_invalid_ctx_zero/log"

root_valid_gpu_zero=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-valid-gpu-zero.XXXXXX")
make_test_env "$root_valid_gpu_zero" old 9090
run_launch "$root_valid_gpu_zero" claude same 8080
PATH="$root_valid_gpu_zero/bin:$ORIG_PATH" TEST_LOG="$root_valid_gpu_zero/log" FLOX_ENV_CACHE="$root_valid_gpu_zero/cache" HOME="$root_valid_gpu_zero/home" XDG_CONFIG_HOME="$root_valid_gpu_zero/config" MODEL="$root_valid_gpu_zero/model.gguf" TEST_SERVER_MODEL="$root_valid_gpu_zero/model.gguf" SCRIPT="$SCRIPT" LLAMACPP_PROXY_PORT=8081 bash -c 'source "$SCRIPT"; llamacpp launch claude --model "$MODEL" --port 8080 --ctx-size 2048 --gpu-layers 0 --api-key same'
assert_persisted_var "$root_valid_gpu_zero/cache/llama-server.env" LLAMACPP_CTX_SIZE 2048
assert_persisted_var "$root_valid_gpu_zero/cache/llama-server.env" LLAMACPP_GPU_LAYERS 0

root_invalid_gpu=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-invalid-gpu.XXXXXX")
make_test_env "$root_invalid_gpu" old 9090
cp "$root_invalid_gpu/cache/llama-server.env" "$root_invalid_gpu/env.before"
run_launch_expect_failure "$root_invalid_gpu" claude '--gpu-layers must be a non-negative integer: -4' --port 8080 --ctx-size 2048 --gpu-layers -4
cmp -s "$root_invalid_gpu/env.before" "$root_invalid_gpu/cache/llama-server.env" || { echo "invalid --gpu-layers rewrote llama-server.env" >&2; exit 1; }
assert_not_contains 'flox services' "$root_invalid_gpu/log"

root_invalid_port_range=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-invalid-port-range.XXXXXX")
make_test_env "$root_invalid_port_range" old 9090
cp "$root_invalid_port_range/cache/llama-server.env" "$root_invalid_port_range/env.before"
run_launch_expect_failure "$root_invalid_port_range" claude '--port must be between 1 and 65535: 65536' --port 65536 --ctx-size 2048 --gpu-layers 4
cmp -s "$root_invalid_port_range/env.before" "$root_invalid_port_range/cache/llama-server.env" || { echo "out-of-range --port rewrote llama-server.env" >&2; exit 1; }
assert_not_contains 'flox services' "$root_invalid_port_range/log"

root_invalid_persisted=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-invalid-persisted.XXXXXX")
make_test_env "$root_invalid_persisted" old 9090
cat > "$root_invalid_persisted/cache/llama-server.env" <<ENVEOF
LLAMACPP_HOST=127.0.0.1
LLAMACPP_PORT=notaport
LLAMACPP_CTX_SIZE=12345
LLAMACPP_GPU_LAYERS=7
LLAMACPP_API_KEY=old
ENVEOF
cp "$root_invalid_persisted/cache/llama-server.env" "$root_invalid_persisted/env.before"
run_launch_expect_failure "$root_invalid_persisted" claude '--port must be a non-negative integer: notaport'
cmp -s "$root_invalid_persisted/env.before" "$root_invalid_persisted/cache/llama-server.env" || { echo "invalid persisted numeric config was rewritten" >&2; exit 1; }
assert_not_contains 'flox services' "$root_invalid_persisted/log"

# Unknown launch options before -- must fail fast instead of passing typos to
# the harness. Harness flags remain supported after --.
root_unknown_launch_opt=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-unknown-launch-opt.XXXXXX")
make_test_env "$root_unknown_launch_opt" old 9090
cp "$root_unknown_launch_opt/cache/llama-server.env" "$root_unknown_launch_opt/env.before"
run_launch_expect_failure "$root_unknown_launch_opt" claude 'Unknown launch option: --prt' --prt 9090
assert_contains 'Pass harness flags after --' "$root_unknown_launch_opt/invalid.out"
cmp -s "$root_unknown_launch_opt/env.before" "$root_unknown_launch_opt/cache/llama-server.env" || { echo "unknown launch option rewrote llama-server.env" >&2; exit 1; }
assert_not_contains 'flox services' "$root_unknown_launch_opt/log"
assert_not_contains '^claude ' "$root_unknown_launch_opt/log"

root_unknown_launch_short_opt=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-unknown-launch-short-opt.XXXXXX")
make_test_env "$root_unknown_launch_short_opt" old 9090
cp "$root_unknown_launch_short_opt/cache/llama-server.env" "$root_unknown_launch_short_opt/env.before"
run_launch_expect_failure "$root_unknown_launch_short_opt" claude 'Unknown launch option: -p' -p 9090
assert_contains 'Pass harness flags after --' "$root_unknown_launch_short_opt/invalid.out"
cmp -s "$root_unknown_launch_short_opt/env.before" "$root_unknown_launch_short_opt/cache/llama-server.env" || { echo "unknown short launch option rewrote llama-server.env" >&2; exit 1; }
assert_not_contains 'flox services' "$root_unknown_launch_short_opt/log"
assert_not_contains '^claude ' "$root_unknown_launch_short_opt/log"

root_harness_flags=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-harness-flags.XXXXXX")
make_test_env "$root_harness_flags" old 9090
run_launch_with_harness_args_after_delimiter "$root_harness_flags" claude --prt 9090
assert_contains 'claude .* --prt 9090' "$root_harness_flags/log"

root_harness_short_flags=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-harness-short-flags.XXXXXX")
make_test_env "$root_harness_short_flags" old 9090
run_launch_with_harness_args_after_delimiter "$root_harness_short_flags" claude -p 9090
assert_contains 'claude .* -p 9090' "$root_harness_short_flags/log"

# Activation-time env vars intentionally override persisted config when no CLI flags are passed.
root_activation=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-activation.XXXXXX")
make_test_env "$root_activation" old 9090
cat > "$root_activation/cache/llama-server.env" <<ENVEOF
LLAMACPP_HOST=127.0.0.1
LLAMACPP_PORT=9090
LLAMACPP_CTX_SIZE=12345
LLAMACPP_GPU_LAYERS=7
LLAMACPP_API_KEY=old
ENVEOF
run_launch_activation_overrides "$root_activation" claude
assert_persisted_var "$root_activation/cache/llama-server.env" LLAMACPP_PORT 7070
assert_persisted_var "$root_activation/cache/llama-server.env" LLAMACPP_CTX_SIZE 22222
assert_persisted_var "$root_activation/cache/llama-server.env" LLAMACPP_GPU_LAYERS 4
assert_persisted_var "$root_activation/cache/llama-server.env" LLAMACPP_API_KEY envkey
assert_contains 'flox services restart llama-server' "$root_activation/log"
assert_contains 'flox services restart llamacpp-proxy' "$root_activation/log"
assert_contains 'claude ANTHROPIC_API_KEY=envkey' "$root_activation/log"

# VRAM auto-configuration must reduce nvidia-smi's per-GPU output to one numeric
# MiB value before calling vram-optimizer.
root_vram_single=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-vram-single.XXXXXX")
make_test_env "$root_vram_single" old 8080
run_launch_auto_config "$root_vram_single" claude 24576 1024
assert_contains 'vram-optimizer .* --vram-total-mib 24576 --vram-used-mib 1024 ' "$root_vram_single/log"
assert_persisted_var "$root_vram_single/cache/llama-server.env" LLAMACPP_CTX_SIZE 4242
assert_persisted_var "$root_vram_single/cache/llama-server.env" LLAMACPP_GPU_LAYERS 42

root_vram_multi=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-vram-multi.XXXXXX")
make_test_env "$root_vram_multi" old 8080
run_launch_auto_config "$root_vram_multi" claude $'24576
24576' $'1024
2048'
assert_contains 'vram-optimizer .* --vram-total-mib 49152 --vram-used-mib 3072 ' "$root_vram_multi/log"
assert_not_contains $'--vram-total-mib 24576
24576' "$root_vram_multi/log"
assert_persisted_var "$root_vram_multi/cache/llama-server.env" LLAMACPP_CTX_SIZE 4242
assert_persisted_var "$root_vram_multi/cache/llama-server.env" LLAMACPP_GPU_LAYERS 42

root_vram_bad=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-vram-bad.XXXXXX")
make_test_env "$root_vram_bad" old 8080
run_launch_auto_config "$root_vram_bad" claude $'24576
bad' 1024
assert_contains 'nvidia-smi --query-gpu=memory.total' "$root_vram_bad/log"
assert_not_contains 'vram-optimizer' "$root_vram_bad/log"
assert_persisted_var "$root_vram_bad/cache/llama-server.env" LLAMACPP_CTX_SIZE 65536
assert_persisted_var "$root_vram_bad/cache/llama-server.env" LLAMACPP_GPU_LAYERS 99


# Env writer must preserve shell metacharacters without evaluating them, and it must
# write private files through the atomic temp-file path.
root_quote=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-quote.XXXXXX")
make_test_env "$root_quote" old 8080
pwned="$root_quote/pwned"
special_key="space key ' \" \\ dollar=\$ backtick=\` cmd=\$(touch $pwned) semi=; amp=& pipe=|"$'\nline two'
run_launch "$root_quote" claude "$special_key" 8080
assert_private_file "$root_quote/cache/llama-server.env"
assert_no_env_temps "$root_quote/cache"
assert_no_proxy_state_temps "$root_quote/cache"
assert_persisted_var "$root_quote/cache/llama-server.env" LLAMACPP_API_KEY "$special_key"
if [ -e "$pwned" ]; then
  echo "env source evaluated API-key metacharacters" >&2
  exit 1
fi
assert_contains "^LLAMACPP_API_KEY='" "$root_quote/cache/llama-server.env"

# A later no-flag launch must read the quoted persisted value, not truncate it at
# a newline or rewrite it through defaults.
run_launch_no_server_flags "$root_quote" claude
assert_persisted_var "$root_quote/cache/llama-server.env" LLAMACPP_API_KEY "$special_key"
assert_private_file "$root_quote/cache/llama-server.env"
assert_no_env_temps "$root_quote/cache"
assert_no_proxy_state_temps "$root_quote/cache"
assert_not_contains 'flox services restart llama-server' "$root_quote/log"

# The wrapper must not execute mutable cache files when reading env, live, proxy,
# or model-lock state. Deliberately use legacy unquoted values that would execute
# if read with `. file`.
root_no_source=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-no-source.XXXXXX")
make_test_env "$root_no_source" old 8080
pwned_cache="$root_no_source/pwned-cache"
malicious_value="\$(touch $pwned_cache)"
cat > "$root_no_source/cache/llama-server.env" <<ENVEOF
LLAMACPP_HOST=127.0.0.1
LLAMACPP_PORT=8080
LLAMACPP_CTX_SIZE=65536
LLAMACPP_GPU_LAYERS=99
LLAMACPP_API_KEY=$malicious_value
ENVEOF
cat > "$root_no_source/cache/llama-server.live.env" <<LIVEEOF
LLAMACPP_LIVE_MODEL=$root_no_source/model.gguf
LLAMACPP_LIVE_HOST=127.0.0.1
LLAMACPP_LIVE_PORT=8080
LLAMACPP_LIVE_CTX_SIZE=65536
LLAMACPP_LIVE_GPU_LAYERS=99
LLAMACPP_LIVE_API_KEY=$malicious_value
LLAMACPP_LIVE_SERVER_MODEL=$root_no_source/model.gguf
LLAMACPP_LIVE_VERIFIED_AT=test
LIVEEOF
cat > "$root_no_source/cache/llamacpp-proxy.state" <<STATEEOF
LLAMACPP_PROXY_HOST=127.0.0.1
LLAMACPP_PROXY_PORT=8081
LLAMACPP_PROXY_BACKEND_HOST=127.0.0.1
LLAMACPP_PROXY_BACKEND_PORT=8080
LLAMACPP_PROXY_BACKEND_API_KEY=$malicious_value
STATEEOF
mkdir -p "$root_no_source/cache/model-locks"
cat > "$root_no_source/cache/model-locks/search-malicious.env" <<LOCKEOF
LLAMACPP_MODEL_QUERY=$malicious_value
LLAMACPP_MODEL_QUANT=Q4_K_M
LLAMACPP_RESOLVED_MODEL=$root_no_source/model.gguf
LLAMACPP_RESOLVED_AT=test
LOCKEOF
chmod 600 "$root_no_source/cache/llama-server.env" "$root_no_source/cache/llama-server.live.env" "$root_no_source/cache/llamacpp-proxy.state" "$root_no_source/cache/model-locks/search-malicious.env"
run_launch_no_server_flags "$root_no_source" claude
PATH="$root_no_source/bin:$ORIG_PATH" TEST_LOG="$root_no_source/log" FLOX_ENV_CACHE="$root_no_source/cache" HOME="$root_no_source/home" XDG_CONFIG_HOME="$root_no_source/config" SCRIPT="$SCRIPT" bash -c 'source "$SCRIPT"; llamacpp model locks' > "$root_no_source/locks.out" 2>&1
if [ -e "$pwned_cache" ]; then
  echo "mutable cache file was executed while being read" >&2
  exit 1
fi
if grep -n '\. "\$.*_file"' "$SCRIPT"; then
  echo "script still sources a mutable cache file" >&2
  exit 1
fi


printf 'state tests passed\n'
exit 0
