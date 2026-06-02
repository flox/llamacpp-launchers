#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
bash "$ROOT_DIR/tests/test-launch-stale-state.sh"
bash "$ROOT_DIR/tests/test-macos-zsh-wrapper.sh"
