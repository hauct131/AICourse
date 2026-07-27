#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(pwd)"
LAB4="$ROOT/Lab/Lab4"
RAG="$LAB4/rag_pipeline"

if [[ ! -d "$ROOT/Lab/Lab1" || ! -d "$LAB4" ]]; then
  echo "ERROR: Hãy chạy tại thư mục gốc AICourse, nơi có Lab/Lab1 và Lab/Lab4." >&2
  exit 1
fi

printf '\n[1/8] Tạo cấu hình Lab 4...\n'
mkdir -p "$RAG"/{api,config,indexing,retrieval,shared,input,sql,ui}

cat > "$LAB4/.env.example" <<'EOF'
POSTGRES_DB=ragdb
POSTGRES_USER=raguser
POSTGRES_PASSWORD=ragpassword

OLLAMA_LLM_MODEL=llama3.2:1b
OLLAMA_EMBED_MODEL=nomic-embed-text

RAG_PORT=8001
TOP_K=4
SIMILARITY_THRESHOLD=0.35
CHUNK_SIZE=800
CHUNK_OVERLAP=120
MAX_UPLOAD_BYTES=5242880
EOF

if [[ ! -f "$LAB4/.env" ]]; then
  cp "$LAB4/.env.example" "$LAB4/.env"
  echo "Đã tạo Lab/Lab4/.env từ .env.example"
else
  echo "Giữ nguyên Lab/Lab4/.env hiện có"
fi

cat > "$LAB4/docker-compose.yml" <<'YAML'
services:
  pgvector:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-ragdb}
      POSTGRES_USER: ${POSTGRES_USER:-raguser}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-ragpassword}
    volumes:
      - pgvector_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-raguser} -d ${POSTGRES_DB:-ragdb}"]
      interval: 5s
      timeout: 5s
      retries: 30
    restart: unless-stopped

  ollama:
    image: ollama/ollama:latest
    volumes:
      - ollama_data:/root/.ollama
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 5s
      timeout: 5s
      retries: 30
    restart: unless-stopped

  model-init:
    image: curlimages/curl:8.10.1
    profiles: ["setup"]
    depends_on:
      ollama:
        condition: service_healthy
    environment:
      OLLAMA_LLM_MODEL: ${OLLAMA_LLM_MODEL:-llama3.2:1b}
      OLLAMA_EMBED_MODEL: ${OLLAMA_EMBED_MODEL:-nomic-embed-text}
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -eu
        echo "Pull embedding model: $$OLLAMA_EMBED_MODEL"
        curl -fsS -H 'Content-Type: application/json' \
          http://ollama:11434/api/pull \
          -d "{\"name\":\"$$OLLAMA_EMBED_MODEL\",\"stream\":false}"
        echo
        echo "Pull chat model: $$OLLAMA_LLM_MODEL"
        curl -fsS -H 'Content-Type: application/json' \
          http://ollama:11434/api/pull \
          -d "{\"name\":\"$$OLLAMA_LLM_MODEL\",\"stream\":false}"
        echo
        echo "Models ready."

  rag-app:
    build:
      context: ./rag_pipeline
    environment:
      DATABASE_URL: postgresql://${POSTGRES_USER:-raguser}:${POSTGRES_PASSWORD:-ragpassword}@pgvector:5432/${POSTGRES_DB:-ragdb}
      OLLAMA_URL: http://ollama:11434
      OLLAMA_LLM_MODEL: ${OLLAMA_LLM_MODEL:-llama3.2:1b}
      OLLAMA_EMBED_MODEL: ${OLLAMA_EMBED_MODEL:-nomic-embed-text}
      EMBEDDING_DIM: "768"
      TOP_K: ${TOP_K:-4}
      SIMILARITY_THRESHOLD: ${SIMILARITY_THRESHOLD:-0.35}
      CHUNK_SIZE: ${CHUNK_SIZE:-800}
      CHUNK_OVERLAP: ${CHUNK_OVERLAP:-120}
      MAX_UPLOAD_BYTES: ${MAX_UPLOAD_BYTES:-5242880}
    depends_on:
      pgvector:
        condition: service_healthy
      ollama:
        condition: service_healthy
    ports:
      - "${RAG_PORT:-8001}:8000"
    volumes:
      - ./rag_pipeline/input:/app/input
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=5)"]
      interval: 5s
      timeout: 5s
      retries: 30
    restart: unless-stopped

