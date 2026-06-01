#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$TEST_DIR/lib.sh"

# /health alone is insufficient. If the live stamp matches but /v1/models reports
# the wrong model, launch must restart and then fail instead of launching a harness.
root_wrong_model=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-wrong-model.XXXXXX")
make_test_env "$root_wrong_model" same 8080
wrong_status=0
PATH="$root_wrong_model/bin:$ORIG_PATH" TEST_LOG="$root_wrong_model/log" TEST_SERVER_MODEL=wrong-model FLOX_ENV_CACHE="$root_wrong_model/cache" HOME="$root_wrong_model/home" XDG_CONFIG_HOME="$root_wrong_model/config" MODEL="$root_wrong_model/model.gguf" SCRIPT="$SCRIPT" LLAMACPP_HOST=127.0.0.1 LLAMACPP_PORT=8080 LLAMACPP_PROXY_PORT=8081 LLAMACPP_CTX_SIZE=65536 LLAMACPP_GPU_LAYERS=99 LLAMACPP_API_KEY=same bash -c 'source "$SCRIPT"; llamacpp launch claude --model "$MODEL" --port 8080 --api-key same' > "$root_wrong_model/out" 2>&1 || wrong_status=$?
if [ "$wrong_status" -eq 0 ]; then
  echo "wrong live model unexpectedly launched harness" >&2
  cat "$root_wrong_model/out" >&2
  cat "$root_wrong_model/log" >&2
  exit 1
fi
assert_contains 'flox services restart llama-server' "$root_wrong_model/log"
assert_contains 'running llama-server model does not match requested model' "$root_wrong_model/out"
assert_not_contains '^claude ' "$root_wrong_model/log"
assert_persisted_var "$root_wrong_model/cache/llama-server.live.env" LLAMACPP_LIVE_SERVER_MODEL "$root_wrong_model/model.gguf"

# Basename or alias matches must not verify the live model. Two different paths
# can share model.gguf, so /v1/models must equal the requested server model ID.
root_same_basename=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-same-basename.XXXXXX")
make_test_env "$root_same_basename" same 8080
mkdir -p "$root_same_basename/a" "$root_same_basename/b"
: > "$root_same_basename/a/model.gguf"
: > "$root_same_basename/b/model.gguf"
same_basename_status=0
PATH="$root_same_basename/bin:$ORIG_PATH" TEST_LOG="$root_same_basename/log" TEST_SERVER_MODEL=model FLOX_ENV_CACHE="$root_same_basename/cache" HOME="$root_same_basename/home" XDG_CONFIG_HOME="$root_same_basename/config" MODEL="$root_same_basename/b/model.gguf" SCRIPT="$SCRIPT" LLAMACPP_HOST=127.0.0.1 LLAMACPP_PORT=8080 LLAMACPP_PROXY_PORT=8081 LLAMACPP_CTX_SIZE=65536 LLAMACPP_GPU_LAYERS=99 LLAMACPP_API_KEY=same bash -c 'source "$SCRIPT"; llamacpp launch claude --model "$MODEL" --port 8080 --api-key same' > "$root_same_basename/out" 2>&1 || same_basename_status=$?
if [ "$same_basename_status" -eq 0 ]; then
  echo "basename-only live model unexpectedly verified" >&2
  cat "$root_same_basename/out" >&2
  cat "$root_same_basename/log" >&2
  exit 1
fi
assert_contains 'flox services restart llama-server' "$root_same_basename/log"
assert_contains 'Expected /v1/models id: ' "$root_same_basename/out"
assert_contains "$root_same_basename/b/model.gguf" "$root_same_basename/out"
assert_not_contains '^claude ' "$root_same_basename/log"
assert_persisted_var "$root_same_basename/cache/llama-server.live.env" LLAMACPP_LIVE_MODEL "$root_same_basename/model.gguf"
assert_persisted_var "$root_same_basename/cache/llama-server.live.env" LLAMACPP_LIVE_SERVER_MODEL "$root_same_basename/model.gguf"


# /v1/models parsing must treat JSON as JSON. Commas and escaped quotes inside
# model IDs are valid JSON string content and must not break live verification.
if command -v python3 >/dev/null 2>&1; then
  root_json_models=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-json-models.XXXXXX")
  make_test_env "$root_json_models" same 8080

  comma_model="$root_json_models/dir,comma/model.gguf"
  mkdir -p "$(dirname "$comma_model")"
  : > "$comma_model"
  python3 - "$comma_model" "$root_json_models/comma-models.json" <<'PYMODELSJSON'
import json
import sys
from pathlib import Path
Path(sys.argv[2]).write_text(json.dumps({"object": "list", "data": [{"id": sys.argv[1]}]}))
PYMODELSJSON
  run_launch_with_model_and_models_body_file "$root_json_models" claude same 8080 "$comma_model" "$root_json_models/comma-models.json"
  assert_contains '^claude ' "$root_json_models/log"
  assert_persisted_var "$root_json_models/cache/llama-server.live.env" LLAMACPP_LIVE_SERVER_MODEL "$comma_model"

  quote_model="$root_json_models/weird\"name.gguf"
  : > "$quote_model"
  python3 - "$quote_model" "$root_json_models/quote-models.json" <<'PYMODELSJSON'
import json
import sys
from pathlib import Path
Path(sys.argv[2]).write_text(json.dumps({"object": "list", "data": [{"id": sys.argv[1]}]}))
PYMODELSJSON
  run_launch_with_model_and_models_body_file "$root_json_models" claude same 8080 "$quote_model" "$root_json_models/quote-models.json"
  assert_contains '^claude ' "$root_json_models/log"
  assert_persisted_var "$root_json_models/cache/llama-server.live.env" LLAMACPP_LIVE_SERVER_MODEL "$quote_model"
fi

printf 'json-parsing tests passed\n'
exit 0
