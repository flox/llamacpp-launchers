#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/bin/llamacpp"
ORIG_PATH="$PATH"

make_test_env() {
  local root="$1" api_key="$2" port="$3"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"

  mkdir -p "$cache" "$bin"
  : > "$model"
  printf '%s' "$model" > "$cache/llama-server.model"
  cat > "$cache/llama-server.env" <<ENVEOF
LLAMACPP_HOST=127.0.0.1
LLAMACPP_PORT=$port
LLAMACPP_CTX_SIZE=65536
LLAMACPP_GPU_LAYERS=99
LLAMACPP_API_KEY=$api_key
ENVEOF
  cat > "$cache/llama-server.live.env" <<LIVEEOF
LLAMACPP_LIVE_MODEL='$model'
LLAMACPP_LIVE_HOST='127.0.0.1'
LLAMACPP_LIVE_PORT='$port'
LLAMACPP_LIVE_CTX_SIZE='65536'
LLAMACPP_LIVE_GPU_LAYERS='99'
LLAMACPP_LIVE_API_KEY='$api_key'
LLAMACPP_LIVE_SERVER_MODEL='$model'
LLAMACPP_LIVE_VERIFIED_AT='test'
LIVEEOF
  chmod 600 "$cache/llama-server.live.env"
  cat > "$cache/llamacpp-proxy.state" <<STATEEOF
LLAMACPP_PROXY_HOST=127.0.0.1
LLAMACPP_PROXY_PORT=8081
LLAMACPP_PROXY_BACKEND_HOST=127.0.0.1
LLAMACPP_PROXY_BACKEND_PORT=$port
LLAMACPP_PROXY_BACKEND_API_KEY=$api_key
STATEEOF
  chmod 600 "$cache/llamacpp-proxy.state"

  cat > "$bin/flox" <<'STUBEOF'
#!/usr/bin/env bash
echo "flox $*" >> "$TEST_LOG"
case "$*" in
  "services status llama-server")
    if [ "${TEST_LLAMA_STATUS_DOWN:-0}" = 1 ]; then exit 1; fi
    exit 0
    ;;
  "services restart llama-server")
    if [ "${TEST_FAIL_LLAMA_RESTART:-0}" = 1 ]; then exit 42; fi
    exit 0
    ;;
  "services start llama-server")
    if [ "${TEST_FAIL_LLAMA_START:-0}" = 1 ]; then exit 43; fi
    exit 0
    ;;
  "services status llamacpp-proxy") exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF

  cat > "$bin/curl" <<'STUBEOF'
#!/usr/bin/env bash
echo "curl $*" >> "$TEST_LOG"
case "$*" in
  *'/v1/models'*)
    if [ -n "${TEST_MODELS_BODY_FILE:-}" ]; then
      cat "$TEST_MODELS_BODY_FILE"
    else
      model_id=${TEST_SERVER_MODEL:-${MODEL:-model.gguf}}
      printf '{"object":"list","data":[{"id":"%s"}]}
' "$model_id"
    fi
    ;;
esac
exit 0
STUBEOF

  cat > "$bin/sleep" <<'STUBEOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$TEST_LOG"
exit 0
STUBEOF

  cat > "$bin/llamacpp-proxy" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF

  cat > "$bin/nvidia-smi" <<'STUBEOF'
#!/usr/bin/env bash
echo "nvidia-smi $*" >> "$TEST_LOG"
case "$*" in
  *memory.total*) printf '%s\n' "${TEST_NVIDIA_TOTALS:-24576}" ;;
  *memory.used*) printf '%s\n' "${TEST_NVIDIA_USED:-1024}" ;;
  *) echo 0 ;;
esac
exit 0
STUBEOF

  cat > "$bin/vram-optimizer" <<'STUBEOF'
#!/usr/bin/env bash
echo "vram-optimizer $*" >> "$TEST_LOG"
echo gpu_layers=42
echo ctx_size=4242
exit 0
STUBEOF

  cat > "$bin/claude" <<'STUBEOF'
#!/usr/bin/env bash
echo "claude ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY} ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL} $*" >> "$TEST_LOG"
exit 0
STUBEOF

  cat > "$bin/opencode" <<'STUBEOF'
