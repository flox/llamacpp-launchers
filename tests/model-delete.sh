#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$TEST_DIR/lib.sh"

# model remove must reject path components before constructing a deletion
# target; otherwise ../ can escape the model directory.
root_remove_path=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-remove-path.XXXXXX")
make_test_env "$root_remove_path" old 8080
mkdir -p "$root_remove_path/cache/models"
: > "$root_remove_path/cache/models/model.gguf"
: > "$root_remove_path/cache/victim.gguf"
if run_model_remove_name "$root_remove_path" '../victim.gguf'; then
  echo "model remove accepted a parent-directory path" >&2
  exit 1
fi
[ -f "$root_remove_path/cache/victim.gguf" ] || { echo "model remove deleted outside the model directory" >&2; exit 1; }
if run_model_remove_name "$root_remove_path" 'subdir/model.gguf'; then
  echo "model remove accepted a subdirectory path" >&2
  exit 1
fi
[ -f "$root_remove_path/cache/models/model.gguf" ] || { echo "model remove deleted through a path component" >&2; exit 1; }
if run_model_remove_name "$root_remove_path" '..'; then
  echo "model remove accepted .." >&2
  exit 1
fi
if run_model_remove_name "$root_remove_path" '.'; then
  echo "model remove accepted ." >&2
  exit 1
fi
[ -f "$root_remove_path/cache/models/model.gguf" ] || { echo "model remove . deleted the only model" >&2; exit 1; }

root_remove_active=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-remove-active.XXXXXX")
make_test_env "$root_remove_active" old 8080
mkdir -p "$root_remove_active/cache/models"
: > "$root_remove_active/cache/models/active.gguf"
: > "$root_remove_active/cache/models/inactive.gguf"
printf '%s' "$root_remove_active/cache/models/active.gguf" > "$root_remove_active/cache/llama-server.model"
if run_model_remove_name "$root_remove_active" 'active.gguf' > "$root_remove_active/remove-active.out" 2>&1; then
  echo "model remove deleted the active model" >&2
  exit 1
fi
assert_contains 'refusing to delete the active model: active.gguf' "$root_remove_active/remove-active.out"
assert_contains 'Set another model first' "$root_remove_active/remove-active.out"
[ -f "$root_remove_active/cache/models/active.gguf" ] || { echo "active model file was deleted" >&2; exit 1; }
assert_equals "$root_remove_active/cache/models/active.gguf" "$(cat "$root_remove_active/cache/llama-server.model")" 'active model state after refused delete'
run_model_remove_name "$root_remove_active" 'inactive.gguf'
[ ! -e "$root_remove_active/cache/models/inactive.gguf" ] || { echo "inactive model was not deleted" >&2; exit 1; }

root_short_fuzzy=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-remove-short-fuzzy.XXXXXX")
make_test_env "$root_short_fuzzy" old 8080
mkdir -p "$root_short_fuzzy/cache/models"
: > "$root_short_fuzzy/cache/models/model.gguf"
if run_model_remove_name "$root_short_fuzzy" 'mo'; then
  echo "model remove accepted a too-short fuzzy term" >&2
  exit 1
fi
[ -f "$root_short_fuzzy/cache/models/model.gguf" ] || { echo "short fuzzy term deleted model.gguf" >&2; exit 1; }
: > "$root_short_fuzzy/cache/models/ab"
run_model_remove_name "$root_short_fuzzy" 'ab'
[ ! -e "$root_short_fuzzy/cache/models/ab" ] || { echo "exact short filename was not deleted" >&2; exit 1; }

# Fuzzy local model deletion must treat *, ?, and [ as literal bytes in the
# user-supplied search term, not as find -name glob syntax.
root_literal=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-literal.XXXXXX")
make_test_env "$root_literal" old 8080
mkdir -p "$root_literal/cache/models"
: > "$root_literal/cache/models/alpha.gguf"
if run_model_remove_name "$root_literal" '*'; then
  echo "model remove treated * as a wildcard" >&2
  exit 1
fi
[ -f "$root_literal/cache/models/alpha.gguf" ] || { echo "literal * search deleted alpha.gguf" >&2; exit 1; }

: > "$root_literal/cache/models/star*model.gguf"
: > "$root_literal/cache/models/starXmodel.gguf"
run_model_remove_name "$root_literal" 'star*model'
[ ! -e "$root_literal/cache/models/star*model.gguf" ] || { echo "literal star filename was not deleted" >&2; exit 1; }
[ -e "$root_literal/cache/models/starXmodel.gguf" ] || { echo "wildcard-like star search deleted starXmodel.gguf" >&2; exit 1; }

: > "$root_literal/cache/models/qmark?model.gguf"
: > "$root_literal/cache/models/qmarkXmodel.gguf"
run_model_remove_name "$root_literal" 'qmark?model'
[ ! -e "$root_literal/cache/models/qmark?model.gguf" ] || { echo "literal question-mark filename was not deleted" >&2; exit 1; }
[ -e "$root_literal/cache/models/qmarkXmodel.gguf" ] || { echo "wildcard-like question-mark search deleted qmarkXmodel.gguf" >&2; exit 1; }

: > "$root_literal/cache/models/brack[model.gguf"
: > "$root_literal/cache/models/brackXmodel.gguf"
run_model_remove_name "$root_literal" 'brack[model'
[ ! -e "$root_literal/cache/models/brack[model.gguf" ] || { echo "literal bracket filename was not deleted" >&2; exit 1; }
[ -e "$root_literal/cache/models/brackXmodel.gguf" ] || { echo "wildcard-like bracket search deleted brackXmodel.gguf" >&2; exit 1; }

printf 'model-delete tests passed\n'
exit 0
