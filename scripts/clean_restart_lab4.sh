#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Lab/Lab4"

set -a
# shellcheck disable=SC1091
source ./.env
set +a
PORT="${RAG_PORT:-8001}"

docker compose down --remove-orphans
docker compose up -d pgvector ollama
docker compose --profile setup run --rm model-init
docker compose up -d --build rag-app

echo "Waiting for Lab 4 health endpoint..."
for _ in $(seq 1 120); do
  if curl -fsS "http://localhost:${PORT}/health" >/dev/null 2>&1; then
    echo "Lab 4 healthy: http://localhost:${PORT}"
    ./smoke_test.sh
    exit 0
  fi
  sleep 2
done

echo "Lab 4 health check failed." >&2
docker compose ps
docker compose logs --tail=150 rag-app ollama pgvector
exit 1
