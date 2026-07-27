#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/home/hao/Documents/AI/Course}"
LAB4="$ROOT/Lab/Lab4"
RAG="$LAB4/rag_pipeline"
APP="$RAG/app.py"
REQ="$RAG/requirements.txt"
COMPOSE="$LAB4/docker-compose.yml"
ENV_FILE="$LAB4/.env"
ENV_EXAMPLE="$LAB4/.env.example"

for required in "$LAB4" "$RAG" "$APP" "$REQ" "$COMPOSE" "$ENV_FILE"; do
  if [[ ! -e "$required" ]]; then
    echo "ERROR: Không tìm thấy: $required" >&2
    exit 1
  fi
done

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$LAB4/backups/anti_hallucination_$STAMP"
mkdir -p "$BACKUP_DIR"
cp "$APP" "$BACKUP_DIR/app.py"
cp "$REQ" "$BACKUP_DIR/requirements.txt"
cp "$COMPOSE" "$BACKUP_DIR/docker-compose.yml"
cp "$ENV_FILE" "$BACKUP_DIR/.env"
[[ -f "$ENV_EXAMPLE" ]] && cp "$ENV_EXAMPLE" "$BACKUP_DIR/.env.example"

echo "[1/8] Ghi dependency và relevance gate..."

cat > "$REQ" <<'EOF'
fastapi>=0.115,<1
uvicorn[standard]>=0.34,<1
httpx>=0.28,<1
psycopg[binary]>=3.2,<4
python-multipart>=0.0.20,<1
pydantic>=2.10,<3
stopwordsiso>=0.6,<1
EOF

cat > "$RAG/relevance.py" <<'PY'
"""Deterministic relevance gate before local-LLM generation."""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Sequence

from stopwordsiso import stopwords


def normalize_text(text: str) -> str:
    normalized = unicodedata.normalize("NFD", text.lower())
    without_accents = "".join(
        character
        for character in normalized
        if unicodedata.category(character) != "Mn"
    )
    return re.sub(r"\s+", " ", without_accents).strip()


LIBRARY_STOPWORDS = {
    normalize_text(word)
    for language in ("vi", "en")
    for word in stopwords(language)
}
DOMAIN_STOPWORDS = {
    "anh",
    "ban",
    "giup",
    "hoi",
    "tra loi",
    "thong tin",
    "cho biet",
}
STOPWORDS = LIBRARY_STOPWORDS | {
    token
    for phrase in DOMAIN_STOPWORDS
    for token in normalize_text(phrase).split()
}


def meaningful_terms(text: str) -> set[str]:
    tokens = re.findall(r"[a-z0-9_]+", normalize_text(text))
    return {
        token
        for token in tokens
        if len(token) >= 2
        and token not in STOPWORDS
        and not token.isdigit()
    }


@dataclass(frozen=True)
class CandidateEvaluation:
    content: str
    source_path: str
    chunk_index: int
    score: float
    overlap_count: int
    query_coverage: float
    matched_terms: tuple[str, ...]
    accepted: bool
    reason: str


@dataclass(frozen=True)
class RelevanceDecision:
    selected: tuple[CandidateEvaluation, ...]
    candidates: tuple[CandidateEvaluation, ...]
    reason: str

    @property
    def top_score(self) -> float | None:
        if not self.candidates:
            return None
        return self.candidates[0].score


