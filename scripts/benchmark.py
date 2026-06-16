#!/usr/bin/env python3
"""
Orin Meeting Intelligence Benchmark
====================================
Reads transcripts from the local SwiftData store, sends them to Ollama
using the same prompts as the app, and reports quality metrics.

Usage:
    python3 scripts/benchmark.py                        # run all meetings
    python3 scripts/benchmark.py --meeting java_standup # run one meeting
    python3 scripts/benchmark.py --output results.json  # write JSON report
    python3 scripts/benchmark.py --model mistral        # override model

Requirements:
    - Orin app installed (provides the SwiftData store)
    - Ollama running locally (http://localhost:11434)
    - Python 3.9+, no third-party dependencies

Output JSON schema:
    {
      "model": "phi3",
      "meeting": "Java Standup",
      "meeting_id": "...",
      "path": "single|chunked",
      "transcript_chars": 14599,
      "latency_ms": 28400,
      "summary_length": 212,
      "action_item_count": 2,
      "action_item_parse_rate": 0.80,
      "keyword_coverage": 0.67,
      "keywords_found": ["Resocia", "Kalyani"],
      "keywords_missing": ["bandwidth"]
    }
"""

import argparse
import json
import os
import re
import sqlite3
import struct
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DB_PATH = os.path.expanduser("~/Library/Application Support/default.store")
OLLAMA_URL = "http://localhost:11434/api/generate"
DEFAULT_MODEL = "phi3"
SINGLE_CALL_THRESHOLD = 12_000   # chars — matches TranscriptChunker.singleCallThreshold
CHUNK_SIZE = 5_000               # chars — matches TranscriptChunker.chunkSize
OVERLAP_SIZE = 500               # chars — matches TranscriptChunker.overlapSize

# Golden Benchmark meetings — UUIDs match stored SwiftData records.
# title is human-readable; uuid is the ZID blob key in ZMEETINGITEM.
BENCHMARK_MEETINGS = [
    {
        "name":             "java_standup",
        "title":            "Java Standup",
        "uuid":             "f2dba8fc-db90-4194-b0f9-f58bffe7e877",
        "expected_keywords": ["Resocia", "Kalyani", "motor catch"],
    },
    {
        "name":             "frederick",
        "title":            "Prep Call with Fedrick",
        "uuid":             "af9fa002-4bd2-44ee-b592-db89c0dc2dd5",
        "expected_keywords": ["Coachbar", "product"],
    },
    {
        "name":             "hari",
        "title":            "Meeting — 13/06/26",
        "uuid":             "a1a8de73-a441-444c-8175-3a509608b849",
        "expected_keywords": [],
    },
    {
        "name":             "coworking",
        "title":            "Coworking Space",
        "uuid":             "51b37881-c028-48ec-ba1b-d7c28c75a3d9",
        "expected_keywords": [],
    },
]

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def uuid_to_blob(uuid_str: str) -> bytes:
    """Convert a UUID string to the 16-byte blob SwiftData stores as ZID."""
    return bytes.fromhex(uuid_str.replace("-", ""))


def load_segments(uuid_str: str) -> list[dict]:
    """
    Return segments for a meeting sorted by ZTIMESTAMP ASC.
    Each dict: { timestamp, speaker, text }
    """
    if not os.path.exists(DB_PATH):
        raise FileNotFoundError(
            f"SwiftData store not found: {DB_PATH}\n"
            "Make sure the Orin app has been launched at least once."
        )
    blob = uuid_to_blob(uuid_str)
    con = sqlite3.connect(DB_PATH)
    try:
        cur = con.cursor()
        cur.execute(
            "SELECT ZTIMESTAMP, ZSPEAKERLABEL, ZTEXT "
            "FROM ZTRANSCRIPTSEGMENT "
            "WHERE ZMEETINGID = ? "
            "ORDER BY ZTIMESTAMP ASC",
            (blob,),
        )
        rows = cur.fetchall()
    finally:
        con.close()
    return [{"timestamp": r[0], "speaker": r[1], "text": r[2]} for r in rows]


def load_meeting_title(uuid_str: str) -> Optional[str]:
    blob = uuid_to_blob(uuid_str)
    con = sqlite3.connect(DB_PATH)
    try:
        cur = con.cursor()
        cur.execute("SELECT ZTITLE FROM ZMEETINGITEM WHERE ZID = ?", (blob,))
        row = cur.fetchone()
        return row[0] if row else None
    finally:
        con.close()

# ---------------------------------------------------------------------------
# Timeline formatter — replicates ConversationTimelineBuilder.formatted()
# ---------------------------------------------------------------------------

