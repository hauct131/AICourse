# Vietnamese Labor Law RAG

## Corpus thống nhất 2026-07-27

Project hiện đọc một release duy nhất:

```text
data/releases/labor-law-2026-07-27-candidate/
├── articles.json
├── chunks.jsonl
├── source_inventory.json
├── legal_effect_review.json
├── approval.json
├── manifest.json
├── SHA256SUMS.txt
└── sources/official_docx/
```

Kết quả kiểm tra kỹ thuật:

- 18 văn bản;
- 513 đơn vị truy hồi;
- 778 chunk;
- đủ 220/220 Điều của `18/VBHN-VPQH`;
- `66.18/2026/NQ-CP`: Điều 4, Điều 6 và sáu đơn vị Phụ lục I.4 dùng
  trong golden current-law;
- 45/45 câu golden v3 đã được bind lại vào chunk ID của release;
- hash nguồn, hash release, coverage và mã Điều đều đạt validator.

Release này chưa được phép gọi là production: 16 snapshot VBPL thiếu checksum
inventory/raw API response, kiểm tra E5 hard limit chưa chạy và duyệt hiệu lực
bởi người có thẩm quyền vẫn đang chờ. Vì vậy `/api/health` chỉ kiểm liveness,
còn `/api/ready` chủ động trả `503 authority_review_pending`.

Xem giải thích nguồn dữ liệu tại:

```text
docs/data/DATA_PROVENANCE_2026-07-27.md
```

Kiểm tra release hiện có:

```bash
make unified-release-validate PYTHON=python3
```

Muốn tạo candidate mới, chọn thư mục release mới để không ghi đè:

```bash
make unified-release \
  PYTHON=python3 \
  UNIFIED_RELEASE_DIR=data/releases/labor-law-2026-07-27-candidate-v2
```

## Retrieval tuning

Cài từ thư mục gốc repository:

```bash
unzip -o retrieval_tuning_bootstrap.zip -d .
chmod +x scripts/tune_retrieval_parameters.py

grep -q '^legal-eval-tune:' Makefile.eval.inc || \
  cat Makefile.eval.tuning.inc >> Makefile.eval.inc
```

Chạy grid nhỏ trước:

```bash
make legal-eval-tune-fast
```

Chạy grid mặc định đầy đủ:

```bash
make legal-eval-tune
```

Dùng GPU:

```bash
make legal-eval-tune E5_DEVICE=cuda E5_BATCH_SIZE=8
```

Kết quả nằm trong:

```text
data/evaluation/tuning/
├── retrieval_grid_results.csv
├── retrieval_grid_results.json
├── best_retrieval_configs.json
├── retrieval_tuning_summary.md
└── <best-config>.json
```

Script chọn ba cấu hình:

- `best.article`: ưu tiên tìm đủ điều luật;
- `best.evidence`: ưu tiên exact evidence chunks;
- `best.balanced`: cân bằng hai mục tiêu.

`best.balanced` là ứng viên mặc định. Đây vẫn là kết quả trên development set 45 câu; cần một holdout riêng trước khi kết luận cuối cùng.
