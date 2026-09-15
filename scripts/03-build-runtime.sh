#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd cmake
require_cmd curl
require_cmd ninja
require_cmd patch
require_cmd tar

DEPLOY_ROOT=${DEPLOY_ROOT:-/data/deepseek-v41-flash}
RUNTIME_DIR=${RUNTIME_DIR:-$DEPLOY_ROOT/llama.cpp}
CUDA_ROOT=${CUDA_ROOT:-/usr/local/cuda-12.8}
CUDA_ARCH=${CUDA_ARCH:-80}
LLAMA_COMMIT=${LLAMA_COMMIT:-3b6fcfe4f7e2c282076f0c159278d3acfa3ad4e5}
BUILD_DIR=${BUILD_DIR:-$RUNTIME_DIR/build-a100-cu128}
PATCH_FILE="$REPO_ROOT/patches/include-cmath.patch"

if [[ ! -x "$CUDA_ROOT/bin/nvcc" ]]; then
  die "nvcc not found at $CUDA_ROOT/bin/nvcc"
fi

mkdir -p "$DEPLOY_ROOT"
if [[ ! -f "$RUNTIME_DIR/CMakeLists.txt" ]]; then
  [[ ! -e "$RUNTIME_DIR" ]] || die "runtime path exists but is not a llama.cpp tree: $RUNTIME_DIR"
  archive=$(mktemp)
  staging=$(mktemp -d)
  trap 'rm -f "$archive"; rm -rf "$staging"' EXIT
  log "Downloading JigSawPT/llama.cpp commit ${LLAMA_COMMIT}"
  curl -L --fail --retry 3 \
    "https://codeload.github.com/JigSawPT/llama.cpp/tar.gz/${LLAMA_COMMIT}" \
    -o "$archive"
  tar -xzf "$archive" --strip-components=1 -C "$staging"
  mv "$staging" "$RUNTIME_DIR"
  trap 'rm -f "$archive"' EXIT
fi

if ! grep -q '^#include <cmath>$' "$RUNTIME_DIR/src/llama-moe-stream.cpp"; then
  log "Applying the std::isfinite build fix"
  patch -d "$RUNTIME_DIR" -p1 <"$PATCH_FILE"
fi

printf '%s\n' "$LLAMA_COMMIT" >"$DEPLOY_ROOT/LLAMA_COMMIT"

cmake -S "$RUNTIME_DIR" -B "$BUILD_DIR" -G Ninja \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
  -DCMAKE_CUDA_COMPILER="$CUDA_ROOT/bin/nvcc" \
  -DCUDAToolkit_ROOT="$CUDA_ROOT" \
  -DLLAMA_CURL=OFF \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" --target llama-server llama-cli -j "${BUILD_JOBS:-24}"

test -x "$BUILD_DIR/bin/llama-server"
test -x "$BUILD_DIR/bin/llama-cli"
CUDA_VISIBLE_DEVICES="${GPU_INDEX:-0}" "$BUILD_DIR/bin/llama-cli" --list-devices
log "Runtime build completed: $BUILD_DIR"
