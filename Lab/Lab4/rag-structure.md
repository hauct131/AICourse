# RAG pipeline — cấu trúc code (bạn tự implement)

> Đây là BỘ KHUNG bạn cần xây. Lab chỉ mô tả **nhiệm vụ từng file** và **luồng dữ liệu** —
> code Python bạn tự viết. Hai "process" (indexing + retrieval) được bọc lại sau một
> lớp `api/` để UI gọi được: **/upload** (nạp file) và **/chat** (hỏi).

```
rag_pipeline/
├── main.py                       # chạy migrations -> start API (uvicorn)
├── input/                        # thả .md vào đây (đọc trực tiếp từ folder này)
├── sql/
│   └── init_rag_db.sql           # schema (documents / chunks / embeddings)
├── migrations.py                 # áp dụng init_rag_db.sql idempotent (re-apply khi SQL đổi)
│
├── config/
│   ├── env_config.py             # đọc biến môi trường (DB, model URL, model name)
│   ├── db_connection.py          # kết nối pgvector (psycopg)
│   └── llm_setup.py              # tạo embedding (nomic) + LLM (llama3.1)
│
├── indexing/                     # ── PROCESS 1: input -> vector DB ──
│   ├── step1_load_input.py       # [Lab1] đọc .md từ input/
│   ├── step2_document_parsing.py # [Lab1] tách frontmatter (---) khỏi body
│   ├── step3_chunking_strategy.py# [Lab1] cắt BODY theo fixed-token (vd 800 token, overlap 120)
│   ├── step4_preprocessing.py    # [Lab1] làm sạch text (bỏ khoảng trắng thừa...)
│   ├── step5_metadata_extraction.py # [Lab2] trích title/date/area/status/tags/description/summary
│   ├── step6_embedding_generation.py# [Lab1] gọi nomic-embed-text -> vector 768
│   ├── step7_store_documents.py  # [Lab1] upsert 1 hàng rag_documents / file
│   ├── step8_store_chunks.py     # [Lab1] lưu rag_chunks + rag_embeddings (chunk + vector)
│   └── index_runner.py           # orchestrate step1..8 cho 1 hoặc nhiều file
│
├── retrieval/                    # ── PROCESS 2: câu hỏi -> câu trả lời ──
│   ├── step1_receive_query.py    # [Lab1] nhận câu hỏi
│   ├── step2_preprocess_query.py # [Lab1] chuẩn hoá câu hỏi
│   ├── step3_query_embedding.py  # [Lab1] embed câu hỏi (nomic)
│   ├── step4_similarity_search.py# [Lab1] top-k theo cosine trên rag_embeddings
│   ├── step5_metadata_filter.py  # [Lab2] pre-filter theo area/status/tags trước khi search
│   ├── step6_reranking.py        # [Lab sau] cross-encoder rerank
│   ├── step7_context_prep.py     # [Lab1] ghép các chunk thành ngữ cảnh (kèm nguồn)
│   ├── step8_prompt_construction.py # [Lab1] dựng prompt "chỉ trả lời dựa trên ngữ cảnh"
│   ├── step9_llm_generation.py   # [Lab1] gọi llama3.1:8b
│   ├── step10_response.py        # [Lab1] trả lời + danh sách nguồn (source_path)
│   └── retrieval_runner.py       # orchestrate step1..10
│
├── api/                          # ── expose 2 process qua HTTP (FastAPI) ──
│   ├── main.py                   # tạo FastAPI app, mount routes, phục vụ ui/
│   ├── routes_upload.py          # POST /upload  -> lưu file vào input/ -> index_runner
│   └── routes_chat.py            # POST /chat    -> retrieval_runner -> {answer, sources}
│
├── ui/
│   └── index.html                # UI đơn giản: khung chat + nút upload (gọi /chat, /upload)
│
└── shared/
    ├── md_frontmatter.py         # parse YAML frontmatter + khối TL;DR (thay cho java_parser cũ)
    ├── file_utils.py             # đọc/ghi file, liệt kê input/
    └── logger.py                 # logging
```

## Hai process, một API

| Process | Chạy khi nào | File chính | Kết quả |
|---------|--------------|-----------|---------|
| **1. Indexing** | khi upload file / chạy nạp thủ công | `indexing/index_runner.py` | chunk + vector đã lưu vào DB |
| **2. Retrieval (chat)** | mỗi lần người dùng hỏi | `retrieval/retrieval_runner.py` | câu trả lời + nguồn |

`api/` bọc cả hai: **POST /upload** gọi Process 1, **POST /chat** gọi Process 2.
UI (`ui/index.html`) chỉ gọi 2 endpoint đó.

## Lộ trình từ dễ → nâng cao (một khung code, nhiều lab)

- **Lab 1 · Basic RAG (buổi này):** chỉ dùng các step gắn `[Lab1]`. Cắt body theo
  fixed-token, embed, lưu, tìm top-k vector, hỏi LLM. Bỏ qua metadata/rerank/hybrid.
- **Lab 2 · Metadata:** bật `step5_metadata_extraction` + `step5_metadata_filter` —
  parse frontmatter/TL;DR vào `rag_documents`, pre-filter theo `area`/`status`/`tags`.
- **Lab 3 · Hybrid:** bật `step6_reranking` + full-text (`content_tsv`) / Elasticsearch,
  hợp nhất kết quả bằng RRF.

## Đã bỏ so với bản nháp

`shared/java_parser.py` và `shared/relationship_tracker.py` là tàn dư của phân tích
mã nguồn — không dùng cho RAG tài liệu .md. Thay bằng `shared/md_frontmatter.py`.
Thêm mới: `api/`, `ui/`, `sql/`, `migrations.py` để đủ cho luồng upload + chat.
