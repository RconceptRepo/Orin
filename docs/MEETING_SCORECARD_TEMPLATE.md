# Meeting Intelligence Scorecard

**Instructions:** Complete within 30 minutes of each meeting while memory is fresh.  
Score every dimension 1–10. Use the rubric below.

---

## Meeting Details

| Field | Value |
|---|---|
| **Date** | |
| **Meeting Title** | |
| **Type** (Standup / Sales / Planning / Review / Other) | |
| **Duration** (minutes) | |
| **Participants** (count) | |
| **Tester name** | |
| **Orin detected type as** | |
| **AI provider used** (Ollama / GPT / Claude / Gemini) | |

---

## Score Rubric

| Score | Meaning |
|---|---|
| 10 | Perfect — zero corrections needed, would send as-is |
| 8–9 | Good — 1–2 minor corrections (typo, name spelling) |
| 6–7 | Usable — 3–5 corrections needed, core content correct |
| 4–5 | Partial — significant gaps, requires substantial editing |
| 2–3 | Poor — more wrong than right |
| 1 | Unusable — completely wrong or missing |

---

## Dimension 1: Transcript Accuracy

**How to evaluate:** Pick 3 random 30-second windows from the meeting. For each window, estimate what percentage of spoken words appear correctly in the transcript.

| Segment | Time window | Accuracy estimate |
|---|---|---|
| Sample A | ___:___ – ___:___ | ____% |
| Sample B | ___:___ – ___:___ | ____% |
| Sample C | ___:___ – ___:___ | ____% |

**Average accuracy:** _______%

| Issue | Example |
|---|---|
| Words missed | |
| Words wrong | |
| Speaker attribution errors | |

### Transcript Score: _____ / 10

---

## Dimension 2: Summary Quality

**Read the AI-generated summary. Evaluate:**

| Question | Y / N / Partial |
|---|---|
| Does it correctly state the main topic(s)? | |
| Does it avoid hallucinated facts? | |
| Does it mention the key outcome? | |
| Is it the right length (not too long, not too short)? | |
| Would you send this to a colleague without editing? | |

**Missing from summary:**

```
1. ______________________________________________________
2. ______________________________________________________
3. ______________________________________________________
```

**Hallucinated (things said that weren't discussed):**

```
1. ______________________________________________________
```

### Summary Score: _____ / 10

---

## Dimension 3: Action Item Accuracy

**Before looking at Orin's list, write the action items you remember:**

```
1. [Owner] _________________: [Task] _______________________________  Due: _______
2. [Owner] _________________: [Task] _______________________________  Due: _______
3. [Owner] _________________: [Task] _______________________________  Due: _______
4. [Owner] _________________: [Task] _______________________________  Due: _______
5. [Owner] _________________: [Task] _______________________________  Due: _______
```

**Total action items you identified:** _____

**Now check Orin's Action Items:**

| Orin's action item | Correct? | Owner correct? | Priority correct? | Due date captured? |
|---|---|---|---|---|
| | Y/N/Partial | Y/N | Y/N | Y/N |
| | Y/N/Partial | Y/N | Y/N | Y/N |
| | Y/N/Partial | Y/N | Y/N | Y/N |
| | Y/N/Partial | Y/N | Y/N | Y/N |
| | Y/N/Partial | Y/N | Y/N | Y/N |

**Capture rate:** _____ / _____ (Orin caught / total you identified)

**False positives (items Orin listed that weren't real action items):** _____

### Action Item Score: _____ / 10

---

## Dimension 4: Decision Accuracy

**Before looking at Orin's list, write the decisions you remember:**

```
1. ___________________________________________________________
2. ___________________________________________________________
3. ___________________________________________________________
4. ___________________________________________________________
```

**Total decisions you identified:** _____

**Now check Orin's Decisions:**

| Orin's decision | Correct? | Notes |
|---|---|---|
| | Y/N/Partial | |
| | Y/N/Partial | |
| | Y/N/Partial | |
| | Y/N/Partial | |

**Capture rate:** _____ / _____ (Orin caught / total you identified)

**Open Questions captured correctly?** Y / N / Partial  
**Risks captured correctly?** Y / N / Partial

### Decision Score: _____ / 10

---

## Overall Meeting Intelligence Score

| Dimension | Weight | Score | Weighted |
|---|---|---|---|
| Transcript Accuracy | 25% | | |
| Summary Quality | 30% | | |
| Action Item Accuracy | 30% | | |
| Decision Accuracy | 15% | | |
| **TOTAL** | 100% | | **_____ / 10** |

---

## Qualitative Assessment

**Single best thing Orin did in this meeting:**

```
________________________________________________________________________
```

**Single worst thing Orin did in this meeting:**

```
________________________________________________________________________
```

**Would Orin's output have saved you time vs. manual notes?**

- [ ] Yes — significantly (> 15 min saved)
- [ ] Yes — somewhat (5–15 min saved)
- [ ] Break-even (about the same effort)
- [ ] No — more work than manual notes

**What one change would most improve this meeting's score?**

```
________________________________________________________________________
```

---

## Meeting Friction Log

| Issue | Severity (1–3) | Notes |
|---|---|---|
| | | |
| | | |

---

*Score total: _____ / 10 | Date: _________ | Tester: _________*
