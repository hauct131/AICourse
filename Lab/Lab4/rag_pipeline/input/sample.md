# Rule, Skill và Knowledge

Rule là chỉ dẫn luôn được gắn vào ngữ cảnh của AI. Rule phù hợp với quy ước ngắn, ổn định và luôn phải tuân thủ. Rule quá dài làm tăng token và có thể gây xung đột ngữ cảnh.

Skill là quy trình chỉ được gọi khi cần. Skill phù hợp với tác vụ nhiều bước như build project, clean restart, tạo PDF hoặc kiểm tra hệ thống.

Knowledge lưu lỗi thường gặp, quyết định kỹ thuật và cách xử lý đã được xác minh. Knowledge không cần luôn nằm trong context mà được truy xuất khi có câu hỏi liên quan.

Khi hệ thống RAG không tìm thấy dữ liệu phù hợp, hệ thống phải trả lời rằng không biết dựa trên tài liệu đã được cung cấp thay vì bịa thông tin.
