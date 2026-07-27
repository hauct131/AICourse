#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/../Lab/Lab1"

docker compose down
docker compose up -d --build
docker compose ps

for _ in {1..30}; do
  if curl -fsS http://localhost:8000/health >/dev/null; then
    echo "Lab 1 healthy: http://localhost:8000"
    exit 0
  fi
  sleep 2
done

echo "Lab 1 health check failed." >&2
docker compose logs --tail=100
exit 1
