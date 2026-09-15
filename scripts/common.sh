#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

if [[ -n "${CONFIG_FILE:-}" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf 'Config file not found: %s\n' "$CONFIG_FILE" >&2
    exit 2
  fi
  # The config is a shell environment file and must come from a trusted source.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}