volumes:
  pgvector_data:
  ollama_data:
YAML

printf '\n[2/8] Tạo Python backend...\n'
cat > "$RAG/requirements.txt" <<'EOF'
fastapi>=0.115,<1
uvicorn[standard]>=0.34,<1
httpx>=0.28,<1
psycopg[binary]>=3.2,<4
python-multipart>=0.0.20,<1
pydantic>=2.10,<3
EOF

cat > "$RAG/Dockerfile" <<'EOF'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat > "$RAG/migrations.py" <<'PY'
"""Idempotent database migration runner for Lab 4."""
from __future__ import annotations

import hashlib
import logging
import os
from pathlib import Path

import psycopg

LOGGER = logging.getLogger(__name__)
SQL_FILE = Path(__file__).resolve().parent / "sql" / "init_rag_db.sql"
EMBEDDING_DIM = int(os.getenv("EMBEDDING_DIM", "768"))
DATABASE_URL = os.environ["DATABASE_URL"]


def run_migrations() -> None:
    sql = SQL_FILE.read_text(encoding="utf-8")
    sql = sql.replace("{{EMBEDDING_DIM}}", str(EMBEDDING_DIM))
    file_hash = hashlib.sha256(sql.encode("utf-8")).hexdigest()
    migration_name = SQL_FILE.name

    with psycopg.connect(DATABASE_URL) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    name TEXT PRIMARY KEY,
                    file_hash TEXT NOT NULL,
                    applied_at TIMESTAMP DEFAULT NOW()
                )
                """
            )
            cursor.execute(
                "SELECT file_hash FROM schema_migrations WHERE name = %s",
                (migration_name,),
            )
            row = cursor.fetchone()
            if row and row[0] == file_hash:
                LOGGER.info("Migration %s unchanged", migration_name)
                return

            LOGGER.info("Applying %s with embedding dimension %s", migration_name, EMBEDDING_DIM)
            cursor.execute(sql)
            cursor.execute(
                """
                INSERT INTO schema_migrations(name, file_hash)
                VALUES (%s, %s)
                ON CONFLICT(name) DO UPDATE
                SET file_hash = EXCLUDED.file_hash, applied_at = NOW()
                """,
                (migration_name, file_hash),
            )
        connection.commit()
PY

cat > "$RAG/sql/init_rag_db.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS rag_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_path TEXT NOT NULL UNIQUE,
    raw_content TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS rag_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES rag_documents(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    content TEXT NOT NULL,
    token_count INT NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(document_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS idx_rag_chunks_document
ON rag_chunks(document_id);

CREATE TABLE IF NOT EXISTS rag_embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chunk_id UUID NOT NULL UNIQUE REFERENCES rag_chunks(id) ON DELETE CASCADE,
    embedding vector({{EMBEDDING_DIM}}) NOT NULL,
    model VARCHAR(100) NOT NULL,
    indexed_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rag_embeddings_chunk
ON rag_embeddings(chunk_id);

CREATE OR REPLACE FUNCTION rag_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_rag_documents_updated ON rag_documents;
CREATE TRIGGER trg_rag_documents_updated
BEFORE UPDATE ON rag_documents
FOR EACH ROW EXECUTE FUNCTION rag_touch_updated_at();
SQL

cat > "$RAG/app.py" <<'PY'
from __future__ import annotations

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
import psycopg
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from migrations import run_migrations

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
LOGGER = logging.getLogger("rag-app")

BASE_DIR = Path(__file__).resolve().parent
INPUT_DIR = BASE_DIR / "input"
UI_FILE = BASE_DIR / "ui" / "index.html"

DATABASE_URL = os.environ["DATABASE_URL"]
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434").rstrip("/")
LLM_MODEL = os.getenv("OLLAMA_LLM_MODEL", "llama3.2:1b")
EMBED_MODEL = os.getenv("OLLAMA_EMBED_MODEL", "nomic-embed-text")
TOP_K = int(os.getenv("TOP_K", "4"))
SIMILARITY_THRESHOLD = float(os.getenv("SIMILARITY_THRESHOLD", "0.35"))
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "800"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "120"))
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_BYTES", "5242880"))
UNKNOWN_ANSWER = "Tôi không biết dựa trên tài liệu đã được cung cấp."


class ChatRequest(BaseModel):
    question: str = Field(min_length=2, max_length=4000)


class ChatResponse(BaseModel):
    answer: str
    sources: list[str]
    top_score: float | None = None


def get_connection() -> psycopg.Connection[Any]:
    return psycopg.connect(DATABASE_URL)


def vector_literal(vector: list[float]) -> str:
    return "[" + ",".join(f"{value:.9f}" for value in vector) + "]"


def chunk_text(text: str) -> list[str]:
    normalized = "\n".join(line.rstrip() for line in text.splitlines()).strip()
    if not normalized:
        return []

    chunks: list[str] = []
    start = 0
    while start < len(normalized):
        end = min(start + CHUNK_SIZE, len(normalized))
        if end < len(normalized):
            boundary = max(
                normalized.rfind("\n\n", start, end),
                normalized.rfind(". ", start, end),
                normalized.rfind("\n", start, end),
            )
            if boundary > start + CHUNK_SIZE // 2:
                end = boundary + 1
        chunk = normalized[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= len(normalized):
            break
        start = max(end - CHUNK_OVERLAP, start + 1)
    return chunks


async def ollama_embed(texts: list[str], prefix: str) -> list[list[float]]:
    prepared = [f"{prefix}: {text}" for text in texts]
    timeout = httpx.Timeout(connect=15.0, read=300.0, write=60.0, pool=15.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(
            f"{OLLAMA_URL}/api/embed",
            json={"model": EMBED_MODEL, "input": prepared},
        )
        if response.status_code < 400:
            data = response.json()
            embeddings = data.get("embeddings")
            if isinstance(embeddings, list) and len(embeddings) == len(texts):
                return embeddings

        LOGGER.warning("Batch embedding endpoint unavailable; using compatibility endpoint")
        embeddings: list[list[float]] = []
        for text in prepared:
            legacy = await client.post(
                f"{OLLAMA_URL}/api/embeddings",
                json={"model": EMBED_MODEL, "prompt": text},
            )
            legacy.raise_for_status()
            embedding = legacy.json().get("embedding")
            if not isinstance(embedding, list):
                raise RuntimeError("Ollama did not return an embedding vector")
            embeddings.append(embedding)
        return embeddings


async def ollama_generate(prompt: str) -> str:
    timeout = httpx.Timeout(connect=15.0, read=600.0, write=60.0, pool=15.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model": LLM_MODEL,
                "prompt": prompt,
                "stream": False,
                "options": {"temperature": 0.0, "num_predict": 350},
            },
        )
        response.raise_for_status()
        answer = str(response.json().get("response", "")).strip()
        return answer or UNKNOWN_ANSWER


def wait_for_database() -> None:
    last_error: Exception | None = None
    for _ in range(60):
        try:
            run_migrations()
            return
        except (psycopg.OperationalError, psycopg.errors.DatabaseError) as exc:
            last_error = exc
            LOGGER.info("Database not ready yet: %s", exc)
            import time

            time.sleep(2)
    raise RuntimeError("Database did not become ready") from last_error


@asynccontextmanager
async def lifespan(_: FastAPI):
    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    await asyncio.to_thread(wait_for_database)
    LOGGER.info("RAG app ready: LLM=%s embedding=%s", LLM_MODEL, EMBED_MODEL)
    yield


app = FastAPI(title="AICourse Local RAG", version="1.0.0", lifespan=lifespan)


@app.get("/", include_in_schema=False)
async def home() -> FileResponse:
    return FileResponse(UI_FILE)


@app.get("/health")
async def health() -> dict[str, Any]:
    database_ok = False
    ollama_ok = False
    models: list[str] = []

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                database_ok = cursor.fetchone() == (1,)
    except Exception as exc:  # health endpoint must report instead of crash
        LOGGER.warning("Database health failed: %s", exc)

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(f"{OLLAMA_URL}/api/tags")
            response.raise_for_status()
            models = [str(item.get("name")) for item in response.json().get("models", [])]
            ollama_ok = True
    except Exception as exc:
        LOGGER.warning("Ollama health failed: %s", exc)

    return {
        "status": "ok" if database_ok and ollama_ok else "degraded",
        "database": database_ok,
        "ollama": ollama_ok,
        "llm_model": LLM_MODEL,
        "embedding_model": EMBED_MODEL,
        "available_models": models,
    }


@app.post("/upload")
async def upload(file: UploadFile = File(...)) -> dict[str, Any]:
    original_name = Path(file.filename or "document.md").name
    suffix = Path(original_name).suffix.lower()
    if suffix not in {".md", ".txt"}:
        raise HTTPException(status_code=400, detail="Chỉ hỗ trợ file .md hoặc .txt")

    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="File rỗng")
    if len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="File vượt quá giới hạn dung lượng")

    try:
        content = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise HTTPException(status_code=400, detail="File phải dùng UTF-8") from exc

    chunks = chunk_text(content)
    if not chunks:
        raise HTTPException(status_code=400, detail="Không tạo được chunk từ file")

    try:
        embeddings = await ollama_embed(chunks, "search_document")
    except Exception as exc:
        LOGGER.exception("Embedding failed")
        raise HTTPException(status_code=503, detail=f"Embedding model lỗi: {exc}") from exc

    saved_path = INPUT_DIR / original_name
    saved_path.write_text(content, encoding="utf-8")

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO rag_documents(source_path, raw_content)
                VALUES (%s, %s)
                ON CONFLICT(source_path) DO UPDATE
                SET raw_content = EXCLUDED.raw_content, updated_at = NOW()
                RETURNING id
                """,
                (original_name, content),
            )
            document_id = cursor.fetchone()[0]
            cursor.execute("DELETE FROM rag_chunks WHERE document_id = %s", (document_id,))

            for index, (chunk, embedding) in enumerate(zip(chunks, embeddings, strict=True)):
                cursor.execute(
                    """
                    INSERT INTO rag_chunks(document_id, chunk_index, content, token_count)
                    VALUES (%s, %s, %s, %s)
                    RETURNING id
                    """,
                    (document_id, index, chunk, len(chunk.split())),
                )
                chunk_id = cursor.fetchone()[0]
                cursor.execute(
                    """
                    INSERT INTO rag_embeddings(chunk_id, embedding, model)
                    VALUES (%s, %s::vector, %s)
                    """,
                    (chunk_id, vector_literal(embedding), EMBED_MODEL),
                )
        connection.commit()

    return {
        "document": original_name,
        "chunks_indexed": len(chunks),
        "embedding_model": EMBED_MODEL,
    }


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest) -> ChatResponse:
    question = request.question.strip()
    try:
        query_embedding = (await ollama_embed([question], "search_query"))[0]
    except Exception as exc:
        LOGGER.exception("Query embedding failed")
        raise HTTPException(status_code=503, detail=f"Embedding model lỗi: {exc}") from exc

    query_vector = vector_literal(query_embedding)
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                WITH query AS (SELECT %s::vector AS embedding)
                SELECT
                    chunks.content,
                    documents.source_path,
                    chunks.chunk_index,
                    1 - (embeddings.embedding <=> query.embedding) AS score
                FROM rag_embeddings AS embeddings
                JOIN rag_chunks AS chunks ON chunks.id = embeddings.chunk_id
                JOIN rag_documents AS documents ON documents.id = chunks.document_id
                CROSS JOIN query
                ORDER BY embeddings.embedding <=> query.embedding
                LIMIT %s
                """,
                (query_vector, TOP_K),
            )
            rows = cursor.fetchall()

    if not rows:
        return ChatResponse(answer=UNKNOWN_ANSWER, sources=[], top_score=None)

    top_score = float(rows[0][3])
    if top_score < SIMILARITY_THRESHOLD:
        return ChatResponse(answer=UNKNOWN_ANSWER, sources=[], top_score=round(top_score, 4))

    context_parts: list[str] = []
    sources: list[str] = []
    for content, source_path, chunk_index, score in rows:
        score_value = float(score)
        context_parts.append(
            f"[Nguồn: {source_path}, chunk {chunk_index}, score {score_value:.4f}]\n{content}"
        )
        label = f"{source_path}#chunk-{chunk_index}"
        if label not in sources:
            sources.append(label)

    prompt = f"""Bạn là trợ lý RAG cẩn thận.
