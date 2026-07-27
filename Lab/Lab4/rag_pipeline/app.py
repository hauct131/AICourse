from __future__ import annotations

import asyncio
import logging
import os
import re
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
import psycopg
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from migrations import run_migrations
from relevance import RelevanceDecision, evaluate_candidates, meaningful_terms

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

TOP_K = int(os.getenv("TOP_K", "5"))
LOW_CONFIDENCE_THRESHOLD = float(
    os.getenv("LOW_CONFIDENCE_THRESHOLD", "0.50")
)
HIGH_CONFIDENCE_THRESHOLD = float(
    os.getenv("HIGH_CONFIDENCE_THRESHOLD", "0.72")
)
MIN_KEYWORD_OVERLAP = int(os.getenv("MIN_KEYWORD_OVERLAP", "1"))
MIN_KEYWORD_COVERAGE = float(os.getenv("MIN_KEYWORD_COVERAGE", "0.20"))
MAX_CONTEXT_CHUNKS = int(os.getenv("MAX_CONTEXT_CHUNKS", "2"))

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
    retrieval_reason: str | None = None


class RetrievalCandidate(BaseModel):
    source: str
    chunk_index: int
    score: float
    accepted: bool
    reason: str
    overlap_count: int
    query_coverage: float
    matched_terms: list[str]


class RetrievalDebugResponse(BaseModel):
    question: str
    decision: str
    candidates: list[RetrievalCandidate]


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
            embeddings = response.json().get("embeddings")
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


def is_refusal_or_abstention(answer: str) -> bool:
    normalized = answer.lower().strip()
    markers = (
        UNKNOWN_ANSWER.lower(),
        "tôi xin lỗi",
        "tôi không thể",
        "không thể giúp",
        "không có bằng chứng",
        "không đủ bằng chứng",
        "không có thông tin",
        "không đủ thông tin",
    )
    return not normalized or any(marker in normalized for marker in markers)


def split_sentences(text: str) -> list[str]:
    compact = " ".join(text.split())
    parts = re.split(r"(?<=[.!?])\s+|\n+", compact)
    return [part.strip() for part in parts if part.strip()]


def extractive_fallback(
    question: str,
    decision: RelevanceDecision,
) -> str:
    query_terms = meaningful_terms(question)
    ranked: list[tuple[int, float, int, str]] = []

    for candidate in decision.selected:
        for position, sentence in enumerate(split_sentences(candidate.content)):
            overlap = len(query_terms & meaningful_terms(sentence))
            ranked.append((overlap, candidate.score, -position, sentence))

    ranked.sort(reverse=True)
    chosen: list[str] = []

    for overlap, _score, _position, sentence in ranked:
        if overlap <= 0 and chosen:
            continue
        if sentence not in chosen:
            chosen.append(sentence)
        if len(chosen) >= 2:
            break

    if not chosen:
        return UNKNOWN_ANSWER

    answer = " ".join(chosen).strip()
    if answer[-1:] not in ".!?":
        answer += "."
    return answer


