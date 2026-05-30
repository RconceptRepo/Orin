# Recurring Meeting Detection Report

**Date:** 2026-05-31

---

## Algorithm

### Grouping Phase

Meetings are first grouped by **title token similarity** using Jaccard distance on normalized word tokens.

```
tokenize("Weekly Team Standup") → {"weekly", "team", "standup"}
tokenize("Team Standup")        → {"team", "standup"}
Jaccard = |{"team","standup"}| / |{"weekly","team","standup"}| = 2/3 = 0.67 ≥ 0.55 → same group
```

**Tokenization:**
- Lowercase, split on whitespace + punctuation
- Filter tokens shorter than 2 characters
- Remove stop words (the, and, for, with, etc.)

**Grouping threshold:** 0.55 — two meetings whose title token sets have ≥ 55% overlap are placed in the same candidate group.

**Minimum group size:** 2 meetings.

---

### Signal Computation

For each candidate group, five weighted signals produce a `[0.0, 1.0]` confidence score:

| # | Signal | Weight | Formula |
|---|---|---|---|
| 1 | Title similarity | 35% | Average pairwise Jaccard of title token sets |
| 2 | Participant match | 25% | Average pairwise Jaccard of participant name sets |
| 3 | Day-of-week pattern | 20% | Fraction of meetings on the most common weekday |
| 4 | Time-of-day pattern | 15% | Inverse spread of start times within a day |
| 5 | Topic similarity | 5% | Keyword Jaccard across summaries and decisions |

**Participant scoring:**
- If meetings have no participants → neutral 0.5
- Full match of {Alice, Bob} vs {Alice, Bob} → 1.0
- Partial match of {Alice, Bob} vs {Alice, Bob, Carol} → 0.67

**Day pattern:**
- ≥ 75% on same weekday → 1.0 ("Every Monday")
- ≥ 50% on same weekday → 0.7 ("Usually Monday")
- Mixed → 0.3

**Time pattern:**
- Spread ≤ 30 minutes → 1.0
- Spread ≤ 60 minutes → 0.7
- Spread ≤ 120 minutes → 0.4
- Wider spread → 0.2

**Topic similarity:**
- Only active when meetings have AI summaries/decisions
- Falls back to 0.5 (neutral) when no content available
- This is a weak signal (5% weight) by design — meetings may be recorded before analysis

---

### Confidence Threshold

**Threshold: 60%**

Patterns below 60% are silently dropped.

Examples:

| Scenario | Title | Participants | Day | Time | Topic | Total |
|---|---|---|---|---|---|---|
| Weekly standup, same team | 1.0 (35%) | 1.0 (25%) | 1.0 (20%) | 1.0 (15%) | 0.5 (5%) | **92.5%** |
| Weekly standup, open invite | 1.0 (35%) | 0.5 (12.5%) | 1.0 (20%) | 1.0 (15%) | 0.5 (5%) | **77.5%** |
| Similar title, random days | 0.85 (29.75%) | 0.8 (20%) | 0.3 (6%) | 0.3 (4.5%) | 0.5 (2.5%) | **62.75%** |
| Only title match, nothing else | 0.95 (33.25%) | 0.0 (0%) | 0.3 (6%) | 0.2 (3%) | 0.5 (2.5%) | **44.75% ❌** |

---

### Deduplication

- Each pattern produces a `dismissedKey` stored in `UserDefaults`
- Dismissed patterns are permanently hidden (per device)
- Patterns for meetings already in an existing folder are excluded
- Up to 3 suggestions shown at once (most confident first)

---

### Folder Name Selection

The suggested folder name is the **most common meeting title** in the group (case-sensitive, exact match). In case of tie, the first meeting's title is used.

---

### Output: RecurringPattern

```swift
struct RecurringPattern: Identifiable {
    let suggestedFolderName: String  // "Weekly Team Standup"
    let meetingIDs: [UUID]           // IDs of all matched meetings
    let confidence: Double           // 0.0 – 1.0 (e.g., 0.925)
    let dayPattern: String           // "Every Monday"
    let timePattern: String          // "~9:00 AM"
    let dismissedKey: String         // UserDefaults dedup key
}
```

---

## Example Detections

### Example 1: Weekly standup (high confidence)

```
Meeting 1: "Weekly Team Standup" — Monday 09:00, Alice/Bob/Carol
Meeting 2: "Weekly Team Standup" — Monday 09:00, Alice/Bob/Carol
Meeting 3: "Weekly Team Standup" — Monday 09:05, Alice/Bob/Carol

Signal scores:
  Title       = 1.00 × 0.35 = 0.350
  Participants = 1.00 × 0.25 = 0.250
  Day          = 1.00 × 0.20 = 0.200
  Time         = 1.00 × 0.15 = 0.150
  Topic        = 0.50 × 0.05 = 0.025
  ─────────────────────────────────
  Total        = 0.975 (97.5%)

Suggestion: Create "Weekly Team Standup" folder → ✅ shown
```

### Example 2: Monthly review (moderate confidence)

```
Meeting 1: "Q1 Product Review"  — Wed 14:00, Alice/Bob
Meeting 2: "Q2 Product Review"  — Mon 10:00, Alice/Carol
Meeting 3: "Product Review"     — Fri 09:00, Bob/Dave

Title similarity   = 0.75 × 0.35 = 0.263
Participants match = 0.33 × 0.25 = 0.083
Day pattern        = 0.33 × 0.20 = 0.067
Time pattern       = 0.30 × 0.15 = 0.045
Topic              = 0.50 × 0.05 = 0.025
─────────────────────────────────
Total = 0.483 (48.3%)

Below threshold → NOT shown
```

### Example 3: Biweekly sync (just above threshold)

```
Meeting 1: "Engineering Sync" — Thu 10:00, Alice/Bob/Carol/Dave
Meeting 2: "Engineering Sync" — Thu 10:30, Alice/Bob/Carol/Dave
Meeting 3: "Engineering Sync" — Thu 10:00, Alice/Bob/Carol/Dave

Title sim    = 1.00 × 0.35 = 0.350
Participants = 1.00 × 0.25 = 0.250
Day          = 1.00 × 0.20 = 0.200
Time         = 0.70 × 0.15 = 0.105
Topic        = 0.50 × 0.05 = 0.025
─────────────────────────────────
Total = 0.930 (93%)

Suggestion: Create "Engineering Sync" → ✅ shown
```
