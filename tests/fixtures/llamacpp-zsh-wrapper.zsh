#!/usr/bin/env zsh
emulate -L zsh
set -e

if [[ $# -lt 1 ]]; then
  print -u2 "usage: llamacpp-zsh-wrapper.zsh /path/to/bin/llamacpp <llamacpp args...>"
  exit 64
fi

launcher="$1"
shift
exec bash -c 'set -euo pipefail; launcher="$1"; shift; source "$launcher"; llamacpp "$@"' -- "$launcher" "$@"
