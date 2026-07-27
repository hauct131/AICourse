# Coding Convention

1. Mọi hàm Python phải có type hints.
2. Không dùng `print()` trong code backend; dùng `logging`.
3. Không hard-code secret hoặc API key.
4. Không commit file `.env`.
5. API phải có `/health`.
6. Sau mỗi thay đổi phải chạy compile check hoặc smoke test.
7. RAG phải trả kèm nguồn và không được bịa khi thiếu context.