def evaluate_candidates(
    question: str,
    rows: Sequence[Sequence[Any]],
    *,
    low_confidence_threshold: float,
    high_confidence_threshold: float,
    min_keyword_overlap: int,
    min_keyword_coverage: float,
    max_context_chunks: int,
) -> RelevanceDecision:
    if low_confidence_threshold >= high_confidence_threshold:
        raise ValueError(
            "LOW_CONFIDENCE_THRESHOLD must be lower than "
            "HIGH_CONFIDENCE_THRESHOLD"
        )

    query_terms = meaningful_terms(question)
    evaluations: list[CandidateEvaluation] = []
    selected: list[CandidateEvaluation] = []

    for row in rows:
        content = str(row[0])
        source_path = str(row[1])
        chunk_index = int(row[2])
        score = float(row[3])

        content_terms = meaningful_terms(content)
        matched_terms = tuple(sorted(query_terms & content_terms))
        overlap_count = len(matched_terms)
        query_coverage = (
            overlap_count / len(query_terms)
            if query_terms
            else 0.0
        )

        if score >= high_confidence_threshold:
            accepted = True
            reason = "high_embedding_confidence"
        elif (
            score >= low_confidence_threshold
            and overlap_count >= min_keyword_overlap
            and query_coverage >= min_keyword_coverage
        ):
            accepted = True
            reason = "embedding_plus_lexical_support"
        elif score < low_confidence_threshold:
            accepted = False
            reason = "embedding_score_too_low"
        else:
            accepted = False
            reason = "insufficient_lexical_support"

        evaluation = CandidateEvaluation(
            content=content,
            source_path=source_path,
            chunk_index=chunk_index,
            score=score,
            overlap_count=overlap_count,
            query_coverage=query_coverage,
            matched_terms=matched_terms,
            accepted=accepted,
            reason=reason,
        )
        evaluations.append(evaluation)

        if accepted and len(selected) < max_context_chunks:
            selected.append(evaluation)

    if selected:
        decision_reason = "relevant_context_found"
    elif not evaluations:
        decision_reason = "no_candidates"
    else:
        decision_reason = evaluations[0].reason

    return RelevanceDecision(
        selected=tuple(selected),
        candidates=tuple(evaluations),
        reason=decision_reason,
    )
PY

echo "[2/8] Thay backend bằng phiên bản có abstention gate..."

cat > "$APP" <<'PY'
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
from relevance import RelevanceDecision, evaluate_candidates

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

TOP_K = int(os.getenv("TOP_K", "8"))
LOW_CONFIDENCE_THRESHOLD = float(
    os.getenv("LOW_CONFIDENCE_THRESHOLD", "0.50")
)
HIGH_CONFIDENCE_THRESHOLD = float(
    os.getenv("HIGH_CONFIDENCE_THRESHOLD", "0.68")
)
MIN_KEYWORD_OVERLAP = int(os.getenv("MIN_KEYWORD_OVERLAP", "1"))
MIN_KEYWORD_COVERAGE = float(os.getenv("MIN_KEYWORD_COVERAGE", "0.20"))
MAX_CONTEXT_CHUNKS = int(os.getenv("MAX_CONTEXT_CHUNKS", "3"))

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
    prompt = f"""Bạn là trợ lý hỏi đáp dựa trên bằng chứng.

QUY TẮC BẮT BUỘC:
1. Chỉ dùng sự kiện được viết trực tiếp trong các khối <EVIDENCE>.
2. Không dùng kiến thức có sẵn của mô hình.
3. Không suy đoán, không bổ sung ví dụ hoặc chi tiết không có trong bằng chứng.
4. Nếu bằng chứng không trả lời trực tiếp câu hỏi, chỉ xuất đúng câu:
{UNKNOWN_ANSWER}
5. Nếu có câu trả lời, trả lời tối đa 4 câu bằng tiếng Việt.

CÂU HỎI:
{question}

BẰNG CHỨNG:
{context}

CÂU TRẢ LỜI:"""

    try:
        answer = await ollama_generate(prompt)
    except Exception as exc:
        LOGGER.exception("Generation failed")
        raise HTTPException(status_code=503, detail=f"Local LLM lỗi: {exc}") from exc

    normalized_answer = answer.strip().strip('"').strip()
    if not normalized_answer or UNKNOWN_ANSWER.lower() in normalized_answer.lower():
        return ChatResponse(
            answer=UNKNOWN_ANSWER,
            sources=[],
            top_score=round(decision.top_score or 0.0, 4),
            retrieval_reason="llm_abstained",
        )

    return ChatResponse(
        answer=normalized_answer,
        sources=sources,
        top_score=round(decision.top_score or 0.0, 4),
        retrieval_reason=decision.reason,
    )
PY

echo "[3/8] Cập nhật cấu hình retrieval..."

python3 - "$ENV_FILE" "$ENV_EXAMPLE" <<'PY'
from pathlib import Path
import sys

