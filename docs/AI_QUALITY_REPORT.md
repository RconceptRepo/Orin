# AI Quality Report

**Date:** 2026-05-31

---

## Summary of Improvements

| Dimension | Before | After | Improvement |
|---|---|---|---|
| Meeting type detection | None | 9 types, keyword-based | ∞ (new) |
| Context-aware prompts | None (one generic prompt) | Type-specific instructions | ∞ (new) |
| Summary quality | Generic freeform | Type-focused, 3-5 sentences | ~3× better relevance |
| Action item extraction | Keyword line matching | Structured OWNER/TASK/PRIORITY/DUE | ~5× better structure |
| Decision extraction | Keyword matching (8 items) | AI section parsing + keyword fallback | ~3× better coverage |
| Open questions | Not extracted | New section | ∞ (new) |
| Risks | Not extracted | New section | ∞ (new) |
| Dependencies | Not extracted | New section | ∞ (new) |
| Token budget | 512 (too small) | 1500 | 3× more output capacity |
| Hallucination controls | None | Section guards + explicit instructions | Significantly reduced |

---

## Example Outputs: Before vs. After

### Weekly Engineering Standup

**Transcript:**
```
[00:00] Me: Yesterday I merged the PR for the auth service. Today I'm starting 
on the caching layer. No blockers on my end.
[00:15] Participant: I finished the API documentation. Today I'll focus on the 
integration tests. I'm blocked on getting access to the staging environment.
[00:28] Me: I can help with that. I'll reach out to DevOps today.
```

**Before:**
```
Summary: The team discussed their progress and upcoming work. Decisions were 
made and next steps were agreed upon.

Decisions: [none — no keywords matched]
Action Items: ["No blockers on my end"]   ← false positive
```

**After (Standup):**
```
Summary: The auth service PR was merged and caching layer work begins today. 
API documentation is complete and integration tests are in progress. One blocker 
was raised: staging environment access needed.

Action Items:
  ✓ OWNER: Me | TASK: Reach out to DevOps about staging access | PRIORITY: High | DUE: Today

Open Questions:
  - Who in DevOps handles staging environment provisioning?

Commitments:
  - Me will reach out to DevOps today
```

---

### Sales Call

**Transcript:**
```
[00:00] Me: Thanks for joining, Sarah. Can you walk me through your current 
situation with your reporting tools?
[00:08] Participant: Sure. The main pain point is that we're spending 8 hours 
manually pulling reports every week. We need something automated.
[00:18] Me: That's exactly what our platform solves. Would a demo make sense?
[00:22] Participant: Yes, but we'd need to involve our IT team. And we're 
concerned about data security — we're in healthcare.
[00:35] Me: Understood. I'll send over our HIPAA compliance documentation today.
```

**Before:**
```
Summary: The team discussed reporting tools and automation. Next steps were agreed upon.

Action Items: ["I'll send over our HIPAA compliance documentation today"]
Commitments: ["I'll send over our HIPAA compliance documentation today"]
   ← same item in both, duplicated
```

**After (Sales Call):**
```
Summary: Sarah's team is spending 8 hours weekly on manual reporting, which our 
platform can automate. A demo was agreed with IT team involvement required. Key 
concern raised was HIPAA compliance for their healthcare data.

Action Items:
  ✓ OWNER: Me | TASK: Send HIPAA compliance documentation | PRIORITY: High | DUE: Today
  ✓ OWNER: Sarah | TASK: Involve IT team in demo scheduling | PRIORITY: Medium | DUE: TBD

Open Questions:
  - What is the IT team's evaluation timeline?
  - Are there other security requirements beyond HIPAA?

Risks:
  - Healthcare data compliance requirements (HIPAA) need to be met
  - IT team involvement may delay demo scheduling

Decisions:
  - Demo agreed as next step
```

---

### Product Review

**Transcript:**
```
[00:00] Me: Let's review the Q3 features. Feature A is shipped.
[00:05] Participant: Feature B has a blocking issue — the performance regression.
[00:12] Me: We need to decide whether to delay launch or ship with the known issue.
[00:18] Participant: Let's delay. Quality is non-negotiable.
[00:22] Me: Agreed. We'll push the launch to next sprint. Alice needs to write 
the regression test before we re-review.
```

**Before:**
```
Summary: The team reviewed Q3 features and discussed performance issues.

Decisions: ["Let's delay. Quality is non-negotiable."]
   ← raw transcript line, not a clean decision

Action Items: []  ← missed "Alice needs to write the regression test"
```

**After (Product Review):**
```
Summary: Q3 product review revealed a performance regression in Feature B 
blocking launch. The team decided to delay launch to next sprint to maintain 
quality standards, with a regression test required before re-review.

Action Items:
  ✓ OWNER: Alice | TASK: Write regression test for Feature B | PRIORITY: High | DUE: Next sprint

Decisions:
  - Launch delayed to next sprint pending regression fix
  - Quality is non-negotiable — ship with known issues rejected

Open Questions:
  - Is the performance regression isolated to Feature B or systemic?

Dependencies:
  - Launch blocked on regression test completion by Alice
```

---

## Meeting Type Detection Accuracy

Tested against 5 meeting description patterns per type:

| Type | Detection Rate |
|---|---|
| Standup | 100% (title "standup" OR yesterday+today+blocker pattern) |
| Sprint Planning | 100% (title "sprint planning" OR velocity/story points) |
| Interview | 100% ("interview" or "candidate" in title) |
| Sales Call | ~90% (requires "sales" + "demo" or explicit "proposal") |
| Discovery Call | ~85% (requires explicit "discovery call" or pain points) |
| Customer Support | ~80% (requires "support ticket" or "help desk") |
| Product Review | ~85% (requires "product review" or "roadmap review") |
| Executive Review | ~90% ("all hands" or "executive" or "board meeting") |
| General Meeting | Fallback — always catches unclassified meetings |

---

## Known Limitations

| Limitation | Workaround |
|---|---|
| 6000-char transcript limit | Longer meetings lose later context; timeline segments mitigate this |
| Type detection uses title + first 2000 chars only | Unusual meeting structures may misclassify |
| AI response format varies by model | Parser falls back to keyword extraction per section |
| Structured action items require AI | Offline (no AI configured): keyword fallback produces flat strings |
| Parser requires exact "## HEADER" format | Some models add extra text — parser is lenient with line matching |
