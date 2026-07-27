from __future__ import annotations

import unittest

from relevance import evaluate_candidates, meaningful_terms


class RelevanceTest(unittest.TestCase):
    def test_stopwords_are_removed(self) -> None:
        terms = meaningful_terms("Bạn hãy cho tôi biết Rule là gì")
        self.assertIn("rule", terms)
        self.assertNotIn("ban", terms)
        self.assertNotIn("cho", terms)

    def test_unrelated_candidate_is_rejected(self) -> None:
        decision = evaluate_candidates(
            "Giá Bitcoin hôm nay là bao nhiêu?",
            [("Rule là chỉ dẫn luôn bật.", "sample.md", 0, 0.54)],
            low_confidence_threshold=0.50,
            high_confidence_threshold=0.68,
            min_keyword_overlap=1,
            min_keyword_coverage=0.20,
            max_context_chunks=3,
        )
        self.assertFalse(decision.selected)

    def test_medium_score_needs_lexical_support(self) -> None:
        decision = evaluate_candidates(
            "Rule khác Skill thế nào?",
            [("Rule luôn bật, còn Skill chỉ được gọi khi cần.", "sample.md", 0, 0.55)],
            low_confidence_threshold=0.50,
            high_confidence_threshold=0.68,
            min_keyword_overlap=1,
            min_keyword_coverage=0.20,
            max_context_chunks=3,
        )
        self.assertEqual(len(decision.selected), 1)

    def test_high_score_can_accept_synonym_case(self) -> None:
        decision = evaluate_candidates(
            "Kỹ năng được kích hoạt khi nào?",
            [("A Skill is invoked only when the task requires it.", "sample.md", 0, 0.72)],
            low_confidence_threshold=0.50,
            high_confidence_threshold=0.68,
            min_keyword_overlap=1,
            min_keyword_coverage=0.20,
            max_context_chunks=3,
        )
        self.assertEqual(len(decision.selected), 1)


if __name__ == "__main__":
    unittest.main()