updates = {
    "TOP_K": "8",
    "LOW_CONFIDENCE_THRESHOLD": "0.50",
    "HIGH_CONFIDENCE_THRESHOLD": "0.68",
    "MIN_KEYWORD_OVERLAP": "1",
    "MIN_KEYWORD_COVERAGE": "0.20",
    "MAX_CONTEXT_CHUNKS": "3",
}

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    if not path.exists():
        continue

    lines = path.read_text(encoding="utf-8").splitlines()
    output: list[str] = []
    seen: set[str] = set()

    for line in lines:
        if "=" in line and not line.lstrip().startswith("#"):
            key = line.split("=", 1)[0].strip()
            if key == "SIMILARITY_THRESHOLD":
                continue
            if key in updates:
                output.append(f"{key}={updates[key]}")
                seen.add(key)
                continue
        output.append(line)

    for key, value in updates.items():
        if key not in seen:
            output.append(f"{key}={value}")

    path.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")
PY

echo "[4/8] Cập nhật docker-compose..."

python3 - "$COMPOSE" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

keys = (
    "SIMILARITY_THRESHOLD",
    "LOW_CONFIDENCE_THRESHOLD",
    "HIGH_CONFIDENCE_THRESHOLD",
    "MIN_KEYWORD_OVERLAP",
    "MIN_KEYWORD_COVERAGE",
    "MAX_CONTEXT_CHUNKS",
)
for key in keys:
    text = re.sub(
        rf"^\s{{6}}{key}:.*\n",
        "",
        text,
        flags=re.MULTILINE,
    )

anchor_pattern = r"^(\s{6}TOP_K:\s*\$\{TOP_K:-[^}]+\}\s*)$"
match = re.search(anchor_pattern, text, flags=re.MULTILINE)
if not match:
    raise SystemExit("Không tìm thấy TOP_K trong rag-app environment")

insert = "\n".join(
    [
        match.group(1),
        "      LOW_CONFIDENCE_THRESHOLD: ${LOW_CONFIDENCE_THRESHOLD:-0.50}",
        "      HIGH_CONFIDENCE_THRESHOLD: ${HIGH_CONFIDENCE_THRESHOLD:-0.68}",
        "      MIN_KEYWORD_OVERLAP: ${MIN_KEYWORD_OVERLAP:-1}",
        "      MIN_KEYWORD_COVERAGE: ${MIN_KEYWORD_COVERAGE:-0.20}",
        "      MAX_CONTEXT_CHUNKS: ${MAX_CONTEXT_CHUNKS:-3}",
    ]
)
text = text[:match.start()] + insert + text[match.end():]
path.write_text(text, encoding="utf-8")
PY

echo "[5/8] Thêm unit test và regression test..."

mkdir -p "$RAG/tests"
touch "$RAG/tests/__init__.py"

cat > "$RAG/tests/test_relevance.py" <<'PY'
from __future__ import annotations

import unittest

from relevance import evaluate_candidates, meaningful_terms


class RelevanceTest(unittest.TestCase):
    def test_stopwords_are_removed(self) -> None:
        terms = meaningful_terms("Bạn hãy cho tôi biết Rule là gì")
        self.assertIn("rule", terms)
        self.assertNotIn("ban", terms)
        self.assertNotIn("cho", terms)

    def test_unrelated_candidate_is_rejected(self) -> None:
        decision = evaluate_candidates(
            "Giá Bitcoin hôm nay là bao nhiêu?",
            [("Rule là chỉ dẫn luôn bật.", "sample.md", 0, 0.54)],
            low_confidence_threshold=0.50,
            high_confidence_threshold=0.68,
            min_keyword_overlap=1,
            min_keyword_coverage=0.20,
            max_context_chunks=3,
        )
        self.assertFalse(decision.selected)

    def test_medium_score_needs_lexical_support(self) -> None:
        decision = evaluate_candidates(
            "Rule khác Skill thế nào?",
            [("Rule luôn bật, còn Skill chỉ được gọi khi cần.", "sample.md", 0, 0.55)],
            low_confidence_threshold=0.50,
            high_confidence_threshold=0.68,
            min_keyword_overlap=1,
            min_keyword_coverage=0.20,
            max_context_chunks=3,
        )
        self.assertEqual(len(decision.selected), 1)

    def test_high_score_can_accept_synonym_case(self) -> None:
        decision = evaluate_candidates(
            "Kỹ năng được kích hoạt khi nào?",
            [("A Skill is invoked only when the task requires it.", "sample.md", 0, 0.72)],
            low_confidence_threshold=0.50,
            high_confidence_threshold=0.68,
            min_keyword_overlap=1,
            min_keyword_coverage=0.20,
            max_context_chunks=3,
        )
        self.assertEqual(len(decision.selected), 1)


