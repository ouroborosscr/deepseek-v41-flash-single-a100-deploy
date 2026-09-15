#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

MODEL_DIR=${MODEL_DIR:-/data/models/DeepSeek-V4.1-Flash}
DEPLOY_ROOT=${DEPLOY_ROOT:-/data/deepseek-v41-flash}
RUNTIME_DIR=${RUNTIME_DIR:-$DEPLOY_ROOT/llama.cpp}
GGUF_DIR=${GGUF_DIR:-$DEPLOY_ROOT/gguf}
CONVERT_PYTHON=${CONVERT_PYTHON:-python3}
MODE=${1:---dry-run}
OUTFILE="$GGUF_DIR/DeepSeek-V4.1-Flash-MXFP4-engram.gguf"

[[ -f "$MODEL_DIR/model.safetensors.index.json" ]] || die "model index not found: $MODEL_DIR"
[[ -f "$RUNTIME_DIR/convert_hf_to_gguf.py" ]] || die "converter not found: $RUNTIME_DIR"
"$CONVERT_PYTHON" -c 'import numpy, safetensors, torch, transformers, yaml' \
  || die "conversion Python is missing required packages"

mkdir -p "$GGUF_DIR"
args=(
  "$RUNTIME_DIR/convert_hf_to_gguf.py"
  "$MODEL_DIR"
  --outtype bf16
  --engram
  --split-max-size 48G
  --outfile "$OUTFILE"
)

case "$MODE" in
  --dry-run)
    args+=(--dry-run)
    ;;
  --convert)
    if compgen -G "$GGUF_DIR/*.gguf" >/dev/null; then
      die "refusing to overwrite existing GGUF files in $GGUF_DIR"
    fi
    ;;
  *)
    die "usage: $0 [--dry-run|--convert]"
    ;;
esac

log "Starting conversion mode: $MODE"
"$CONVERT_PYTHON" "${args[@]}"
log "Conversion mode completed: $MODE"
