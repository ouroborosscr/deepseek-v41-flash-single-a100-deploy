#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

PORT=${PORT:-7888}
SMOKE_HOST=${SMOKE_HOST:-127.0.0.1}
BASE_URL=${BASE_URL:-http://$SMOKE_HOST:$PORT}
MODEL_ALIAS=${MODEL_ALIAS:-DeepSeek-V4.1-Flash}
require_cmd curl
require_cmd python3

headers=(-H 'Content-Type: application/json')
if [[ -n "${API_KEY:-}" ]]; then
  headers+=(-H "Authorization: Bearer $API_KEY")
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

curl -fsS --max-time 10 "${headers[@]}" "$BASE_URL/health" >"$tmpdir/health.json"
curl -fsS --max-time 10 "${headers[@]}" "$BASE_URL/v1/models" >"$tmpdir/models.json"

cat >"$tmpdir/request.json" <<JSON
{
  "model": "$MODEL_ALIAS",
  "messages": [{"role": "user", "content": "What is 29*31? Return only the integer."}],
  "reasoning_effort": "none",
  "temperature": 0,
  "max_tokens": 32
}
JSON

curl -fsS --max-time 180 "${headers[@]}" \
  -d @"$tmpdir/request.json" \
  "$BASE_URL/v1/chat/completions" >"$tmpdir/response.json"

MODEL_ALIAS="$MODEL_ALIAS" TMPDIR_CHECK="$tmpdir" python3 <<'PY'
import json
import os

root = os.environ["TMPDIR_CHECK"]
alias = os.environ["MODEL_ALIAS"]
health = json.load(open(os.path.join(root, "health.json")))
models = json.load(open(os.path.join(root, "models.json")))
response = json.load(open(os.path.join(root, "response.json")))

assert health.get("status") == "ok", health
assert any(item.get("id") == alias for item in models.get("data", [])), models
content = response["choices"][0]["message"]["content"].strip()
assert content == "899", response
print("smoke_ok: health=ok, model=%s, answer=%s" % (alias, content))
PY
