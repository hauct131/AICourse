#!/usr/bin/env bash
set -Eeuo pipefail

LAB4="${1:-/home/hao/Documents/AI/Course/Lab/Lab4}"

if [[ ! -d "$LAB4/rag_pipeline" || ! -f "$LAB4/docker-compose.yml" ]]; then
  echo "ERROR: Không tìm thấy Lab4 hợp lệ tại: $LAB4" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/tmp/Lab4_before_submission_${STAMP}.tar.gz"
tar -czf "$BACKUP" -C "$(dirname "$LAB4")" "$(basename "$LAB4")"

echo "[1/8] Xóa file tạm, cache và cấu hình thật..."
rm -f "$LAB4/.env"
rm -rf "$LAB4/backups" "$LAB4/__pycache__"
find "$LAB4" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$LAB4" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

# Hai thư mục model cũ không được docker-compose hiện tại sử dụng và còn
# tham chiếu llama3.1:8b, dễ gây nhầm với cấu hình thật.
rm -rf \
  "$LAB4/llm-llama-3-8b" \
  "$LAB4/llm-nomic-embed-text"

echo "[2/8] Đồng bộ .env.example với cấu hình đã test..."

cat > "$LAB4/.env.example" <<'EOF'
POSTGRES_DB=ragdb
POSTGRES_USER=raguser
POSTGRES_PASSWORD=change-me-for-non-local-use

OLLAMA_LLM_MODEL=llama3.2:1b
OLLAMA_EMBED_MODEL=nomic-embed-text

RAG_PORT=8001
TOP_K=8
CHUNK_SIZE=800
CHUNK_OVERLAP=120
MAX_UPLOAD_BYTES=5242880

LOW_CONFIDENCE_THRESHOLD=0.56
HIGH_CONFIDENCE_THRESHOLD=0.72
MIN_KEYWORD_OVERLAP=2
MIN_KEYWORD_COVERAGE=0.50
MAX_CONTEXT_CHUNKS=3
EOF

echo "[3/8] Làm docker-compose chạy được từ máy mới..."

python3 - "$LAB4/docker-compose.yml" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Đồng bộ defaults với cấu hình adaptive filter đã test.
defaults = {
    "TOP_K": "8",
    "LOW_CONFIDENCE_THRESHOLD": "0.56",
    "HIGH_CONFIDENCE_THRESHOLD": "0.72",
    "MIN_KEYWORD_OVERLAP": "2",
    "MIN_KEYWORD_COVERAGE": "0.50",
    "MAX_CONTEXT_CHUNKS": "3",
}

for key, value in defaults.items():
    pattern = rf"^(\s{{6}}{re.escape(key)}:).*$"
    replacement = rf"\1 ${{{key}:-{value}}}"
    text, count = re.subn(
        pattern,
        replacement,
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise SystemExit(f"Không tìm thấy biến {key} trong docker-compose.yml")

# Model init phải chạy tự động, không phụ thuộc profile setup.
text = text.replace(
    '    profiles: ["setup"]\n',
    '    restart: "no"\n',
    1,
)

depends_old = """    depends_on:
      pgvector:
        condition: service_healthy
      ollama:
        condition: service_healthy
"""
depends_new = """    depends_on:
      pgvector:
        condition: service_healthy
      ollama:
        condition: service_healthy
      model-init:
        condition: service_completed_successfully
"""
if "condition: service_completed_successfully" not in text:
    if depends_old not in text:
        raise SystemExit("Không tìm thấy depends_on của rag-app")
    text = text.replace(depends_old, depends_new, 1)

path.write_text(text, encoding="utf-8")
PY

echo "[4/8] Sửa smoke test và UI..."

cat > "$LAB4/smoke_test.sh" <<'EOF'
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
EOF
chmod +x "$LAB4/smoke_test.sh"

python3 - "$LAB4/rag_pipeline/ui/index.html" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    "Backend: POST /chat · POST /upload — chạy ở cùng origin (http://localhost:8000)",
    "Backend: POST /chat · POST /upload — chạy cùng origin với giao diện",
)
path.write_text(text, encoding="utf-8")
PY

echo "[5/8] Thêm README và ignore files..."

cat > "$LAB4/README.md" <<'EOF'
# Lab 4 — Local RAG với Ollama và pgvector

Ứng dụng RAG tối giản chạy hoàn toàn local:

1. Upload tài liệu Markdown hoặc TXT.
2. Chia tài liệu thành các chunk.
3. Sinh embedding bằng `nomic-embed-text`.
4. Lưu vector và nội dung vào PostgreSQL + pgvector.
5. Embed câu hỏi, tìm các chunk liên quan bằng cosine similarity.
6. Dùng relevance gate để từ chối câu hỏi ngoài phạm vi.
7. Gọi `llama3.2:1b` để trả lời và hiển thị nguồn.

## Kiến trúc

- `pgvector`: lưu tài liệu, chunk và vector embedding.
- `ollama`: chạy embedding model và local chat model.
- `model-init`: tự động tải hai model khi khởi động lần đầu.
- `rag-app`: FastAPI, upload/indexing, retrieval, generation và UI.