if __name__ == "__main__":
    unittest.main()
PY

cat > "$LAB4/test_anti_hallucination.py" <<'PY'
from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

BASE_URL = os.getenv("RAG_BASE_URL", "http://localhost:8001").rstrip("/")
UNKNOWN = "Tôi không biết dựa trên tài liệu đã được cung cấp."


def post_json(path: str, payload: dict[str, str]) -> dict[str, object]:
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.loads(response.read().decode("utf-8"))


def upload_sample() -> None:
    sample = Path(__file__).resolve().parent / "rag_pipeline" / "input" / "sample.md"
    boundary = "----AICourseBoundary"
    content = sample.read_bytes()
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="sample.md"\r\n'
        "Content-Type: text/markdown\r\n\r\n"
    ).encode() + content + f"\r\n--{boundary}--\r\n".encode()

    request = urllib.request.Request(
        f"{BASE_URL}/upload",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        response.read()


def main() -> int:
    upload_sample()

    in_scope_question = "Rule và Skill khác nhau như thế nào?"
    in_scope = post_json("/chat", {"question": in_scope_question})
    print("IN_SCOPE:", json.dumps(in_scope, ensure_ascii=False, indent=2))
    if in_scope.get("answer") == UNKNOWN:
        print("FAIL: Câu hỏi trong tài liệu bị từ chối.", file=sys.stderr)
        debug = post_json("/debug/retrieval", {"question": in_scope_question})
        print(json.dumps(debug, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1

    out_of_scope_questions = [
        "Giá Bitcoin hôm nay là bao nhiêu?",
        "Ngày mai ở Hà Nội có mưa không?",
        "Ai là tổng thống Hoa Kỳ?",
    ]

    failed = False
    for question in out_of_scope_questions:
        result = post_json("/chat", {"question": question})
        print("OUT_OF_SCOPE:", json.dumps(result, ensure_ascii=False, indent=2))
        if result.get("answer") != UNKNOWN or result.get("sources") != []:
            failed = True
            print(f"FAIL: Không abstain: {question}", file=sys.stderr)

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

echo "[6/8] Kiểm tra cú pháp..."
python3 -m py_compile \
  "$RAG/app.py" \
  "$RAG/relevance.py" \
  "$RAG/tests/test_relevance.py" \
  "$LAB4/test_anti_hallucination.py"

echo "[7/8] Build và chạy test..."
cd "$LAB4"
docker compose up -d --build rag-app

RAG_PORT="$(awk -F= '$1 == "RAG_PORT" {print $2}' .env | tail -n 1)"
RAG_PORT="${RAG_PORT:-8001}"
BASE_URL="http://localhost:$RAG_PORT"

echo "Đợi API healthy tại $BASE_URL..."
ready=0
for _ in $(seq 1 90); do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "$ready" -ne 1 ]]; then
  echo "ERROR: RAG API chưa healthy." >&2
  docker compose ps
  docker compose logs --tail=200 rag-app
  exit 1
fi

docker compose exec -T rag-app python -m unittest -v tests.test_relevance
RAG_BASE_URL="$BASE_URL" python3 ./test_anti_hallucination.py

echo "[8/8] Hoàn tất."
echo
echo "UI: $BASE_URL"
echo "Debug retrieval:"
echo "curl -sS -X POST '$BASE_URL/debug/retrieval' \\" 
echo "  -H 'Content-Type: application/json' \\" 
echo "  -d '{\"question\":\"Giá Bitcoin hôm nay là bao nhiêu?\"}'"
echo
echo "Backup: $BACKUP_DIR"
