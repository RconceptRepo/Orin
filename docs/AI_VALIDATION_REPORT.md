# AI Validation Report

**Date:** 2026-05-31  
**Version:** Orin v1 (post AI pipeline upgrade)

---

## Quality Targets by Stage

### Alpha / Founder Testing (current)

| Dimension | Minimum Acceptable | Target | Blocking |
|---|---|---|---|
| Transcript accuracy | ≥ 70% word accuracy | ≥ 85% | Yes if < 60% |
| Summary relevance | Score ≥ 5.0/10 | ≥ 7.0/10 | Yes if < 4.0 |
| Action item capture rate | ≥ 50% | ≥ 70% | Yes if < 40% |
| Action item false positive rate | ≤ 30% | ≤ 15% | Yes if > 40% |
| Decision capture rate | ≥ 40% | ≥ 60% | Yes if < 30% |
| Meeting type detection accuracy | ≥ 80% | ≥ 90% | No |
| Overall meeting intelligence | Score ≥ 5.5/10 | ≥ 7.0/10 | Yes if < 4.5 |

### Beta (target: 4–6 weeks post founder validation)

| Dimension | Minimum | Target |
|---|---|---|
| Transcript accuracy | ≥ 80% | ≥ 90% |
| Summary relevance | ≥ 6.5/10 | ≥ 8.0/10 |
| Action item capture rate | ≥ 65% | ≥ 80% |
| Action item false positive rate | ≤ 20% | ≤ 10% |
| Decision capture rate | ≥ 55% | ≥ 75% |
| Meeting type detection accuracy | ≥ 90% | ≥ 95% |
| Overall meeting intelligence | ≥ 6.5/10 | ≥ 8.0/10 |

### Release v1.0 (target: 8–12 weeks post founder validation)

| Dimension | Minimum | Target |
|---|---|---|
| Transcript accuracy | ≥ 85% | ≥ 93% |
| Summary relevance | ≥ 7.5/10 | ≥ 8.5/10 |
| Action item capture rate | ≥ 75% | ≥ 85% |
| Action item false positive rate | ≤ 15% | ≤ 8% |
| Decision capture rate | ≥ 65% | ≥ 80% |
| Meeting type detection accuracy | ≥ 95% | ≥ 98% |
| Overall meeting intelligence | ≥ 7.5/10 | ≥ 8.5/10 |

---

## Performance by Meeting Type (Expected)

Based on AI pipeline design and meeting type context:

| Meeting Type | Expected Summary Quality | Expected Action Capture | Expected Decision Capture |
|---|---|---|---|
| Standup | 8–9/10 | 80–90% | 70–85% |
| Sprint Planning | 7–8/10 | 75–85% | 75–85% |
| Sales Call | 7–8/10 | 70–80% | 65–75% |
| Discovery Call | 6–8/10 | 65–75% | 60–70% |
| Interview | 7–8/10 | 70–80% | 65–75% |
| Product Review | 7–8/10 | 70–80% | 70–80% |
| Executive Review | 6–7/10 | 65–75% | 70–80% |
| Customer Support | 7–8/10 | 70–80% | 65–75% |
| General Meeting | 6–7/10 | 60–70% | 55–65% |

**Why Standup scores highest:** Most structured meeting type, predictable language patterns ("yesterday I...", "today I'll...", "blocked on..."), short duration = full transcript in context.

**Why General Meeting scores lowest:** No type-specific context means generic prompt, unpredictable structure.

---

## AI Provider Quality Comparison (Expected)

| Provider | Summary Quality | Action Item Parsing | Decision Extraction | Latency (60 min) |
|---|---|---|---|---|
| **Ollama (llama3)** | Good | Good | Good | 4–8 min |
| **GPT-4o-mini** | Very Good | Very Good | Very Good | 30–60 s |
| **Claude Haiku 4.5** | Very Good | Excellent | Excellent | 20–40 s |
| **Gemini 1.5 Flash** | Good | Good | Good | 20–40 s |

**Recommendation for founder testing:**
- Use Ollama if available (free, private, good quality)
- Fall back to Claude Haiku via Anthropic API ($) for highest quality
- GPT-4o-mini is the best cost/quality balance for cloud

---

## Transcript Accuracy Factors

