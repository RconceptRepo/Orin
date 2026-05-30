# Founder Feedback Export Guide

**Purpose:** Export meeting intelligence from Orin for founder review, async feedback, and external sharing.

---

## Quick Export Options

Orin supports five export formats accessible from every meeting. All exports are available from the meeting detail view's `···` menu.

### Option A — Markdown Export (recommended for human review)

Best for: reading, sharing in Slack, pasting into Notion/Linear

1. Open Orin → select a meeting
2. Click `···` menu (top-right of meeting detail)
3. Select Export → Markdown
4. Save to Desktop
5. Open in any text editor / Notion / Obsidian

**Markdown export includes:**
- Meeting title, date, duration, participants
- AI-generated summary
- Decisions
- Action Items
- Suggested Tasks
- Full conversation transcript (Timeline format)

---

### Option B — CSV Export (recommended for scoring / spreadsheet review)

Best for: filling out scorecards, tracking scores across multiple meetings

1. Open Orin → select a meeting
2. Click `···` → Export → CSV
3. Open in Numbers, Excel, or Google Sheets

**CSV columns:**
```
ID | Date | Duration | Title | Participants | Summary | Decisions | 
Action Items | Suggested Tasks | Has Transcript | Has Recording | Tags
```

Multi-value fields (decisions, action items) use semicolon (`;`) separators.

---

### Option C — ZIP Export of All Meetings (recommended for bulk review)

Best for: end-of-week batch review, sending all meeting data to an advisor

1. Open Orin → Settings → Data
2. Click "Export All Meetings (ZIP)"
3. ZIP file contains:
   - `index.json` — all meetings as structured JSON
   - One `.md` file per meeting (full content)

**ZIP structure:**
```
Orin-Export-2026-05-31/
  index.json
  2026-05-31 Weekly Standup.md
  2026-05-31 Customer Discovery — Acme.md
  2026-05-30 Sprint Planning.md
  ...
```

---

### Option D — JSON Export (recommended for programmatic analysis)

Best for: technical analysis, building scoring dashboards, data science

1. Open Orin → select a meeting → Export → JSON
2. JSON contains full `MeetingSnapshot` with all fields

**JSON fields:**
```json
{
  "id": "UUID",
  "title": "Weekly Standup",
  "date": "2026-05-31T09:00:00Z",
  "durationSeconds": 1800,
  "participants": ["Alice", "Bob"],
  "transcript": "Me: Hello everyone...",
  "summary": "...",
  "decisions": ["..."],
  "actionItems": ["..."],
  "suggestedTaskTitles": ["..."],
  "tags": []
}
```

---

### Option E — Full App Export (recommended for complete data handoff)

Best for: handing off full data to a technical reviewer / data scientist

1. Open Orin → Settings → Data → "Export Full App Data (JSON)"
2. Single JSON file containing all meetings, folders, tasks, and settings

---

## Founder Review Workflow (Recommended)

### Daily review (5 min/meeting):
1. Export meeting as Markdown immediately after it ends
2. Paste into Slack → `#orin-testing` channel with scorecard scores in the message
3. Note 1 win + 1 issue per meeting

### Weekly batch review (30 min):
1. Export all meetings as ZIP
2. Open in Finder → sort `.md` files by date
3. Read each summary (2–3 min each)
4. Fill out weekly aggregate scorecard

### External advisor review:
1. Export all meetings as ZIP
2. Share ZIP via Dropbox / Google Drive
3. Advisor reads `.md` files and fills out scorecard template

---

## Feedback Format for Async Review

When sharing feedback in Slack / email, use this format:

```
Meeting: [Title] — [Date] — [Duration]
Type: [Standup / Sales / Planning / Other]
AI: [Ollama / GPT-4 / Claude]

Transcript: X/10
Summary: X/10
Actions: X/10
Decisions: X/10
Overall: X/10

Win: [One specific thing Orin got right]
Issue: [One specific thing Orin got wrong, with example]
```

---

## Export Limitations

| Limitation | Workaround |
|---|---|
| Transcript may be truncated in CSV (long meetings) | Export as Markdown or JSON for full transcript |
| Structured action items (owner/priority/due) in CSV show as combined text | Export as JSON for fully structured ActionItemRecord data |
| ZIP export includes all meetings (no date filter) | Delete meetings you don't want before exporting |
| Audio recording NOT included in any export format | Access directly: `~/Library/Application Support/Orin/Recordings/` |

---

## Sending Feedback to the Team

**Priority bug reports** (scoring < 4 on any dimension):
- Screen record the meeting review session
- Export the meeting as JSON
- Send both to the founder Slack channel with scores

**Feature requests** (scoring 4–7, improvement ideas):
- Use the `<!-- Orin feedback -->` note format in Notion
- Include the meeting scorecard

**Positive signals** (scoring 8–10):
- Note the meeting type and AI provider that achieved the high score
- These become the benchmark for regression testing