#!/usr/bin/env bash
if [ -n "${OPENCODE_CONFIG_CONTENT:-}" ]; then
  printf '%s' "$OPENCODE_CONFIG_CONTENT" > "${TEST_LOG}.opencode_config_content"
  opencode_config_content_status=set
else
  : > "${TEST_LOG}.opencode_config_content"
  opencode_config_content_status=unset
fi
echo "opencode OPENAI_BASE_URL=${OPENAI_BASE_URL} OPENAI_API_KEY=${OPENAI_API_KEY} OPENCODE_CONFIG=${OPENCODE_CONFIG:-} OPENCODE_CONFIG_CONTENT=${opencode_config_content_status} OPENCODE_MODEL=${OPENCODE_MODEL:-} $*" >> "$TEST_LOG"
exit 0
STUBEOF

  cat > "$bin/gemini" <<'STUBEOF'
#!/usr/bin/env bash
echo "gemini GOOGLE_GEMINI_BASE_URL=${GOOGLE_GEMINI_BASE_URL:-} GEMINI_API_KEY=${GEMINI_API_KEY:-} GEMINI_MODEL=${GEMINI_MODEL:-} $*" >> "$TEST_LOG"
exit 0
STUBEOF

  cat > "$bin/crush" <<'STUBEOF'
#!/usr/bin/env bash
echo "crush CRUSH_GLOBAL_CONFIG=${CRUSH_GLOBAL_CONFIG:-} CRUSH_GLOBAL_DATA=${CRUSH_GLOBAL_DATA:-} CRUSH_CACHE_DIR=${CRUSH_CACHE_DIR:-} $*" >> "$TEST_LOG"
exit 0
STUBEOF

  cat > "$bin/deepseek-tui" <<'STUBEOF'
#!/usr/bin/env bash
echo "deepseek-tui $*" >> "$TEST_LOG"
exit 0
STUBEOF

  cat > "$bin/hf" <<'STUBEOF'
#!/usr/bin/env bash
echo "hf $*" >> "$TEST_LOG"
case "$*" in
  models\ ls\ --search*)
    printf 'modelId\tdownloads\n'
    printf '%s\t1000\n' "${HF_REPO:-unsloth/Default-GGUF}"
    printf '%s\t500\n' "${HF_REPO_FALLBACK:-bartowski/Fallback-GGUF}"
    exit 0
    ;;
  download*)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
