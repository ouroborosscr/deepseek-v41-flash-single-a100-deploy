#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd modelscope
require_cmd python3

MODEL_ID=${MODEL_ID:-deepseek-ai/DeepSeek-V4.1-Flash}
MODEL_DIR=${MODEL_DIR:-/data/models/DeepSeek-V4.1-Flash}

mkdir -p "$MODEL_DIR"
log "Downloading ${MODEL_ID} to ${MODEL_DIR}"
modelscope download --model "$MODEL_ID" --local_dir "$MODEL_DIR"

MODEL_DIR="$MODEL_DIR" python3 <<'PY'
import glob
import json
import os
import sys

root = os.environ["MODEL_DIR"]
index_path = os.path.join(root, "model.safetensors.index.json")
if not os.path.isfile(index_path):
    raise SystemExit(f"missing index: {index_path}")

with open(index_path, encoding="utf-8") as handle:
    index = json.load(handle)

expected = sorted(set(index["weight_map"].values()))
actual = sorted(os.path.basename(path) for path in glob.glob(os.path.join(root, "model-*.safetensors")))
missing = sorted(set(expected) - set(actual))
extra = sorted(set(actual) - set(expected))
if missing or extra:
    raise SystemExit(f"shard mismatch: missing={missing}, extra={extra}")

total = sum(os.path.getsize(os.path.join(root, name)) for name in expected)
print(f"validated tensors={len(index['weight_map'])}, shards={len(expected)}, bytes={total}")
PY

log "Model download and shard validation completed"
