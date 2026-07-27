#!/usr/bin/env bash
set -Eeuo pipefail

# Chạy script này tại thư mục gốc repository AICourse.
ROOT="$(pwd)"

if [[ ! -d "$ROOT/Lab/Lab1" ]]; then
  echo "ERROR: Không thấy Lab/Lab1. Hãy cd vào thư mục gốc AICourse rồi chạy lại." >&2
  exit 1
fi

if [[ ! -f "$ROOT/Lab/lab4-rag.zip" && ! -d "$ROOT/Lab/Lab4" ]]; then
  echo "ERROR: Không thấy Lab/lab4-rag.zip hoặc Lab/Lab4." >&2
  exit 1
fi

printf '\n[1/6] Tạo cấu trúc Rule / Skill / Knowledge...\n'
mkdir -p \
  "$ROOT/.claude/rules" \
  "$ROOT/.claude/skills/clean-restart" \
  "$ROOT/rag-ai-local/QandA" \
  "$ROOT/rag-ai-local/functionality-docs/20260728" \
  "$ROOT/scripts"

cat > "$ROOT/CLAUDE.md" <<'EOF'
# AICourse Project Instructions

- Đọc `.claude/rules/coding-convention.md` trước khi sửa code.
- Không hard-code API key, password hoặc secret.
- Mọi cấu hình phải lấy từ biến môi trường.
- Sau khi sửa backend phải chạy health check.
- RAG chỉ trả lời dựa trên retrieved context.
- Nếu không có bằng chứng phù hợp, trả lời: "Tôi không biết dựa trên tài liệu đã được cung cấp."
EOF

cat > "$ROOT/.claude/rules/coding-convention.md" <<'EOF'
# Coding Convention

1. Mọi hàm Python phải có type hints.
2. Không dùng `print()` trong code backend; dùng `logging`.
3. Không hard-code secret hoặc API key.
4. Không commit file `.env`.
5. API phải có `/health`.
6. Sau mỗi thay đổi phải chạy compile check hoặc smoke test.
7. RAG phải trả kèm nguồn và không được bịa khi thiếu context.
EOF

cat > "$ROOT/.claude/skills/clean-restart/SKILL.md" <<'EOF'
---
name: clean-restart
description: Build lại Docker Compose, khởi động service và kiểm tra health endpoint.
---

# Clean Restart

1. Chạy `docker compose down`.
2. Chạy `docker compose up -d --build`.
3. Chạy `docker compose ps`.
4. Gọi endpoint `/health`.
5. Nếu lỗi, đọc `docker compose logs --tail=100`.
6. Báo service lỗi và log liên quan.
EOF

cat > "$ROOT/rag-ai-local/QandA/20260728_rule_skill_basics.md" <<'EOF'
# Rule, Skill và Knowledge — Q&A

## Rule là gì?
Rule là chỉ dẫn luôn được đưa vào ngữ cảnh. Rule phải ngắn, ổn định và áp dụng cho hầu hết tác vụ.

## Skill là gì?
Skill là quy trình được gọi khi cần, ví dụ build, restart hoặc kiểm tra project.

## Knowledge dùng để làm gì?
Knowledge lưu lỗi lặp lại, quyết định kỹ thuật và cách xử lý đã xác minh để tra cứu lại.

## Khi nào không nên dùng Rule?
Không đưa tài liệu dài, log hoặc kiến thức chỉ dùng cho một tác vụ vào Rule vì làm tăng token và dễ gây xung đột.

## RAG phải làm gì khi không có dữ liệu?
Trả lời: "Tôi không biết dựa trên tài liệu đã được cung cấp."
EOF

cat > "$ROOT/rag-ai-local/functionality-docs/20260728/01_lab_notes_rules_skills.md" <<'EOF'
# Lab Notes — Rules, Skills and Knowledge

## Rule
- Luôn bật.
- Dùng cho quy ước code, bảo mật và hành vi bắt buộc.
- Phải ngắn và không xung đột.

## Skill
- Chỉ gọi khi cần.
- Chứa quy trình nhiều bước có thể lặp lại.
- Ví dụ: clean restart, build and test, generate artifact.

## Knowledge
- Lưu lỗi, nguyên nhân, cách khắc phục và quyết định đã xác minh.
- Nên đặt tên theo ngày và chủ đề để dễ truy vết.
EOF

cat > "$ROOT/scripts/clean_restart_lab1.sh" <<'EOF'
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
EOF
chmod +x "$ROOT/scripts/clean_restart_lab1.sh"

printf '\n[2/6] Chuẩn hóa Lab 4...\n'
if [[ ! -d "$ROOT/Lab/Lab4" ]]; then
  mkdir -p "$ROOT/Lab/Lab4"
  unzip -q "$ROOT/Lab/lab4-rag.zip" -d "$ROOT/Lab/Lab4"
