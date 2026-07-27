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
            low_confidence_threshold=0.56,
            high_confidence_threshold=0.72,
            min_keyword_overlap=2,
            min_keyword_coverage=0.50,
            max_context_chunks=3,
        )

    def test_stopwords_are_removed(self) -> None:
        terms = meaningful_terms("Bạn hãy cho tôi biết Rule là gì")
        self.assertIn("rule", terms)
        self.assertNotIn("ban", terms)

    def test_alias_is_normalized(self) -> None:
        terms = meaningful_terms("Kỹ năng được gọi khi nào?")
        self.assertIn("skill", terms)

    def test_bitcoin_false_positive_is_rejected(self) -> None:
        decision = self.evaluate(
            "Giá Bitcoin hôm nay là bao nhiêu?",
            0.6744,
            "Quy định miễn học phần và chương trình đào tạo.",
        )
        self.assertFalse(decision.selected)

    def test_president_false_positive_is_rejected(self) -> None:
        decision = self.evaluate(
            "Ai là tổng thống Hoa Kỳ?",
            0.6836,
            "Thông tin về quy định đào tạo của trường.",
        )
        self.assertFalse(decision.selected)

    def test_high_score_is_accepted(self) -> None:
        decision = self.evaluate(
            "Kỹ năng được kích hoạt khi nào?",
            0.75,
            "A Skill is invoked only when the task requires it.",
        )
        self.assertEqual(len(decision.selected), 1)

    def test_medium_score_with_terms_is_accepted(self) -> None:
        decision = self.evaluate(
            "Rule và Skill khác nhau thế nào?",
            0.66,
            "Rule luôn bật, còn Skill chỉ được gọi khi cần.",
        )
        self.assertEqual(len(decision.selected), 1)


if __name__ == "__main__":
    unittest.main()