async def ollama_generate(prompt: str) -> str:
    timeout = httpx.Timeout(connect=15.0, read=600.0, write=60.0, pool=15.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model": LLM_MODEL,
                "prompt": prompt,
                "stream": False,
                "options": {
                    "temperature": 0.0,
                    "num_predict": 260,
                    "top_p": 0.1,
                    "repeat_penalty": 1.1,
                },
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


app = FastAPI(title="AICourse Local RAG", version="1.1.0", lifespan=lifespan)


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
    except Exception as exc:
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
        "retrieval": {
            "top_k": TOP_K,
            "low_confidence_threshold": LOW_CONFIDENCE_THRESHOLD,
            "high_confidence_threshold": HIGH_CONFIDENCE_THRESHOLD,
            "min_keyword_overlap": MIN_KEYWORD_OVERLAP,
            "min_keyword_coverage": MIN_KEYWORD_COVERAGE,
            "max_context_chunks": MAX_CONTEXT_CHUNKS,
        },
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


async def retrieve(question: str) -> RelevanceDecision:
    query_embedding = (await ollama_embed([question], "search_query"))[0]
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

    return evaluate_candidates(
        question,
        rows,
        low_confidence_threshold=LOW_CONFIDENCE_THRESHOLD,
        high_confidence_threshold=HIGH_CONFIDENCE_THRESHOLD,
        min_keyword_overlap=MIN_KEYWORD_OVERLAP,
        min_keyword_coverage=MIN_KEYWORD_COVERAGE,
        max_context_chunks=MAX_CONTEXT_CHUNKS,
    )


@app.post("/debug/retrieval", response_model=RetrievalDebugResponse)
async def debug_retrieval(request: ChatRequest) -> RetrievalDebugResponse:
    question = request.question.strip()
    try:
        decision = await retrieve(question)
    except Exception as exc:
        LOGGER.exception("Retrieval debug failed")
        raise HTTPException(status_code=503, detail=f"Retrieval lỗi: {exc}") from exc

    return RetrievalDebugResponse(
        question=question,
        decision=decision.reason,
        candidates=[
            RetrievalCandidate(
                source=candidate.source_path,
                chunk_index=candidate.chunk_index,
                score=round(candidate.score, 4),
                accepted=candidate.accepted,
                reason=candidate.reason,
                overlap_count=candidate.overlap_count,
                query_coverage=round(candidate.query_coverage, 4),
                matched_terms=list(candidate.matched_terms),
            )
            for candidate in decision.candidates
        ],
    )


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest) -> ChatResponse:
    question = request.question.strip()

    try:
        decision = await retrieve(question)
    except Exception as exc:
        LOGGER.exception("Query retrieval failed")
        raise HTTPException(status_code=503, detail=f"Retrieval lỗi: {exc}") from exc

    if not decision.selected:
        LOGGER.info(
            "Abstained before generation: reason=%s top_score=%s question=%r",
            decision.reason,
            decision.top_score,
            question,
        )
        return ChatResponse(
            answer=UNKNOWN_ANSWER,
            sources=[],
            top_score=(round(decision.top_score, 4) if decision.top_score is not None else None),
            retrieval_reason=decision.reason,
        )

    context_parts: list[str] = []
    sources: list[str] = []

    for candidate in decision.selected:
        context_parts.append(
            "\n".join(
                [
                    "<EVIDENCE>",
                    (
                        f"source={candidate.source_path}; "
                        f"chunk={candidate.chunk_index}; "
                        f"score={candidate.score:.4f}"
                    ),
                    candidate.content,
                    "</EVIDENCE>",
                ]
            )
        )
        label = f"{candidate.source_path}#chunk-{candidate.chunk_index}"
        if label not in sources:
            sources.append(label)

    context = "\n\n".join(context_parts)
    prompt = (
        "Nhiệm vụ: trả lời trực tiếp câu hỏi bằng tiếng Việt.\n\n"
        "Chỉ sử dụng nội dung trong BẰNG CHỨNG.\n"
        "Không xin lỗi. Không nói về vai trò trợ lý.\n"
        "Không dùng kiến thức bên ngoài và không suy đoán.\n"
        "Nếu bằng chứng không trả lời trực tiếp câu hỏi, chỉ ghi:\n"
        f"{UNKNOWN_ANSWER}\n\n"
        f"CÂU HỎI:\n{question}\n\n"
        f"BẰNG CHỨNG:\n{context}\n\n"
        "TRẢ LỜI NGẮN GỌN:"
    )

    try:
        answer = await ollama_generate(prompt)
    except Exception as exc:
        LOGGER.exception("Generation failed")
        raise HTTPException(status_code=503, detail=f"Local LLM lỗi: {exc}") from exc

    normalized_answer = answer.strip().strip('"').strip()
    if is_refusal_or_abstention(normalized_answer):
        normalized_answer = extractive_fallback(question, decision)

    if normalized_answer == UNKNOWN_ANSWER:
        return ChatResponse(
            answer=UNKNOWN_ANSWER,
            sources=[],
            top_score=round(decision.top_score or 0.0, 4),
            retrieval_reason="extractive_fallback_failed",
        )

    return ChatResponse(
        answer=normalized_answer,
        sources=sources,
        top_score=round(decision.top_score or 0.0, 4),
        retrieval_reason=decision.reason,
    )