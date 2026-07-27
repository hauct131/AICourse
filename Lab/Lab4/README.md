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
