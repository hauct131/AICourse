from __future__ import annotations

import unittest

from relevance import evaluate_candidates, meaningful_terms


class RelevanceTest(unittest.TestCase):
    def evaluate(
        self,
        question: str,
        score: float,
        content: str,
    ):
        return evaluate_candidates(
            question,
            [(content, "sample.md", 0, score)],
            low_confidence_threshold=0.60,
            high_confidence_threshold=0.72,
            min_keyword_overlap=1,
            min_keyword_coverage=0.20,
            max_context_chunks=2,
        )

    def test_stopwords_are_removed(self) -> None:
        terms = meaningful_terms("Bạn hãy cho tôi biết Rule là gì")
        self.assertIn("rule", terms)
        self.assertNotIn("ban", terms)
        self.assertNotIn("cho", terms)

    def test_bitcoin_false_positive_is_rejected(self) -> None:
        decision = self.evaluate(
            "Giá Bitcoin hôm nay là bao nhiêu?",
            0.6744,
            "Quy định miễn học phần của trường.",
        )
        self.assertFalse(decision.selected)

    def test_president_false_positive_is_rejected(self) -> None:
        decision = self.evaluate(
            "Ai là tổng thống Hoa Kỳ?",
            0.6836,
            "Thông tin về quy định đào tạo.",
        )
        self.assertFalse(decision.selected)

    def test_in_scope_high_score_is_accepted(self) -> None:
        decision = self.evaluate(
            "Rule và Skill khác nhau thế nào?",
            0.7944,
            "Rule luôn bật, Skill chỉ được gọi khi cần.",
        )
        self.assertEqual(len(decision.selected), 1)


if __name__ == "__main__":
    unittest.main()