def format_timeline(segments: list[dict]) -> str:
    """
    Format segments as:
        [MM:SS] Speaker: text
    Timestamp is offset from the first segment (meeting-relative).
    """
    if not segments:
        return ""
    t0 = segments[0]["timestamp"]
    lines = []
    for seg in segments:
        offset = int(seg["timestamp"] - t0)
        mm, ss = divmod(offset, 60)
        lines.append(f"[{mm:02d}:{ss:02d}] {seg['speaker']}: {seg['text']}")
    return "\n".join(lines)

# ---------------------------------------------------------------------------
# Chunker — replicates TranscriptChunker.chunks(of transcript:)
# ---------------------------------------------------------------------------

def chunk_transcript(transcript: str) -> list[str]:
    """
    Split a transcript into overlapping chunks aligned to line boundaries.
    Returns [transcript] when len <= SINGLE_CALL_THRESHOLD.
    """
    if len(transcript) <= SINGLE_CALL_THRESHOLD:
        return [transcript]

    lines = transcript.split("\n")
    chunks = []
    current_lines: list[str] = []
    current_length = 0

    for line in lines:
        current_lines.append(line)
        current_length += len(line) + 1

        if current_length >= CHUNK_SIZE:
            chunks.append("\n".join(current_lines))
            # Keep trailing lines that sum to OVERLAP_SIZE for context continuity
            current_lines = _trailing_lines(current_lines, OVERLAP_SIZE)
            current_length = sum(len(l) + 1 for l in current_lines)

    if current_lines:
        chunks.append("\n".join(current_lines))
    return chunks


def _trailing_lines(lines: list[str], target_chars: int) -> list[str]:
    result = []
    total = 0
    for line in reversed(lines):
        total += len(line) + 1
        result.insert(0, line)
        if total >= target_chars:
            break
    return result

# ---------------------------------------------------------------------------
# Prompt builders — exact matches to Swift source
# ---------------------------------------------------------------------------

def build_comprehensive_prompt(title: str, transcript: str) -> str:
    return (
        "You are a meeting notes assistant. Fill in the five sections below using ONLY facts "
        "explicitly stated in the transcript. Do not infer. Do not write emails. "
        "Do not add commentary outside the sections.\n\n"
        f"MEETING TITLE: {title}\n"
        f"TRANSCRIPT:\n{transcript}\n\n"
        "Fill in these five sections:\n\n"
        "## SUMMARY\n"
        "Write 2-3 sentences covering what was discussed.\n\n"
        "## DISCUSSION POINTS\n"
        "List each topic as a short bullet.\n\n"
        "## ACTION ITEMS\n"
        "Only create an action item when a speaker explicitly commits to a specific task, "
        "follow-up, or deliverable.\n"
        "Do NOT create action items from acknowledgements (yeah, right, okay, sure), "
        "opinions, discussion topics, or questions without an owner.\n"
        "Write \"None\" if no explicit commitments were made.\n"
        "For each real action item: OWNER: name | TASK: verb-first task | "
        "PRIORITY: High/Medium/Low | DUE: date or TBD\n\n"
        "## DECISIONS\n"
        "List each decision as a short bullet.\n\n"
        "## FOLLOW-UPS\n"
        "List each follow-up as a short bullet."
    )


def build_extraction_prompt(chunk: str, index: int, total: int, meeting_type: str = "general") -> str:
    return (
        f"Extract structured information from this {meeting_type} transcript segment.\n"
        f"This is segment {index + 1} of {total}. Extract only what is explicitly stated.\n\n"
        f"TRANSCRIPT SEGMENT:\n{chunk}\n\n"
        "Respond with EXACTLY these sections. Write \"None\" for empty sections.\n\n"
        "## ACTION ITEMS\n"
        "Only output an action item when a speaker explicitly commits to a specific task, "
        "follow-up, or deliverable.\n"
        "Do NOT include acknowledgements (yeah, right, okay, sure), opinions, discussion "
        "topics, or unanswered questions.\n"
        "Write \"None\" if no explicit commitments exist.\n"
        "Format: OWNER: [name or Team] | TASK: [verb-first task] | "
        "PRIORITY: [High/Medium/Low] | DUE: [date or TBD]\n\n"
        "## DECISIONS\n"
        "[- each decision made]\n\n"
        "## KEY POINTS\n"
        "[1-3 bullet points capturing the main topics or outcomes of this segment]"
    )


