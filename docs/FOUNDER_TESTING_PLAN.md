# Orin Founder Testing Plan

**Version:** 1.0  
**Date:** 2026-05-31  
**Duration:** 7 days  
**Participants:** 2–4 founders / early team members

---

## Objective

Validate that Orin's meeting intelligence (transcript, summary, action items, decisions) is accurate and useful enough for real-world founder workflows before broader beta.

**Primary question:** Does Orin save meaningful time versus manual note-taking?

---

## Testing Framework

### Scoring System

All scores use a 1–10 scale:

| Score | Meaning |
|---|---|
| 1–3 | Unusable — wrong or missing |
| 4–5 | Partially correct — needs significant human correction |
| 6–7 | Mostly correct — minor corrections needed |
| 8–9 | Good — usable with light review |
| 10 | Perfect — no corrections needed |

**Release threshold:** Average ≥ 7.0 across all dimensions  
**Beta threshold:** Average ≥ 5.5 across all dimensions

---

## Day-by-Day Protocol

### Day 1 — Setup and Calibration

**Goal:** Establish baseline, install Orin, verify all features work.

**Morning (30 min):**
- [ ] Install Orin from DMG
- [ ] Grant all permissions (mic, calendar, notifications, screen recording)
- [ ] Connect Ollama (preferred) OR add OpenAI API key in Settings
- [ ] Run first test recording: 5-minute solo recording of a scripted standup
- [ ] Verify: floating widget appears, recording stops, transcript generated

**Afternoon:**
- [ ] Score the calibration recording using the Meeting Scorecard Template
- [ ] Document any setup friction in the Friction Log
- [ ] Record first real meeting (any type)

**End of Day 1 Checklist:**
- [ ] Can start recording from the app ✓
- [ ] Can start recording from notification action ✓
- [ ] Floating widget appears and works ✓
- [ ] Transcript appears after meeting ✓
- [ ] Summary generated (with Ollama or cloud AI) ✓

---

### Day 2–3 — Standup Meetings

**Target meeting type:** Daily standups, 15–30 minutes, 3–6 participants  
**Goal:** Validate standup-specific intelligence (progress, blockers, commitments)

**For each meeting:**
1. Start recording when meeting begins (either auto-detect or manual)
2. Conduct meeting normally — do NOT change behavior for Orin
3. After meeting: complete Meeting Scorecard within 30 minutes (memory is fresh)
4. Note 3 specific errors (wrong name, missed action item, hallucinated decision)
5. Note 1 thing Orin got right that surprised you

**Standup-specific questions:**
- Did Orin correctly identify this as a Standup? (check Meeting Type badge)
- Were all blockers captured in Risks?
- Were individual commitments ("I'll finish the PR today") captured correctly?
- Did the summary distinguish between what's done vs. in-progress vs. blocked?

**Target: 4–6 standup meetings across Day 2–3**

---

### Day 4–5 — Sales Calls / Customer Meetings

**Target meeting type:** Customer interviews, sales demos, discovery calls  
**Goal:** Validate that pain points, objections, and follow-ups are captured

**Special protocol:**
- After the call, write your own notes BEFORE looking at Orin's summary
- Compare your notes to Orin's output
- Score the delta: what did Orin miss that you caught? What did Orin catch that you missed?

**Sales-call-specific questions:**
- Were customer pain points captured in the Summary?
- Were objections listed in Decisions or Open Questions?
- Were all follow-up commitments ("I'll send the pricing deck") in Action Items?
- Were action items attributed to the correct person (you vs. the customer)?

**Target: 2–3 customer meetings across Day 4–5**

---

### Day 6 — Product / Planning Meetings

**Target meeting type:** Sprint planning, product reviews, engineering syncs, executive reviews  
**Goal:** Validate decision and action item accuracy for structured meetings

**For product review specifically:**
- Note every decision made during the meeting (keep a tally)
- After: count what percentage Orin captured
- Note every action item assigned (keep a tally)
- After: count what percentage Orin captured (with correct owner)

**Decision capture test:**
Use a verbal signal: say "We're deciding to..." before each decision.  
After: check if all flagged decisions appear in Orin's Decisions section.

**Target: 1–2 planning meetings on Day 6**

---

### Day 7 — Analysis and Go/No-Go

**Morning (1 hour):**
- Tally all scores from the week
- Calculate averages per dimension (Transcript, Summary, Actions, Decisions)
- Identify top 3 failure patterns
- Identify top 3 success patterns

**Questions to answer:**
1. Would you use Orin as your primary meeting notes tool today? (Y/N)
2. What would need to change to answer Yes?
3. Which meeting type worked best?
4. Which meeting type worked worst?
5. How much time did Orin save vs. manual note-taking? (estimate minutes/meeting)

---

## Metrics Collection

### Required Metrics (per meeting)

| Metric | Method |
|---|---|
| Transcript accuracy | Count missed sentences / total sentences (sample 3 random 30-second windows) |
| Action item capture rate | (Orin's correct actions) / (total actions you noted) |
| Decision capture rate | (Orin's correct decisions) / (total decisions you noted) |
| False positive rate | (Orin's hallucinated items) / (Orin's total items) |
| Summary usefulness | "Would I send this summary to a colleague without editing?" (Y/N/With edits) |

### Optional Metrics

| Metric | Method |
|---|---|
| Time saved | Estimate: how long would manual notes have taken? |
| Speaker attribution accuracy | (correct speaker labels) / (total labeled utterances) |
| Folder grouping suggestion quality | Did the recurring meeting suggestion match your mental model? |

---

## What to Test That Isn't AI

| Feature | Test |
|---|---|
| Meeting detection | Open Zoom → does the prompt appear? |
| Background recording start | Lock screen while in meeting → does recording continue? |
| Notification "Start Recording" | Let Orin detect meeting, tap notification action → does recording start? |
| Widget always-on-top | Open another fullscreen app → is widget still visible? |
| Multi-monitor widget | Move cursor to secondary monitor → does widget follow? |
| Export (CSV) | Export one meeting as CSV → open in Excel/Numbers → readable? |
| Export (ZIP) | Export all meetings as ZIP → all files present? |
| Folder creation | Accept a recurring meeting suggestion → folder created, meetings moved? |
| Folder summary | Generate folder intelligence for a folder with 3+ meetings → quality? |

---

## Known Limitations to Account For in Scoring

1. **"Me" vs. "Participant" labels** — Orin does not diarize multiple remote speakers. All remote audio is labeled "Participant". Do not penalize for this.
2. **Accent/noise sensitivity** — SFSpeechRecognizer may struggle with heavy accents or poor audio. Penalize proportionally only if your own speech was also poor.
3. **Short meetings (< 5 min)** — Auto-analysis skips meetings below the minimum duration threshold. Manually trigger analysis if needed.
4. **First-word delay** — SFSpeechRecognizer takes ~2–3 seconds to initialize. The first words of a meeting may be missed in the transcript.

---

## Friction Log Template

For every friction point, record:
```
Date: ___________
Feature affected: ___________
What happened: ___________
Severity: 1 (annoyance) / 2 (workflow blocker) / 3 (showstopper)
Workaround found: Y / N
```

---

## Daily Reporting

At end of each day, send to product channel:
- Number of meetings tested
- Average scores for the day
- Top 3 wins
- Top 3 issues
- Any showstoppers (severity 3 friction)
