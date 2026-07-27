#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"

if [[ -f ./.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

PORT="${RAG_PORT:-8001}"
BASE="http://localhost:${PORT}"

echo "== HEALTH =="
curl -fsS "$BASE/health"
printf '\n\n'

echo "== UPLOAD =="
curl -fsS -F "file=@rag_pipeline/input/sample.md" "$BASE/upload"
printf '\n\n'

echo "== IN-SCOPE QUESTION =="
curl -fsS -X POST "$BASE/chat" \
  -H 'Content-Type: application/json' \
  -d '{"question":"Rule và Skill khác nhau như thế nào?"}'
printf '\n\n'

echo "== OUT-OF-SCOPE QUESTION =="
curl -fsS -X POST "$BASE/chat" \
  -H 'Content-Type: application/json' \
  -d '{"question":"Giá Bitcoin hôm nay là bao nhiêu?"}'
printf '\n'