def build_synthesis_prompt(key_points_text: str, decisions_count: int,
                            actions_count: int, title: str) -> str:
    return (
        f"Write a factual summary for the meeting titled \"{title}\".\n\n"
        f"The meeting covered these topics:\n{key_points_text}\n\n"
        f"There were {decisions_count} decision(s) and {actions_count} action item(s) identified.\n\n"
        "Rules:\n"
        "- Use ONLY the topics listed above. Do not add context not present in the list.\n"
        "- Do not infer roles, job titles, candidate qualities, or team dynamics.\n"
        "- Write 2-4 sentences. Be specific. No filler phrases."
    )

# ---------------------------------------------------------------------------
# Ollama caller
# ---------------------------------------------------------------------------

def call_ollama(prompt: str, model: str, max_tokens: int = 900) -> tuple[str, int]:
    """
    Call Ollama and return (response_text, latency_ms).
    Raises RuntimeError if Ollama is unreachable or returns an error.
    """
    payload = json.dumps({
        "model":   model,
        "prompt":  prompt,
        "stream":  False,
        "options": {"num_predict": max_tokens, "temperature": 0},
    }).encode()

    req = urllib.request.Request(
        OLLAMA_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            body = json.loads(resp.read())
    except urllib.error.URLError as exc:
        raise RuntimeError(
            f"Ollama unreachable at {OLLAMA_URL}: {exc}\n"
            "Start Ollama with: ollama serve"
        ) from exc

    latency_ms = int((time.monotonic() - t0) * 1000)
    text = body.get("response", "").strip()
    return text, latency_ms

# ---------------------------------------------------------------------------
# Response parsers
# ---------------------------------------------------------------------------

def _section_name(header: str) -> Optional[str]:
    h = header.strip().upper()
    if "ACTION ITEM" in h or h == "ACTIONS": return "actions"
    if h.startswith("DECISION"):              return "decisions"
    if h.startswith("KEY POINT"):             return "key_points"
    if h.startswith("SUMMARY"):               return "summary"
    if h.startswith("DISCUSSION"):            return "discussion"
    if h.startswith("FOLLOW"):                return "follow_ups"
    return None


def parse_response(text: str) -> dict:
    """
    Parse a structured LLM response into sections.
    Returns dict with keys: summary, actions_raw, action_items, decisions, key_points.
    actions_raw = list of raw lines under ACTION ITEMS (used to compute parse_rate).
    action_items = list of successfully parsed ActionItemRecord-like dicts.
    """
    sections: dict[str, list[str]] = {
        "summary": [], "actions_raw": [], "decisions": [], "key_points": [], "follow_ups": []
    }
    current = ""

    for line in text.split("\n"):
        s = line.strip()
        if not s or s in ("None", "- None"):
            continue

        # Pattern 1: ## SECTION HEADER or ** SECTION HEADER
        header_match = re.match(r'^[#*]+\s*(.*?)[\s:]*$', s)
        if header_match:
            candidate = header_match.group(1)
            sec = _section_name(candidate)
            if sec:
                current = sec
                continue

        # Pattern 2: SECTION: inline-content  (e.g. "DECISIONS: None")
        colon_match = re.match(r'^([A-Z][A-Z\s]+):\s*(.*)', s)
        if colon_match:
            sec = _section_name(colon_match.group(1))
            if sec:
                current = sec
                inline = colon_match.group(2).strip()
                if inline and inline not in ("None", "- None"):
                    sections.get(current, []).append(inline)
                continue

        # Pattern 3: plain uppercase header with no markup (phi3 style)
        # e.g. "ACTION ITEMS", "DECISIONS", "KEY POINTS"
        plain_match = re.match(r'^([A-Z][A-Z\s]{3,})$', s)
        if plain_match:
            sec = _section_name(plain_match.group(1).strip())
            if sec:
                current = sec
                continue

        if current == "actions":
            sections["actions_raw"].append(s)
        elif current in sections:
            sections[current].append(s)

    # Parse action item lines
    action_items = []
    for raw in sections["actions_raw"]:
        item = _parse_action_item_line(raw)
        if item:
            action_items.append(item)

    return {
        "summary":      " ".join(sections["summary"]),
        "actions_raw":  sections["actions_raw"],
        "action_items": action_items,
        "decisions":    sections["decisions"],
        "key_points":   sections["key_points"],
    }


def _parse_action_item_line(line: str) -> Optional[dict]:
    """Parse 'OWNER: x | TASK: y | PRIORITY: z | DUE: w' into a dict."""
    if "|" not in line:
        return None
    parts = [p.strip() for p in line.split("|")]
    if len(parts) < 2:
        return None
    result = {"owner": "Team", "task": "", "priority": "Medium", "due": ""}
    for part in parts:
        kv = part.split(":", 1)
        if len(kv) != 2:
            continue
        key, val = kv[0].strip().upper(), kv[1].strip()
        if key in ("OWNER", "OWNERS"):  result["owner"]    = val or "Team"
        elif key == "TASK":            result["task"]     = val
        elif key == "PRIORITY":        result["priority"] = val.split()[0].capitalize() if val else "Medium"
        elif key == "DUE":             result["due"]      = "" if val.upper() in ("TBD", "") else val
    return result if result["task"] else None


def is_meaningful_action_item(task: str) -> bool:
    """Python mirror of TranscriptChunker.isMeaningfulActionItem — keeps filtering consistent."""
    normalized = task.lower().strip(".,!? \t\n\r")
    acknowledgements = {
        "yeah", "yes", "no", "right", "okay", "ok", "yep", "nope",
        "sure", "got it", "sounds good", "mm-hmm", "mm hmm",
        "uh huh", "alright", "all right", "noted", "understood",
        "absolutely", "definitely", "of course", "will do",
        "thanks", "thank you", "correct", "exactly", "fair enough",
    }
    if normalized in acknowledgements:
        return False
    words = [
        w.strip(".,;:!?-_ \t\n\r")
        for w in re.split(r"[ .,;:!?\-_\t\n\r]", normalized)
    ]
    meaningful = [w for w in words if len(w) >= 2]
    return len(meaningful) >= 3

# ---------------------------------------------------------------------------
# Metric computation
# ---------------------------------------------------------------------------

def keyword_coverage(text: str, keywords: list[str]) -> tuple[float, list[str], list[str]]:
    """Return (coverage_ratio, found, missing) for expected keywords."""
    if not keywords:
        return 1.0, [], []
    found = [k for k in keywords if k.lower() in text.lower()]
    missing = [k for k in keywords if k.lower() not in text.lower()]
    return len(found) / len(keywords), found, missing


def action_item_parse_rate(actions_raw: list[str]) -> float:
    """Fraction of ACTION ITEMS lines that successfully parse into OWNER|TASK format."""
    if not actions_raw:
        return 0.0
    parsed = sum(1 for line in actions_raw if _parse_action_item_line(line) is not None)
    return parsed / len(actions_raw)

# ---------------------------------------------------------------------------
# Single-call analysis
# ---------------------------------------------------------------------------

def run_single(title: str, transcript: str, model: str) -> tuple[dict, int]:
    """Run single-call analysis. Returns (parsed_response, latency_ms)."""
    prompt = build_comprehensive_prompt(title, transcript)
    text, latency_ms = call_ollama(prompt, model, max_tokens=900)
    return parse_response(text), latency_ms

# ---------------------------------------------------------------------------
# Chunked analysis
# ---------------------------------------------------------------------------

def run_chunked(title: str, transcript: str, model: str) -> tuple[dict, int]:
    """
    Run chunked analysis. Returns merged results and total latency.
    Replicates the app's analyzeChunked pipeline.
    """
    chunks = chunk_transcript(transcript)
    total_latency_ms = 0
    all_action_items: list[dict] = []
    all_actions_raw:  list[str]  = []
    all_decisions:    list[str]  = []
    all_key_points:   list[str]  = []

    for i, chunk in enumerate(chunks):
        prompt = build_extraction_prompt(chunk, i, len(chunks))
        text, ms = call_ollama(prompt, model, max_tokens=500)
        total_latency_ms += ms
        parsed = parse_response(text)
        filtered = [item for item in parsed["action_items"]
                    if is_meaningful_action_item(item["task"])]
        all_action_items.extend(filtered)
        all_actions_raw.extend(parsed["actions_raw"])
        all_decisions.extend(parsed["decisions"])
        all_key_points.extend(parsed["key_points"])
        print(f"  chunk {i+1}/{len(chunks)}: {ms}ms "
              f"actions={len(filtered)} decisions={len(parsed['decisions'])} "
              f"key_points={len(parsed['key_points'])}")

    # Synthesis call
    key_points_text = "\n".join(f"  • {p}" for p in all_key_points)
    synth_prompt = build_synthesis_prompt(
        key_points_text, len(all_decisions), len(all_action_items), title
    )
    summary_text, ms = call_ollama(synth_prompt, model, max_tokens=350)
    total_latency_ms += ms

    return {
        "summary":      summary_text,
        "actions_raw":  all_actions_raw,
        "action_items": all_action_items,
        "decisions":    all_decisions,
        "key_points":   all_key_points,
    }, total_latency_ms

# ---------------------------------------------------------------------------
# Main benchmark runner
# ---------------------------------------------------------------------------

def run_benchmark(meeting: dict, model: str) -> dict:
    """Run one meeting and return a results dict."""
    name  = meeting["name"]
    uuid  = meeting["uuid"]
    title = meeting["title"]
    keywords = meeting["expected_keywords"]

    print(f"\n{'=' * 60}")
    print(f"Meeting : {title} ({name})")
    print(f"Model   : {model}")

    segments = load_segments(uuid)
    if not segments:
        print(f"  WARNING: no segments found for UUID {uuid}")
        return {
            "model": model, "meeting": name, "meeting_title": title,
            "meeting_id": uuid, "error": "no_segments",
        }

    transcript = format_timeline(segments)
    tx_chars   = len(transcript)
    path       = "single" if tx_chars <= SINGLE_CALL_THRESHOLD else "chunked"
    print(f"Chars   : {tx_chars:,}  path={path}  segments={len(segments)}")

    if path == "single":
        parsed, latency_ms = run_single(title, transcript, model)
    else:
        parsed, latency_ms = run_chunked(title, transcript, model)

    # Apply filter to single-call items (chunked already filtered per-chunk)
    if path == "single":
        parsed["action_items"] = [
            item for item in parsed["action_items"]
            if is_meaningful_action_item(item["task"])
        ]

    summary_text  = parsed["summary"]
    action_items  = parsed["action_items"]
    actions_raw   = parsed["actions_raw"]
    combined_text = summary_text + " " + " ".join(
        item["task"] for item in action_items
    ) + " " + " ".join(parsed["decisions"])

    coverage, found, missing = keyword_coverage(combined_text, keywords)
    parse_rate = action_item_parse_rate(actions_raw)

    result = {
        "model":                 model,
        "meeting":               name,
        "meeting_title":         title,
        "meeting_id":            uuid,
        "path":                  path,
        "transcript_chars":      tx_chars,
        "segment_count":         len(segments),
        "latency_ms":            latency_ms,
        "summary_length":        len(summary_text),
        "action_item_count":     len(action_items),
        "action_item_parse_rate": round(parse_rate, 3),
        "keyword_coverage":      round(coverage, 3),
        "keywords_found":        found,
        "keywords_missing":      missing,
        "action_items":          action_items,
        "summary_preview":       summary_text[:200] if summary_text else "",
    }

    print(f"Latency : {latency_ms:,}ms")
    print(f"Summary : {len(summary_text)} chars — {summary_text[:120]}...")
    print(f"Actions : {len(action_items)} (parse_rate={parse_rate:.0%}, raw_lines={len(actions_raw)})")
    print(f"Keywords: {coverage:.0%} found={found} missing={missing}")
    for item in action_items:
        print(f"  [{item['owner']}] {item['task']} | {item['priority']}")

    return result

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Orin benchmark harness")
    parser.add_argument("--meeting", help="Run one meeting by name (e.g. java_standup)")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Ollama model name")
    parser.add_argument("--output", help="Write JSON results to this path")
    args = parser.parse_args()

    meetings = BENCHMARK_MEETINGS
    if args.meeting:
        meetings = [m for m in BENCHMARK_MEETINGS if m["name"] == args.meeting]
        if not meetings:
            print(f"Unknown meeting '{args.meeting}'. Available: "
                  + ", ".join(m["name"] for m in BENCHMARK_MEETINGS))
            sys.exit(1)

    results = []
    for meeting in meetings:
        try:
            result = run_benchmark(meeting, args.model)
            results.append(result)
        except RuntimeError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            results.append({"meeting": meeting["name"], "error": str(exc)})

    timestamp = datetime.now().strftime("%Y-%m-%dT%H%M%S")
    report = {
        "run_timestamp": timestamp,
        "model":         args.model,
        "meeting_count": len(results),
        "results":       results,
    }

    if args.output:
        with open(args.output, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nResults written to {args.output}")
    else:
        out_path = f"scripts/benchmark_results_{timestamp}.json"
        with open(out_path, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nResults written to {out_path}")

    # Print aggregate
    print("\n" + "=" * 60)
    print(f"{'Meeting':<25} {'Path':<8} {'Latency':>10} {'Actions':>8} {'ParseRate':>10} {'Keywords':>10}")
    print("-" * 60)
    for r in results:
        if "error" in r:
            print(f"{r['meeting']:<25} ERROR: {r['error']}")
            continue
        print(
            f"{r['meeting']:<25} {r['path']:<8} {r['latency_ms']:>9,}ms "
            f"{r['action_item_count']:>8} {r['action_item_parse_rate']:>9.0%} "
            f"{r['keyword_coverage']:>9.0%}"
        )


if __name__ == "__main__":
    main()
