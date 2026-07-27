#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"
set -a
# shellcheck disable=SC1091
source ./.env
set +a

PORT="${RAG_PORT:-8001}"
BASE="http://localhost:${PORT}"

echo "== HEALTH =="
curl -fsS "$BASE/health"
echo -e "\n"

echo "== UPLOAD =="
curl -fsS -F "file=@rag_pipeline/input/sample.md" "$BASE/upload"
echo -e "\n"

echo "== IN-SCOPE QUESTION =="
curl -fsS -X POST "$BASE/chat" \
  -H 'Content-Type: application/json' \
  -d '{"question":"Rule và Skill khác nhau như thế nào?"}'
echo -e "\n"

echo "== OUT-OF-SCOPE QUESTION =="
curl -fsS -X POST "$BASE/chat" \
  -H 'Content-Type: application/json' \
  -d '{"question":"Giá Bitcoin hôm nay là bao nhiêu?"}'
echo -e "\n"
