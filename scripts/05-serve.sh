#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

DEPLOY_ROOT=${DEPLOY_ROOT:-/data/deepseek-v41-flash}
RUNTIME_DIR=${RUNTIME_DIR:-$DEPLOY_ROOT/llama.cpp}
BUILD_DIR=${BUILD_DIR:-$RUNTIME_DIR/build-a100-cu128}
GGUF_DIR=${GGUF_DIR:-$DEPLOY_ROOT/gguf}
MODEL_FILE=${MODEL_FILE:-$GGUF_DIR/DeepSeek-V4.1-Flash-MXFP4-engram-00001-of-00011.gguf}
MODEL_ALIAS=${MODEL_ALIAS:-DeepSeek-V4.1-Flash}
GPU_INDEX=${GPU_INDEX:-0}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-7888}
# 786,432 completed an end-to-end short-generation test on the reference A100.
# Use a smaller value if your workload has long prompts, multiple slots, or less
# free VRAM than the reference host.
CONTEXT_SIZE=${CONTEXT_SIZE:-786432}
PARALLEL=${PARALLEL:-1}
CPU_THREADS=${CPU_THREADS:-32}
VRAM_CACHE_GIB=${VRAM_CACHE_GIB:-60}
HOST_CACHE_GIB=${HOST_CACHE_GIB:-120}
ALLOW_UNAUTHENTICATED_PUBLIC=${ALLOW_UNAUTHENTICATED_PUBLIC:-0}
LLAMA_SERVER=${LLAMA_SERVER:-$BUILD_DIR/bin/llama-server}

[[ -x "$LLAMA_SERVER" ]] || die "llama-server not found: $LLAMA_SERVER"
[[ -f "$MODEL_FILE" ]] || die "first GGUF shard not found: $MODEL_FILE"

shard_count=$(find "$GGUF_DIR" -maxdepth 1 -type f -name '*.gguf' | wc -l)
((shard_count == 11)) || die "expected 11 GGUF shards, found $shard_count"

is_loopback=0
case "$HOST" in
  127.0.0.1|localhost|::1) is_loopback=1 ;;
esac

if ((is_loopback == 0)) && [[ -z "${API_KEY:-}" ]] && [[ "$ALLOW_UNAUTHENTICATED_PUBLIC" != 1 ]]; then
  die "public listener requires API_KEY or ALLOW_UNAUTHENTICATED_PUBLIC=1"
fi

args=(
  --model "$MODEL_FILE"
  --alias "$MODEL_ALIAS"
  --parallel "$PARALLEL"
  --n-gpu-layers 99
  --ctx-size "$CONTEXT_SIZE"
  --threads "$CPU_THREADS"
  --moe-stream
  --moe-stream-cache "$VRAM_CACHE_GIB"
  --moe-stream-l2 "$HOST_CACHE_GIB"
  --reasoning auto
  --reasoning-format deepseek
  --host "$HOST"
  --port "$PORT"
)

if [[ -n "${API_KEY:-}" ]]; then
  # Keep the secret out of the process command line. llama-server reads LLAMA_API_KEY.
  export LLAMA_API_KEY="$API_KEY"
fi

log "Starting ${MODEL_ALIAS} on ${HOST}:${PORT}, physical GPU ${GPU_INDEX}"
exec env CUDA_VISIBLE_DEVICES="$GPU_INDEX" "$LLAMA_SERVER" "${args[@]}"
