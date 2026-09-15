#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd nvidia-smi
require_cmd df

GPU_INDEX=${GPU_INDEX:-0}
MODEL_DIR=${MODEL_DIR:-/data/models/DeepSeek-V4.1-Flash}
MIN_RAM_GIB=${MIN_RAM_GIB:-768}
MIN_GPU_MIB=${MIN_GPU_MIB:-75000}
MIN_DISK_GIB=${MIN_DISK_GIB:-1100}

ram_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
ram_gib=$((ram_kib / 1024 / 1024))
gpu_mib=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=memory.total --format=csv,noheader,nounits)
disk_root=$(dirname "$MODEL_DIR")
mkdir -p "$disk_root"
disk_kib=$(df -Pk "$disk_root" | awk 'NR == 2 {print $4}')
disk_gib=$((disk_kib / 1024 / 1024))

log "RAM: ${ram_gib} GiB (minimum ${MIN_RAM_GIB} GiB)"
log "GPU ${GPU_INDEX}: ${gpu_mib} MiB (minimum ${MIN_GPU_MIB} MiB)"
log "Free disk at ${disk_root}: ${disk_gib} GiB (minimum ${MIN_DISK_GIB} GiB)"

nvidia-smi -i "$GPU_INDEX" \
  --query-gpu=index,name,driver_version,compute_cap,compute_mode,memory.total,memory.used,memory.free \
  --format=csv,noheader

((ram_gib >= MIN_RAM_GIB)) || die "insufficient system RAM"
((gpu_mib >= MIN_GPU_MIB)) || die "an A100 80GB-class GPU is required"
((disk_gib >= MIN_DISK_GIB)) || die "insufficient disk for source weights plus GGUF"

log "Host preflight passed"