Chỉ trả lời dựa trên CONTEXT bên dưới.
Không dùng kiến thức bên ngoài.
Nếu CONTEXT không đủ để trả lời, hãy trả lời chính xác:
{UNKNOWN_ANSWER}

CONTEXT:
{chr(10).join(context_parts)}

QUESTION:
{question}

Trả lời ngắn gọn bằng tiếng Việt và không tự tạo nguồn."""

    try:
        answer = await ollama_generate(prompt)
    except Exception as exc:
        LOGGER.exception("Generation failed")
        raise HTTPException(status_code=503, detail=f"Local LLM lỗi: {exc}") from exc

    return ChatResponse(answer=answer, sources=sources, top_score=round(top_score, 4))
PY

printf '\n[3/8] Tạo dữ liệu và smoke test...\n'
cat > "$RAG/input/sample.md" <<'EOF'
# Rule, Skill và Knowledge

Rule là chỉ dẫn luôn được gắn vào ngữ cảnh của AI. Rule phù hợp với quy ước ngắn, ổn định và luôn phải tuân thủ. Rule quá dài làm tăng token và có thể gây xung đột ngữ cảnh.

Skill là quy trình chỉ được gọi khi cần. Skill phù hợp với tác vụ nhiều bước như build project, clean restart, tạo PDF hoặc kiểm tra hệ thống.

Knowledge lưu lỗi thường gặp, quyết định kỹ thuật và cách xử lý đã được xác minh. Knowledge không cần luôn nằm trong context mà được truy xuất khi có câu hỏi liên quan.

Khi hệ thống RAG không tìm thấy dữ liệu phù hợp, hệ thống phải trả lời rằng không biết dựa trên tài liệu đã được cung cấp thay vì bịa thông tin.
EOF

cat > "$LAB4/smoke_test.sh" <<'EOF'
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
EOF
chmod +x "$LAB4/smoke_test.sh"

cat > "$ROOT/scripts/clean_restart_lab4.sh" <<'EOF'
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
EOF
chmod +x "$ROOT/scripts/clean_restart_lab4.sh"

printf '\n[4/8] Dọn file cache và cập nhật .gitignore...\n'
find "$LAB4" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$LAB4" -type f -name '*.pyc' -delete

touch "$ROOT/.gitignore"
for pattern in \
  '.env' \
  '.env.*' \
  '!.env.example' \
  '__pycache__/' \
  '*.pyc' \
  'AICourse-review.zip' \
  'Lab/lab4-rag/' \
  'Lab/Lab4/pgdata/'; do
  grep -qxF "$pattern" "$ROOT/.gitignore" || echo "$pattern" >> "$ROOT/.gitignore"
done

printf '\n[5/8] Kiểm tra cú pháp...\n'
python3 -m py_compile "$RAG/app.py" "$RAG/migrations.py"
bash -n "$LAB4/smoke_test.sh" "$ROOT/scripts/clean_restart_lab4.sh"
find "$LAB4" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$LAB4" -type f -name '*.pyc' -delete

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  (cd "$LAB4" && docker compose config --quiet)
else
  echo "Không tìm thấy Docker Compose; chỉ tạo file, chưa kiểm tra compose."
fi

printf '\n[6/8] Các file đã tạo...\n'
find "$LAB4" -maxdepth 3 -type f | sort

printf '\n[7/8] Khởi động Lab 4...\n'
if [[ "${RUN_DOCKER:-1}" == "1" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Không tìm thấy docker." >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon chưa chạy hoặc user chưa có quyền truy cập Docker." >&2
    exit 1
  fi
  "$ROOT/scripts/clean_restart_lab4.sh"
else
  echo "RUN_DOCKER=0 nên bỏ qua bước chạy container."
fi

printf '\n[8/8] Hoàn tất.\n'
echo "UI Lab 4: http://localhost:${RAG_PORT:-8001}"
echo "Xem log: cd Lab/Lab4 && docker compose logs -f rag-app"
echo "Chạy lại: ./scripts/clean_restart_lab4.sh"