fi

mkdir -p \
  "$ROOT/Lab/Lab4/rag_pipeline/sql" \
  "$ROOT/Lab/Lab4/rag_pipeline/ui" \
  "$ROOT/Lab/Lab4/rag_pipeline/input" \
  "$ROOT/Lab/Lab4/rag_pipeline/config" \
  "$ROOT/Lab/Lab4/rag_pipeline/indexing" \
  "$ROOT/Lab/Lab4/rag_pipeline/retrieval" \
  "$ROOT/Lab/Lab4/rag_pipeline/api" \
  "$ROOT/Lab/Lab4/rag_pipeline/shared"

if [[ -f "$ROOT/Lab/Lab4/init_rag_db.sql" ]]; then
  mv "$ROOT/Lab/Lab4/init_rag_db.sql" "$ROOT/Lab/Lab4/rag_pipeline/sql/init_rag_db.sql"
fi
if [[ -f "$ROOT/Lab/Lab4/migrations.py" ]]; then
  mv "$ROOT/Lab/Lab4/migrations.py" "$ROOT/Lab/Lab4/rag_pipeline/migrations.py"
fi
if [[ -f "$ROOT/Lab/Lab4/ui/index.html" ]]; then
  mv "$ROOT/Lab/Lab4/ui/index.html" "$ROOT/Lab/Lab4/rag_pipeline/ui/index.html"
  rmdir "$ROOT/Lab/Lab4/ui" 2>/dev/null || true
fi

for pkg in config indexing retrieval api shared; do
  touch "$ROOT/Lab/Lab4/rag_pipeline/$pkg/__init__.py"
done

cat > "$ROOT/Lab/Lab4/.env.example" <<'EOF'
POSTGRES_DB=ragdb
POSTGRES_USER=raguser
POSTGRES_PASSWORD=ragpassword
DATABASE_URL=postgresql://raguser:ragpassword@pgvector:5432/ragdb

OLLAMA_LLM_URL=http://llama:11434
OLLAMA_LLM_MODEL=qwen2.5:1.5b
OLLAMA_EMBED_URL=http://embedding:11434
OLLAMA_EMBED_MODEL=nomic-embed-text

TOP_K=4
SIMILARITY_THRESHOLD=0.35
CHUNK_SIZE=800
CHUNK_OVERLAP=120
EOF

cat > "$ROOT/Lab/Lab4/rag_pipeline/input/sample.md" <<'EOF'
# Rule và Skill

Rule là chỉ dẫn luôn được gắn vào ngữ cảnh của AI. Rule phù hợp với các quy ước ngắn, ổn định và luôn phải tuân thủ.

Skill là quy trình được gọi theo yêu cầu. Skill phù hợp với tác vụ nhiều bước như build project, clean restart hoặc kiểm tra hệ thống.

Knowledge lưu lại lỗi thường gặp, quyết định kỹ thuật và cách xử lý đã được xác minh.
EOF

printf '\n[3/6] Bảo vệ secret...\n'
touch "$ROOT/.gitignore"
for pattern in '.env' '.env.*' '!.env.example' '__pycache__/' '*.pyc' '.idea/' '.vscode/' 'Lab/Lab4/pgdata/'; do
  grep -qxF "$pattern" "$ROOT/.gitignore" || echo "$pattern" >> "$ROOT/.gitignore"
done

printf '\n[4/6] Kiểm tra Python hiện có...\n'
python3 -m compileall -q "$ROOT/Lab/Lab1/app" "$ROOT/Lab/Lab4/rag_pipeline"

printf '\n[5/6] Kiểm tra file bắt buộc...\n'
required=(
  "$ROOT/CLAUDE.md"
  "$ROOT/.claude/rules/coding-convention.md"
  "$ROOT/.claude/skills/clean-restart/SKILL.md"
  "$ROOT/rag-ai-local/QandA/20260728_rule_skill_basics.md"
  "$ROOT/Lab/Lab4/rag_pipeline/migrations.py"
  "$ROOT/Lab/Lab4/rag_pipeline/sql/init_rag_db.sql"
  "$ROOT/Lab/Lab4/rag_pipeline/ui/index.html"
)
for file in "${required[@]}"; do
  [[ -f "$file" ]] || { echo "ERROR: Thiếu $file" >&2; exit 1; }
done

printf '\n[6/6] Hoàn tất. Cấu trúc hiện tại:\n'
find "$ROOT/.claude" "$ROOT/rag-ai-local" "$ROOT/Lab/Lab4" -maxdepth 4 -type f | sort

printf '\nGit status:\n'
git status --short 2>/dev/null || true

cat <<'EOF'

PHASE 1 COMPLETE
Tiếp theo cần viết code chạy thật cho Lab 4: docker-compose + upload/index + retrieval/chat.
EOF
