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
