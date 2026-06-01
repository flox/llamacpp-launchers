#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TIMEOUT_SECONDS=${LLAMACPP_TEST_TIMEOUT_SECONDS:-45}
BASE_PATH=$PATH
BASE_HOME=${HOME:-/tmp}
BASE_TMPDIR=${TMPDIR:-/tmp}
SUITES=(
  state.sh
  model-resolution.sh
  harness-config.sh
  model-delete.sh
  json-parsing.sh
)

pids=()
logs=()
names=()

start_suite() {
  local suite="$1" log
  log=$(mktemp "${TMPDIR:-/tmp}/llamacpp-${suite%.sh}.XXXXXX.log") || return 1
  printf '[llamacpp tests] running %s\n' "$suite"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECONDS" env -i PATH="$BASE_PATH" HOME="$BASE_HOME" TMPDIR="$BASE_TMPDIR" bash "$TEST_DIR/$suite" > "$log" 2>&1 &
  else
    env -i PATH="$BASE_PATH" HOME="$BASE_HOME" TMPDIR="$BASE_TMPDIR" bash "$TEST_DIR/$suite" > "$log" 2>&1 &
  fi
  pids+=("$!")
  logs+=("$log")
  names+=("$suite")
}

for suite in "${SUITES[@]}"; do
  start_suite "$suite"
done

failed=0
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  suite="${names[$i]}"
  log="${logs[$i]}"
  status=0
  wait "$pid" || status=$?
  cat "$log"
  rm -f "$log"
  if [ "$status" -eq 124 ]; then
    printf '[llamacpp tests] %s timed out after %s seconds\n' "$suite" "$TIMEOUT_SECONDS" >&2
    failed=1
  elif [ "$status" -ne 0 ]; then
    printf '[llamacpp tests] %s failed with status %s\n' "$suite" "$status" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'llamacpp split regression suites passed\n'