Bản lab giới hạn thời gian nên các bước indexing, retrieval và API được gộp
trong `rag_pipeline/app.py`. `rag-structure.md` là kiến trúc tham chiếu để mở
rộng thành nhiều module trong các lab tiếp theo.

## Yêu cầu

- Docker Engine
- Docker Compose v2
- Khoảng trống đĩa đủ để tải các model Ollama

## Chạy ứng dụng

Có thể chạy bằng cấu hình mặc định:

```bash
docker compose up -d --build
```

Hoặc tùy chỉnh:

```bash
cp .env.example .env
docker compose up -d --build
```

Lần chạy đầu, service `model-init` sẽ tải:

- `nomic-embed-text`
- `llama3.2:1b`

Kiểm tra:

```bash
docker compose ps
docker compose logs --tail=100 model-init rag-app
curl http://localhost:8001/health
```

Mở giao diện:

```text
http://localhost:8001
```

## Smoke test

```bash
./smoke_test.sh
```

## Regression test chống ảo giác

Khi ứng dụng đang chạy:

```bash
python3 test_anti_hallucination.py
```

Test yêu cầu:

- Câu hỏi có trong `sample.md` phải trả lời và có nguồn.
- Câu Bitcoin, thời tiết và tổng thống phải trả:
  `Tôi không biết dựa trên tài liệu đã được cung cấp.`

## API

- `GET /health`
- `POST /upload`
- `POST /chat`
- `POST /debug/retrieval`

Ví dụ:

```bash
curl -F "file=@rag_pipeline/input/sample.md" \
  http://localhost:8001/upload

curl -X POST http://localhost:8001/chat \
  -H "Content-Type: application/json" \
  -d '{"question":"Rule và Skill khác nhau như thế nào?"}'
```

## Giới hạn hiện tại

- Chỉ hỗ trợ `.md` và `.txt` UTF-8.
- Chưa có OCR, PDF, reranking hoặc hybrid search.
- Ngưỡng relevance được tinh chỉnh cho tập tài liệu lab; khi thay corpus lớn
  cần đánh giá lại trên bộ câu hỏi in-scope và out-of-scope.
EOF

cat > "$LAB4/.gitignore" <<'EOF'
.env
backups/
__pycache__/
*.py[cod]
.pytest_cache/
.DS_Store
EOF

cat > "$LAB4/rag_pipeline/.dockerignore" <<'EOF'
__pycache__/
*.py[cod]
tests/__pycache__/
.pytest_cache/
EOF

python3 - "$LAB4/rag-structure.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
note = (
    "> **Ghi chú bản nộp:** Đây là kiến trúc tham chiếu ban đầu. "
    "Để hoàn thành lab trong thời gian giới hạn, bản chạy thật gộp "
    "indexing, retrieval và API vào `rag_pipeline/app.py`.\n\n"
)
if note not in text:
    lines = text.splitlines(keepends=True)
    if lines:
        lines.insert(1, "\n" + note)
        text = "".join(lines)
    else:
        text = note
path.write_text(text, encoding="utf-8")
PY

echo "[6/8] Chạy kiểm tra tĩnh..."

python3 -m compileall -q \
  "$LAB4/rag_pipeline" \
  "$LAB4/test_anti_hallucination.py"

# compileall tạo bytecode; xóa lại để ZIP không chứa cache.
find "$LAB4" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$LAB4" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

bash -n "$LAB4/smoke_test.sh"

python3 - "$LAB4/docker-compose.yml" <<'PY'
from pathlib import Path
import sys
import yaml

path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text(encoding="utf-8"))
services = set(data.get("services", {}))
required = {"pgvector", "ollama", "model-init", "rag-app"}
missing = required - services
if missing:
    raise SystemExit(f"Thiếu services: {sorted(missing)}")
print("docker-compose.yml: YAML hợp lệ")
PY

echo "[7/8] Kiểm tra không còn file không nên nộp..."

bad_files="$(
  find "$LAB4" \
    \( -name '.env' -o -name '*.pyc' -o -name '*.pyo' -o -name '__pycache__' -o -name 'backups' \) \
    -print
)"
if [[ -n "$bad_files" ]]; then
  echo "ERROR: Còn file không nên nộp:" >&2
  echo "$bad_files" >&2
  exit 1
fi

echo "[8/8] Đóng gói ZIP sạch..."

OUTPUT="$(dirname "$LAB4")/Lab4-submission.zip"
rm -f "$OUTPUT"
(
  cd "$(dirname "$LAB4")"
  zip -qr "$OUTPUT" "$(basename "$LAB4")"
)

unzip -t "$OUTPUT" >/dev/null

echo
echo "DONE"
echo "Backup trước khi dọn: $BACKUP"
echo "ZIP để nộp: $OUTPUT"
echo
echo "Trước khi push, chạy trên máy của bạn:"
echo "  cd \"$LAB4\""
echo "  docker compose up -d --build"
echo "  ./smoke_test.sh"
echo "  python3 test_anti_hallucination.py"
