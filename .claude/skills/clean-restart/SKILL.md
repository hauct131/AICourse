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
