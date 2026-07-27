"""Deterministic relevance gate before local-LLM generation."""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Sequence

from stopwordsiso import stopwords


def normalize_text(text: str) -> str:
    normalized = unicodedata.normalize("NFD", text.lower())
    without_accents = "".join(
        character
        for character in normalized
        if unicodedata.category(character) != "Mn"
    )
    return re.sub(r"\s+", " ", without_accents).strip()


LIBRARY_STOPWORDS = {
    normalize_text(word)
    for language in ("vi", "en")
    for word in stopwords(language)
}
DOMAIN_STOPWORDS = {
    "anh",
    "ban",
    "giup",
    "hoi",
    "tra loi",
    "thong tin",
    "cho biet",
}
STOPWORDS = LIBRARY_STOPWORDS | {
    token
    for phrase in DOMAIN_STOPWORDS
    for token in normalize_text(phrase).split()
}


def meaningful_terms(text: str) -> set[str]:
    tokens = re.findall(r"[a-z0-9_]+", normalize_text(text))
    return {
        token
        for token in tokens
        if len(token) >= 2
        and token not in STOPWORDS
        and not token.isdigit()
    }


@dataclass(frozen=True)
class CandidateEvaluation:
    content: str
    source_path: str
    chunk_index: int
    score: float
    overlap_count: int
    query_coverage: float
    matched_terms: tuple[str, ...]
    accepted: bool
    reason: str


@dataclass(frozen=True)
class RelevanceDecision:
    selected: tuple[CandidateEvaluation, ...]
    candidates: tuple[CandidateEvaluation, ...]
    reason: str

    @property
    def top_score(self) -> float | None:
        if not self.candidates:
            return None
        return self.candidates[0].score


def evaluate_candidates(
    question: str,
    rows: Sequence[Sequence[Any]],
    *,
    low_confidence_threshold: float,
    high_confidence_threshold: float,
    min_keyword_overlap: int,
    min_keyword_coverage: float,
    max_context_chunks: int,
) -> RelevanceDecision:
    if low_confidence_threshold >= high_confidence_threshold:
        raise ValueError(
            "LOW_CONFIDENCE_THRESHOLD must be lower than "
            "HIGH_CONFIDENCE_THRESHOLD"
        )

    query_terms = meaningful_terms(question)
    evaluations: list[CandidateEvaluation] = []
    selected: list[CandidateEvaluation] = []

    for row in rows:
        content = str(row[0])
        source_path = str(row[1])
        chunk_index = int(row[2])
        score = float(row[3])

        content_terms = meaningful_terms(content)
        matched_terms = tuple(sorted(query_terms & content_terms))
        overlap_count = len(matched_terms)
        query_coverage = (
            overlap_count / len(query_terms)
            if query_terms
            else 0.0
        )

        if score >= high_confidence_threshold:
            accepted = True
            reason = "high_embedding_confidence"
        elif (
            score >= low_confidence_threshold
            and overlap_count >= min_keyword_overlap
            and query_coverage >= min_keyword_coverage
        ):
            accepted = True
            reason = "embedding_plus_lexical_support"
        elif score < low_confidence_threshold:
            accepted = False
            reason = "embedding_score_too_low"
        else:
            accepted = False
            reason = "insufficient_lexical_support"

        evaluation = CandidateEvaluation(
            content=content,
            source_path=source_path,
            chunk_index=chunk_index,
            score=score,
            overlap_count=overlap_count,
            query_coverage=query_coverage,
            matched_terms=matched_terms,
            accepted=accepted,
            reason=reason,
        )
        evaluations.append(evaluation)

        if accepted and len(selected) < max_context_chunks:
            selected.append(evaluation)

    if selected:
        decision_reason = "relevant_context_found"
    elif not evaluations:
        decision_reason = "no_candidates"
    else:
        decision_reason = evaluations[0].reason

    return RelevanceDecision(
        selected=tuple(selected),
        candidates=tuple(evaluations),
        reason=decision_reason,
    )
