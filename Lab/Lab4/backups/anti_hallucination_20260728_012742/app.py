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