STUBEOF

  chmod +x "$bin"/*
}

run_launch() {
  local root="$1" harness="$2" api_key="$3" port="$4"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  MODEL="$model" \
  SCRIPT="$SCRIPT" \
  LLAMACPP_HOST=127.0.0.1 \
  LLAMACPP_PORT=8080 \
  LLAMACPP_PROXY_PORT=8081 \
  LLAMACPP_CTX_SIZE=65536 \
  LLAMACPP_GPU_LAYERS=99 \
  LLAMACPP_API_KEY=default \
  bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL" --gpu-layers 99 --ctx-size 65536 --port "$2" --api-key "$3"' _ "$harness" "$port" "$api_key"
}


run_launch_with_ctx_size() {
  local root="$1" harness="$2" api_key="$3" port="$4" ctx_size="$5"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH"   TEST_LOG="$root/log"   FLOX_ENV_CACHE="$cache"   HOME="$root/home"   XDG_CONFIG_HOME="$root/config"   MODEL="$model"   SCRIPT="$SCRIPT"   LLAMACPP_HOST=127.0.0.1   LLAMACPP_PORT=8080   LLAMACPP_PROXY_PORT=8081   LLAMACPP_CTX_SIZE=65536   LLAMACPP_GPU_LAYERS=99   LLAMACPP_API_KEY=default   bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL" --gpu-layers 99 --ctx-size "$2" --port "$3" --api-key "$4"' _ "$harness" "$ctx_size" "$port" "$api_key"
}

run_launch_no_server_flags() {
  local root="$1" harness="$2"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  : > "$root/log"

  (
    unset LLAMACPP_HOST LLAMACPP_PORT LLAMACPP_CTX_SIZE LLAMACPP_GPU_LAYERS LLAMACPP_API_KEY
    PATH="$bin:$ORIG_PATH" \
    TEST_LOG="$root/log" \
    FLOX_ENV_CACHE="$cache" \
    MODEL="$model" \
    SCRIPT="$SCRIPT" \
    LLAMACPP_PROXY_PORT=8081 \
    bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL"' _ "$harness"
  )
}

run_launch_expect_failure() {
  local root="$1" harness="$2" expected_pattern="$3"
  shift 3
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  local status=0
  : > "$root/log"

  (
    unset LLAMACPP_HOST LLAMACPP_PORT LLAMACPP_CTX_SIZE LLAMACPP_GPU_LAYERS LLAMACPP_API_KEY
    PATH="$bin:$ORIG_PATH" \
    TEST_LOG="$root/log" \
    FLOX_ENV_CACHE="$cache" \
    HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    MODEL="$model" \
    SCRIPT="$SCRIPT" \
    LLAMACPP_PROXY_PORT=8081 \
    bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL" "${@:2}"' _ "$harness" "$@"
  ) > "$root/invalid.out" 2>&1 || status=$?

  if [ "$status" -eq 0 ]; then
    echo "invalid launch unexpectedly succeeded: $*" >&2
    cat "$root/invalid.out" >&2
    exit 1
  fi
  assert_contains "$expected_pattern" "$root/invalid.out"
}

run_launch_with_harness_args_after_delimiter() {
  local root="$1" harness="$2"
  shift 2
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  : > "$root/log"

  (
    unset LLAMACPP_HOST LLAMACPP_PORT LLAMACPP_CTX_SIZE LLAMACPP_GPU_LAYERS LLAMACPP_API_KEY
    PATH="$bin:$ORIG_PATH" \
    TEST_LOG="$root/log" \
    FLOX_ENV_CACHE="$cache" \
    HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    MODEL="$model" \
    SCRIPT="$SCRIPT" \
    LLAMACPP_PROXY_PORT=8081 \
    bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL" -- "${@:2}"' _ "$harness" "$@"
  )
}

run_launch_service_failure() {
  local root="$1" mode="$2"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  local status=0
  : > "$root/log"

  case "$mode" in
    restart)
      PATH="$bin:$ORIG_PATH" \
      TEST_LOG="$root/log" \
      TEST_FAIL_LLAMA_RESTART=1 \
      FLOX_ENV_CACHE="$cache" \
      HOME="$root/home" \
      XDG_CONFIG_HOME="$root/config" \
      MODEL="$model" \
      SCRIPT="$SCRIPT" \
      LLAMACPP_HOST=127.0.0.1 \
      LLAMACPP_PORT=8080 \
      LLAMACPP_PROXY_PORT=8081 \
      LLAMACPP_CTX_SIZE=65536 \
      LLAMACPP_GPU_LAYERS=99 \
      LLAMACPP_API_KEY=default \
      bash -c 'source "$SCRIPT"; llamacpp launch claude --model "$MODEL" --port 8080 --api-key new' > "$root/service-failure.out" 2>&1 || status=$?
      ;;
    start)
      PATH="$bin:$ORIG_PATH" \
      TEST_LOG="$root/log" \
      TEST_LLAMA_STATUS_DOWN=1 \
      TEST_FAIL_LLAMA_START=1 \
      FLOX_ENV_CACHE="$cache" \
      HOME="$root/home" \
      XDG_CONFIG_HOME="$root/config" \
      MODEL="$model" \
      SCRIPT="$SCRIPT" \
      LLAMACPP_HOST=127.0.0.1 \
      LLAMACPP_PORT=8080 \
      LLAMACPP_PROXY_PORT=8081 \
      LLAMACPP_CTX_SIZE=65536 \
      LLAMACPP_GPU_LAYERS=99 \
      LLAMACPP_API_KEY=default \
      bash -c 'source "$SCRIPT"; llamacpp launch claude --model "$MODEL" --port 8080 --api-key new' > "$root/service-failure.out" 2>&1 || status=$?
      ;;
    *)
      echo "unknown service failure mode: $mode" >&2
      exit 64
      ;;
  esac

  if [ "$status" -eq 0 ]; then
    echo "launch unexpectedly succeeded despite llama-server $mode failure" >&2
    cat "$root/service-failure.out" >&2
    cat "$root/log" >&2
    exit 1
  fi
}


run_launch_activation_overrides() {
  local root="$1" harness="$2"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  MODEL="$model" \
  SCRIPT="$SCRIPT" \
  LLAMACPP_HOST=127.0.0.1 \
  LLAMACPP_PORT=7070 \
  LLAMACPP_PROXY_PORT=8081 \
  LLAMACPP_CTX_SIZE=22222 \
  LLAMACPP_GPU_LAYERS=4 \
  LLAMACPP_API_KEY=envkey \
  bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL"' _ "$harness"
}

run_launch_auto_config() {
  local root="$1" harness="$2" totals="$3" used="$4"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  : > "$root/log"

  cat > "$cache/llama-server.env" <<ENVEOF
LLAMACPP_HOST=127.0.0.1
LLAMACPP_PORT=8080
LLAMACPP_API_KEY=autokey
ENVEOF

  (
    unset LLAMACPP_HOST LLAMACPP_PORT LLAMACPP_CTX_SIZE LLAMACPP_GPU_LAYERS LLAMACPP_API_KEY
    PATH="$bin:$ORIG_PATH" \
    TEST_LOG="$root/log" \
    TEST_NVIDIA_TOTALS="$totals" \
    TEST_NVIDIA_USED="$used" \
    FLOX_ENV_CACHE="$cache" \
    HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    MODEL="$model" \
    SCRIPT="$SCRIPT" \
    LLAMACPP_PROXY_PORT=8081 \
    bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL"' _ "$harness"
  )
}

run_model_set_query() {
  local root="$1" query="$2" repo="$3" quant="${4:-Q4_K_M}"
  local cache="$root/cache" bin="$root/bin"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  HF_REPO="$repo" \
  LLAMACPP_DEFAULT_QUANT="$quant" \
  bash -c 'source "$SCRIPT"; llamacpp model set "$1"' _ "$query"
}

run_model_set_path() {
  local root="$1"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  MODEL="$model" \
  SCRIPT="$SCRIPT" \
  bash -c 'source "$SCRIPT"; llamacpp model set "$MODEL"'
}

run_model_set_relative_path() {
  local root="$1" rel="$2" cwd="$3"
  local cache="$root/cache" bin="$root/bin"
  : > "$root/log"

  (
    cd "$cwd"
    PATH="$bin:$ORIG_PATH" \
    TEST_LOG="$root/log" \
    FLOX_ENV_CACHE="$cache" \
    HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    SCRIPT="$SCRIPT" \
    bash -c 'source "$SCRIPT"; llamacpp model set "$1"' _ "$rel"
  )
}

run_model_pin_query() {
  local root="$1" query="$2" repo="$3" quant="${4:-Q4_K_M}"
  local cache="$root/cache" bin="$root/bin"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  HF_REPO="$repo" \
  LLAMACPP_DEFAULT_QUANT="$quant" \
  bash -c 'source "$SCRIPT"; llamacpp model pin "$1" --quant "$2"' _ "$query" "$quant"
}


run_model_pin_expect_failure() {
  local root="$1" query="$2" quant="$3" expected_pattern="$4"
  local cache="$root/cache" bin="$root/bin"
  local status=0
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  bash -c 'source "$SCRIPT"; llamacpp model pin "$1" --quant "$2"' _ "$query" "$quant" > "$root/model-pin-failure.out" 2>&1 || status=$?

  if [ "$status" -eq 0 ]; then
    echo "model pin unexpectedly accepted invalid quant: $quant" >&2
    cat "$root/model-pin-failure.out" >&2
    exit 1
  fi
  assert_contains "$expected_pattern" "$root/model-pin-failure.out"
}

run_model_set_expect_failure() {
  local root="$1" spec="$2" expected_pattern="$3"
  local cache="$root/cache" bin="$root/bin"
  local status=0
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  bash -c 'source "$SCRIPT"; llamacpp model set "$1"' _ "$spec" > "$root/model-set-failure.out" 2>&1 || status=$?

  if [ "$status" -eq 0 ]; then
    echo "model set unexpectedly accepted invalid spec: $spec" >&2
    cat "$root/model-set-failure.out" >&2
    exit 1
  fi
  assert_contains "$expected_pattern" "$root/model-set-failure.out"
}

run_model_search_query() {
  local root="$1" query="$2" repo="$3"
  local cache="$root/cache" bin="$root/bin"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  HF_REPO="$repo" \
  bash -c 'source "$SCRIPT"; llamacpp model search "$1"' _ "$query"
}

run_model_pull_spec() {
  local root="$1" spec="$2"
  local cache="$root/cache" bin="$root/bin"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  bash -c 'source "$SCRIPT"; llamacpp model pull "$1"' _ "$spec"
}

run_model_pull_expect_failure() {
  local root="$1" spec="$2" expected_pattern="$3"
  local cache="$root/cache" bin="$root/bin"
  local status=0
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  bash -c 'source "$SCRIPT"; llamacpp model pull "$1"' _ "$spec" > "$root/model-pull-failure.out" 2>&1 || status=$?

  if [ "$status" -eq 0 ]; then
    echo "model pull unexpectedly accepted invalid repo spec: $spec" >&2
    cat "$root/model-pull-failure.out" >&2
    exit 1
  fi
  assert_contains "$expected_pattern" "$root/model-pull-failure.out"
}

run_model_remove_name() {
  local root="$1" name="$2"
  local cache="$root/cache" bin="$root/bin"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  SCRIPT="$SCRIPT" \
  bash -c 'source "$SCRIPT"; llamacpp model remove "$1"' _ "$name"
}

run_launch_with_models_body_file() {
  local root="$1" harness="$2" api_key="$3" port="$4" models_body_file="$5"
  local cache="$root/cache" bin="$root/bin" model="$root/model.gguf"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  TEST_MODELS_BODY_FILE="$models_body_file" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  MODEL="$model" \
  SCRIPT="$SCRIPT" \
  LLAMACPP_HOST=127.0.0.1 \
  LLAMACPP_PORT=8080 \
  LLAMACPP_PROXY_PORT=8081 \
  LLAMACPP_CTX_SIZE=65536 \
  LLAMACPP_GPU_LAYERS=99 \
  LLAMACPP_API_KEY=default \
  bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL" --gpu-layers 99 --ctx-size 65536 --port "$2" --api-key "$3"' _ "$harness" "$port" "$api_key"
}

run_launch_with_model_and_models_body_file() {
  local root="$1" harness="$2" api_key="$3" port="$4" model_spec="$5" models_body_file="$6"
  local cache="$root/cache" bin="$root/bin"
  : > "$root/log"

  PATH="$bin:$ORIG_PATH" \
  TEST_LOG="$root/log" \
  TEST_MODELS_BODY_FILE="$models_body_file" \
  FLOX_ENV_CACHE="$cache" \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  MODEL="$model_spec" \
  SCRIPT="$SCRIPT" \
  LLAMACPP_HOST=127.0.0.1 \
  LLAMACPP_PORT=8080 \
  LLAMACPP_PROXY_PORT=8081 \
  LLAMACPP_CTX_SIZE=65536 \
  LLAMACPP_GPU_LAYERS=99 \
  LLAMACPP_API_KEY=default \
  bash -c 'source "$SCRIPT"; llamacpp launch "$1" --model "$MODEL" --gpu-layers 99 --ctx-size 65536 --port "$2" --api-key "$3"' _ "$harness" "$port" "$api_key"
}

assert_contains() {
  local pattern="$1" file="$2"
  if ! grep -q -- "$pattern" "$file"; then
    echo "missing pattern: $pattern" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local pattern="$1" file="$2"
  if grep -q -- "$pattern" "$file"; then
    echo "unexpected pattern: $pattern" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

read_persisted_var() {
  local env_file="$1" name="$2"
  bash -c '
    set -e
    . "$1"
    case "$2" in
      LLAMACPP_HOST) printf "%s" "${LLAMACPP_HOST:-}" ;;
      LLAMACPP_PORT) printf "%s" "${LLAMACPP_PORT:-}" ;;
      LLAMACPP_CTX_SIZE) printf "%s" "${LLAMACPP_CTX_SIZE:-}" ;;
      LLAMACPP_GPU_LAYERS) printf "%s" "${LLAMACPP_GPU_LAYERS:-}" ;;
      LLAMACPP_API_KEY) printf "%s" "${LLAMACPP_API_KEY:-}" ;;
      LLAMACPP_PROXY_HOST) printf "%s" "${LLAMACPP_PROXY_HOST:-}" ;;
      LLAMACPP_PROXY_PORT) printf "%s" "${LLAMACPP_PROXY_PORT:-}" ;;
      LLAMACPP_PROXY_BACKEND_HOST) printf "%s" "${LLAMACPP_PROXY_BACKEND_HOST:-}" ;;
      LLAMACPP_PROXY_BACKEND_PORT) printf "%s" "${LLAMACPP_PROXY_BACKEND_PORT:-}" ;;
      LLAMACPP_PROXY_BACKEND_API_KEY) printf "%s" "${LLAMACPP_PROXY_BACKEND_API_KEY:-}" ;;
      LLAMACPP_LIVE_MODEL) printf "%s" "${LLAMACPP_LIVE_MODEL:-}" ;;
      LLAMACPP_LIVE_HOST) printf "%s" "${LLAMACPP_LIVE_HOST:-}" ;;
      LLAMACPP_LIVE_PORT) printf "%s" "${LLAMACPP_LIVE_PORT:-}" ;;
      LLAMACPP_LIVE_CTX_SIZE) printf "%s" "${LLAMACPP_LIVE_CTX_SIZE:-}" ;;
      LLAMACPP_LIVE_GPU_LAYERS) printf "%s" "${LLAMACPP_LIVE_GPU_LAYERS:-}" ;;
      LLAMACPP_LIVE_API_KEY) printf "%s" "${LLAMACPP_LIVE_API_KEY:-}" ;;
      LLAMACPP_LIVE_SERVER_MODEL) printf "%s" "${LLAMACPP_LIVE_SERVER_MODEL:-}" ;;
      *) exit 64 ;;
    esac
  ' _ "$env_file" "$name"
}

assert_equals() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "mismatch: $label" >&2
    echo "expected bytes:" >&2
    printf "%s" "$expected" | od -An -tx1 >&2
    echo "actual bytes:" >&2
    printf "%s" "$actual" | od -An -tx1 >&2
    exit 1
  fi
}

assert_persisted_var() {
  local env_file="$1" name="$2" expected="$3" actual
  actual=$(read_persisted_var "$env_file" "$name")
  assert_equals "$expected" "$actual" "$name"
}

assert_private_file() {
  local file="$1" mode
  mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
  if [ "$mode" != "600" ]; then
    echo "unexpected file mode for $file: $mode" >&2
    exit 1
  fi
}

assert_no_env_temps() {
  local cache="$1"
  if compgen -G "$cache/llama-server.env.tmp.*" >/dev/null; then
    echo "unexpected leftover llama-server.env temp files" >&2
    ls -la "$cache" >&2
    exit 1
  fi
}

assert_no_proxy_state_temps() {
  local cache="$1"
  if compgen -G "$cache/llamacpp-proxy.state.tmp.*" >/dev/null; then
    echo "unexpected leftover llamacpp-proxy.state temp files" >&2
    ls -la "$cache" >&2
    exit 1
  fi
}

assert_no_live_state_temps() {
  local cache="$1"
  if compgen -G "$cache/llama-server.live.env.tmp.*" >/dev/null; then
    echo "unexpected leftover llama-server.live.env temp files" >&2
    ls -la "$cache" >&2
    exit 1
  fi
}

read_lock_var() {
  local lock_file="$1" name="$2"
  bash -c '
    set -e
    . "$1"
    case "$2" in
      LLAMACPP_MODEL_QUERY) printf "%s" "${LLAMACPP_MODEL_QUERY:-}" ;;
      LLAMACPP_MODEL_QUANT) printf "%s" "${LLAMACPP_MODEL_QUANT:-}" ;;
      LLAMACPP_RESOLVED_MODEL) printf "%s" "${LLAMACPP_RESOLVED_MODEL:-}" ;;
      LLAMACPP_RESOLVED_AT) printf "%s" "${LLAMACPP_RESOLVED_AT:-}" ;;
      *) exit 64 ;;
    esac
  ' _ "$lock_file" "$name"
}

first_model_lock_file() {
  find "$1/model-locks" -type f -name 'search-*.env' -print 2>/dev/null | head -1
}

assert_no_model_lock_temps() {
  local cache="$1"
  if compgen -G "$cache/model-locks/search-*.env.tmp.*" >/dev/null; then
    echo "unexpected leftover model-lock temp files" >&2
    find "$cache/model-locks" -maxdepth 1 -type f -print >&2
    exit 1
  fi
}