### What improves accuracy:
- Good microphone (headset > laptop mic)
- Quiet environment (no background noise)
- Clear pronunciation
- Single speaker at a time (no crosstalk)
- Standard English accent (SFSpeechRecognizer is en-US tuned)
- Meeting length < 18 minutes (single-call path, no chunking latency)

### What degrades accuracy:
- Multiple overlapping speakers
- Heavy accents (particularly for en-US SFSpeechRecognizer)
- Technical jargon or proper nouns
- Very fast speech (> 200 wpm)
- Poor microphone / VoIP compression artifacts
- Background noise (HVAC, keyboard, echo)

### Mitigation (current):
- Transcript recovery: UserDefaults backup + TranscriptChunk records prevent data loss even on crash
- Best-of-N finalization: longest transcript wins on session end
- Conversation timeline: segments ordered by timestamp for readability

### Mitigation (future, not yet implemented):
- whisper.cpp post-processing for higher accuracy (especially technical vocabulary)
- Custom vocabulary list for domain-specific terms
- Noise cancellation pre-processing

---

## Known Quality Gaps

| Gap | Impact | Timeline to fix |
|---|---|---|
| "Participant" = all remote speakers mixed | Medium — action items may say "Participant" instead of person name | Phase 1 diarization (4–6 weeks) |
| SFSpeechRecognizer no per-utterance timestamps | Low — timeline shows 20-second blocks, not exact utterance | Requires whisper.cpp (separate) |
| Structured action items require AI | Low — without Ollama/cloud key, flat keyword extraction used | AI provider setup guidance |
| Long meetings (> 18 min) use chunked analysis | Low — action items near meeting end may be in later chunks | Already implemented; test to verify |
| Meeting type detection uses keywords only | Low — unusual meeting titles may misclassify | Improve keyword set based on test results |
| Folder summary limited to 10 most recent meetings | Low — folders with many meetings lose older context | Use MeetingKnowledgeSnapshot (already designed) |

---

## Go / No-Go Criteria

### Founder Testing (Alpha) — go/no-go after Day 7

**Go (proceed to beta) if:**
- Average Overall score ≥ 5.5/10 across ≥ 10 meetings
- No severity-3 (showstopper) friction issues unresolved
- At least one meeting type scores ≥ 7.0/10 consistently
- Founders express "I would use this daily" for at least one use case

**No-go (needs iteration) if:**
- Average Overall score < 4.5/10
- Any severity-3 friction blocking core workflows
- Transcript accuracy < 60% in majority of meetings
- "More work than manual notes" feedback from majority of testers

### Beta Release

**Go if:**
- Average Overall ≥ 6.5/10 across 50+ meetings
- Action item capture rate ≥ 65% across 3+ meeting types
- Zero data loss incidents (transcript, recordings)
- All 30 test suites passing (currently at 30/30 non-vault)

---

## Regression Baseline

Current automated test coverage:

| Suite | Tests | Status |
|---|---|---|
| AIAnalysisTests | 30 | ✅ All passing |
| LongContextTests | 28 | ✅ All passing |
| TranscriptStoreTests | 40+ | ✅ All passing |
| ConversationTimelineTests | 30 | ✅ All passing |
| MeetingDeletionTests | 12 | ✅ All passing |
| RecurringMeetingTests | 15 | ✅ All passing |
| **Total non-vault suites** | 417 | ✅ **30/30 passing** |

Any regression in these suites blocks a beta release.

---

## Measurement Methodology

### Transcript Accuracy (Word Error Rate)

```
WER = (Substitutions + Deletions + Insertions) / Total reference words
Accuracy = 1 - WER
```

For founder testing: sample 3 random 30-second windows per meeting, count errors manually.

### Action Item Capture Rate

```
Capture Rate = (Orin's correct action items) / (Total action items in meeting)
```
"Correct" = task is substantively right (owner and task match what was discussed).

### False Positive Rate

```
FPR = (Items Orin listed that weren't real) / (Total items Orin listed)
```

### Summary Quality Score (1–10)

Evaluate on:
- Factual accuracy (no hallucinations) — 40%
- Completeness (key topics covered) — 30%
- Conciseness (not too long/short) — 15%
- Type-specificity (standup looks different from sales call) — 15%
