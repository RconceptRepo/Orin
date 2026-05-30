# Diarization Feasibility Report

**Date:** 2026-05-31  
**Research basis:** Deep-research workflow (2026-05-30) + codebase analysis

---

## Executive Summary

Local speaker diarization on macOS Apple Silicon is **technically feasible** using FluidAudio (CoreML-compiled pyannote), with the following constraints:

- **Post-processing only** (not real-time) — 7–40 minutes analysis time per meeting
- **8 GB Mac** limited to smaller whisper models; diarization itself fits comfortably
- **16 GB Mac** recommended minimum for full-quality experience
- **4–8 week engineering effort** from zero to Phase 1 implementation
- **Recommended approach:** FluidAudio (Sortformer or LS-EEND) + existing transcription pipeline

---

## Task 2: Local Diarization Options Comparison

### Option 1: pyannote via FluidAudio ✅ RECOMMENDED

**Library:** `github.com/FluidInference/FluidAudio` (v0.14.7, Apache 2.0, 2.1k stars, May 2026)

| Dimension | Details |
|---|---|
| **Technology** | pyannote 3.1 compiled to CoreML `.mlmodelc` bundles |
| **Language** | Pure Swift SPM package — no Python runtime |
| **Acceleration** | Apple Neural Engine (ANE), FP16 |
| **Models available** | Sortformer (≤4 speakers), LS-EEND (≤10 speakers, 100ms updates), WeSpeaker/pyannote (highest accuracy, 5s+ chunks) |
| **Offline** | ✅ Fully offline after first-run model download (~300–600 MB) |
| **Apple Silicon** | ✅ Native ANE — M1 claimed 122× real-time (vendor) |
| **Intel Mac** | ⚠️ CoreML CPU fallback, significantly slower |
| **DER (Diarization Error Rate)** | ~5–12% (pyannote 3.1 benchmark; CoreML accuracy loss unverified) |
| **API** | `OfflineDiarizerManager.prepareModels()` → `diarize(audioURL:)` |
| **Output** | Array of `(startTime, endTime, speakerId)` segments |
| **RAM** | ~500 MB–1 GB model + runtime |
| **Implementation complexity** | Low — Swift SPM, 50+ app integrations documented |
| **Licensing** | Apache 2.0 (commercial use permitted) |

**Key limitation:** Model downloads happen on first use (HuggingFace CDN). Can be pre-staged for offline deployments.

---

### Option 2: whisper.cpp

| Dimension | Details |
|---|---|
| **Technology** | OpenAI Whisper in C++, GGML quantized |
| **Diarization capability** | ❌ **None** — transcription only |
| **Role in Orin** | Word-level timestamps for transcript-diarization alignment (not diarization itself) |
| **Apple Silicon** | ✅ Metal GPU + Core ML acceleration |
| **Models** | tiny (75MB) → large-v3 (2.9GB) → large-v3-turbo (1.6GB, better speed/accuracy) |
| **Processing speed** | large-v3: ~5–10× real-time on M1 (i.e., 60-min → 6–12 min) |
| **RAM** | large-v3: ~3.9 GB; large-v3-turbo: ~2.5 GB; medium: ~2.1 GB |
| **Implementation complexity** | Medium — C++ library, needs Swift wrapper or `Process`-based invocation |
| **Orin use case** | Replace or augment SFSpeechRecognizer for word-level timestamps, enabling timestamp-diarization alignment |

**Verdict:** whisper.cpp is the **transcription layer** in a diarization stack, not the diarization layer itself.

---

### Option 3: WhisperX ❌ NOT VIABLE

| Dimension | Details |
|---|---|
| **Technology** | Python library wrapping whisper.cpp + pyannote + phoneme alignment |
| **Language** | Python — requires Python runtime |
| **macOS integration** | ⚠️ Can be called via `Process` but fragile; sandboxing complications |
| **Apple Silicon** | Limited — Python MPS acceleration inconsistent |
| **Dependency hell** | PyTorch, torchaudio, transformers, pyannote all required |
| **Verdict** | **Inappropriate for a production macOS app** |

WhisperX is a research tool. FluidAudio provides equivalent functionality in a native Swift package.

---

### Option 4: Resemblyzer ❌ NOT VIABLE

| Dimension | Details |
|---|---|
| **Technology** | Python library for speaker embedding/verification |
| **Language** | Python — same integration problems as WhisperX |
| **Accuracy** | Moderate (d-vector approach, older architecture) |
| **Models** | GE2E (Generalized End-to-End Loss), ~17 MB |
| **Use case** | Speaker verification (same/different), not full diarization |
| **Verdict** | **Python-only, outdated architecture vs. pyannote** |

---

### Option 5: Apple CreateML / Core ML (Custom) ❌ NOT VIABLE NOW

| Dimension | Details |
|---|---|
| **Technology** | Apple's own ML framework |
| **Speaker diarization** | No pre-trained model available from Apple |
| **Training required** | Would require training from scratch on speaker diarization datasets |
| **Timeline** | 6–18 months research + engineering |
| **Verdict** | **Not practical in any reasonable roadmap** |

---

### Option 6: SpeakerKit (Apple) ⚠️ FUTURE WATCH

macOS Sonoma (14.0) added limited speaker recognition APIs in `SpeechAnalytics` (private frameworks). iOS 17 added `SFSpeechRecognizer` improvements. No public speaker diarization API exists as of macOS 15.x.

**Watch for:** WWDC announcements. Apple may add public speaker diarization in macOS 16+.

---

### Comparison Summary

| Option | Diarizes? | Swift native? | Offline? | Complexity | Recommended |
|---|---|---|---|---|---|
| FluidAudio (pyannote) | ✅ | ✅ | ✅ | Low | **✅ YES** |
| whisper.cpp | Transcription only | ✅ (with wrapper) | ✅ | Medium | As companion only |
| WhisperX | ✅ | ❌ Python | ✅ | Very high | ❌ No |
| Resemblyzer | Partial | ❌ Python | ✅ | High | ❌ No |
| Apple CreateML | ❌ (build yourself) | ✅ | ✅ | Extreme | ❌ No |

---

## Task 3: Recommended Architecture

### Overall Pipeline

```
RECORDING PHASE (real-time, unchanged)
──────────────────────────────────────
Microphone → AVAudioEngine → .caf file
                           → SFSpeechRecognizer → "Me: ..."
System Audio → SCStream   → .caf file (or same file)
                           → SFSpeechRecognizer → "Participant: ..."
                           → TranscriptChunk × N
                           → MeetingItem.transcript (checkpoint every 3s)

POST-PROCESSING PHASE (after recording stops, background)
──────────────────────────────────────────────────────────
                                  ┌─────────────────────────────────┐
.caf audio file                   │ POST-PROCESSING PIPELINE        │
        │                         │                                 │
        ▼                         │  1. RESAMPLE                    │
  Resample to 16 kHz mono PCM    ─►     AVAudioConverter            │
        │                         │     (44.1kHz → 16kHz mono)      │
        ▼                         │                                 │
  FluidAudio diarization         ─►  2. DIARIZE                     │
        │                         │     OfflineDiarizerManager      │
        │  Returns:                │     .diarize(audioURL:)        │
        │  [(0.0, 3.2, "spkA"),   │     Output: [(t_start, t_end,  │
        │   (3.5, 8.1, "spkB"),   │      speakerId)] ordered        │
        │   (8.2, 15.0, "spkA")] │                                 │
        ▼                         │  3. ALIGN                       │
  Existing TranscriptSegments    ─►     For each TranscriptSegment: │
        │                         │     Find diarization segment     │
        │                         │     whose time range overlaps    │
        │                         │     most with segment.timestamp  │
        │                         │     → assign speakerId          │
        ▼                         │                                 │
  Speaker cluster mapping        ─►  4. MAP                         │
        │                         │     "spkA" → "Me" (mic source)  │
        │                         │     "spkB" → "Speaker 1"        │
        │                         │     "spkC" → "Speaker 2"        │
        ▼                         │                                 │
  Update TranscriptSegments      ─►  5. UPDATE                      │
        │                         │     segment.speakerLabel =       │
        │                         │     "Speaker 1" / "Speaker 2"   │
        ▼                         └─────────────────────────────────┘
  Persist + notify UI
```

### Speaker-Mic Disambiguation

The key insight: we know which audio came from the mic (`source = "mic"`) and which from the system audio (`source = "participant"`). This provides an automatic anchor:

```
diarization_cluster("spkA") maps to mic channel  →  speakerLabel = "Me"
diarization_cluster("spkB") maps to sys audio    →  speakerLabel = "Speaker 1"
diarization_cluster("spkC") maps to sys audio    →  speakerLabel = "Speaker 2"
```

The mic is always a single speaker (the local user). Any diarization cluster that correlates with mic audio timestamps = "Me". All others = "Speaker N".

### Timestamp Alignment

TranscriptSegment timestamps are wall-clock (`Date`). Diarization output is audio-relative (seconds from start). Alignment:

```
meetingStartTime = MeetingItem.date
segmentOffset    = segment.timestamp - meetingStartTime
diarSpeaker      = diarization.find(overlappingTime: segmentOffset)
```

For system audio segments (source = "participant"), most segments will align to exactly one diarization cluster. Overlapping speech is assigned to the dominant speaker by duration.

### Model Selection by Use Case

| Use Case | Model | Speakers | Chunk size | Speed |
|---|---|---|---|---|
| **1:1 calls** | Sortformer | ≤ 4 | Not chunked | Fastest |
| **Small group (≤ 5 pax)** | LS-EEND | ≤ 10 | 100ms frames | Fast |
| **Large meeting (any)** | WeSpeaker/pyannote | Unlimited | ≥ 5s | Slowest, most accurate |

**Default recommendation:** Start with `Sortformer` (easiest to implement, covers 90% of meetings) and expose model selection in Settings.

---

## Task 4: Performance Modeling

### Assumptions

- Speech rate: 130 wpm avg, 5 chars/word → 650 chars/min
- Audio: 44.1 kHz, 16-bit mono → 88.2 KB/s (PCM), 180 MB/hr
- Resampled: 16 kHz, 16-bit → 32 KB/s (PCM), 115 MB/hr
- FluidAudio Sortformer: ~50–100× real-time on ANE (vendor), ~10–20× real-time on CPU
- whisper.cpp large-v3-turbo: ~8–15× real-time on M1 Metal

### 30-Minute Meeting

| Resource | 8 GB Mac | 16 GB Mac | 32 GB Mac |
|---|---|---|---|
| **Audio file (stored)** | ~90 MB | ~90 MB | ~90 MB |
| **Resampled audio (temp)** | ~58 MB | ~58 MB | ~58 MB |
| **FluidAudio RAM** | ~600 MB | ~600 MB | ~600 MB |
| **whisper.cpp model RAM** | medium: 2.1 GB | large-v3-turbo: 2.5 GB | large-v3: 3.9 GB |
| **Available RAM for OS/Orin** | 8−2.7 = 5.3 GB ⚠️ tight | 16−3.1 = 12.9 GB ✅ | 32−4.5 = 27.5 GB ✅ |
| **Diarization analysis time** | ~18–36 s (CPU) | ~9–18 s (ANE) | ~9–18 s (ANE) |
| **Transcription (optional)** | ~3–6 min (medium) | ~2–4 min (turbo) | ~2–4 min (large) |
| **Total post-processing** | ~4–7 min | ~3–5 min | ~3–5 min |

### 60-Minute Meeting

| Resource | 8 GB Mac | 16 GB Mac | 32 GB Mac |
|---|---|---|---|
| **Audio file (stored)** | ~180 MB | ~180 MB | ~180 MB |
| **FluidAudio RAM** | ~600 MB | ~600 MB | ~600 MB |
| **whisper.cpp model RAM** | medium: 2.1 GB | large-v3-turbo: 2.5 GB | large-v3: 3.9 GB |
| **Available RAM** | ~5.3 GB ⚠️ | ~12.9 GB ✅ | ~27.5 GB ✅ |
| **Diarization analysis time** | ~36–72 s (CPU) | ~18–36 s (ANE) | ~18–36 s (ANE) |
| **Transcription (optional)** | ~6–12 min | ~4–8 min | ~4–8 min |
| **Total post-processing** | ~7–13 min | ~5–9 min | ~5–9 min |

### 120-Minute Meeting

| Resource | 8 GB Mac | 16 GB Mac | 32 GB Mac |
|---|---|---|---|
| **Audio file (stored)** | ~360 MB | ~360 MB | ~360 MB |
| **FluidAudio RAM** | ~600 MB | ~600 MB | ~600 MB |
| **whisper.cpp model RAM** | medium: 2.1 GB | large-v3-turbo: 2.5 GB | large-v3: 3.9 GB |
| **Available RAM** | ~5.3 GB ⚠️ tight | ~12.9 GB ✅ | ~27.5 GB ✅ |
| **Diarization analysis time** | ~72–144 s (CPU) | ~36–72 s (ANE) | ~36–72 s (ANE) |
| **Transcription (optional)** | ~12–24 min | ~8–16 min | ~8–16 min |
| **Total post-processing** | ~14–26 min | ~9–18 min | ~9–18 min |

### Notes on 8 GB Macs

- 8 GB unified memory is shared between CPU, GPU, and ANE
- whisper.cpp large (3.9 GB) + FluidAudio (0.6 GB) + Orin (~0.5 GB) + macOS (~3 GB) = ~8 GB → **cannot run large model simultaneously**
- Solution: use **whisper.cpp medium** (2.1 GB) on 8 GB Macs → reduces accuracy but fits
- Alternatively: run diarization first (FluidAudio only, no whisper), then release model before transcription
- **Recommendation:** Auto-detect available RAM and select model tier:
  - < 12 GB: use existing SFSpeechRecognizer transcript + FluidAudio diarization only
  - ≥ 12 GB: whisper.cpp for word-level timestamps + FluidAudio diarization
  - ≥ 16 GB: full pipeline with large-v3-turbo

### CPU Load During Analysis

| Phase | CPU | GPU/ANE | Duration (60 min meeting) |
|---|---|---|---|
| Recording (baseline) | ~2–5% | ~5% (SCKit) | 60 min |
| Resampling | ~15% | — | ~30 s |
| FluidAudio diarization | ~10% | ~60% ANE | ~18–36 s (16GB) |
| whisper.cpp (optional) | ~30–80% | ~40% Metal | ~4–8 min (16GB) |
| Alignment + segment update | ~5% | — | ~5 s |

Post-processing runs after the meeting ends as a background task. The user is not blocked.

---

## Task 5: Battery Impact Assessment

### MacBook Air 13" M3 (52.6 Wh battery)

| Mode | Power draw | Per-hour cost | % of full charge/hr |
|---|---|---|---|
| **Recording only** | ~1.5–3 W | 0.075–0.15 Wh | 0.14–0.28% |
| **Recording + SFSpeechRecognizer** | ~3–6 W | 0.15–0.3 Wh | 0.28–0.57% |
| **Recording + Diarization (post)** | ~15–25 W (post phase) | 1.75–4.2 Wh per hr of meeting | 3.3–8% |

**Example: 60-minute team meeting**
- Recording phase (60 min at ~5W): 5 Wh → ~9.5% battery
- Post-processing (8 min at ~20W): 2.7 Wh → ~5.1% battery
- **Total: ~14.6% battery for a 60-minute meeting with full diarization**

Without diarization (current):
- Recording (60 min at ~5W): 5 Wh → ~9.5% battery only

**Diarization overhead:** ~5% additional battery per hour of meeting recorded, for a 16 GB Mac running the full pipeline.

### Mitigation Strategies

1. **On-power-only:** Only run diarization when plugged in (configurable)
2. **Deferred processing:** Queue diarization for overnight when on charger
3. **Diarization-only mode:** Use existing SFSpeechRecognizer transcript (no whisper.cpp), only run FluidAudio for speaker labels — reduces post-processing power from ~20W to ~8W
4. **User opt-in:** Make diarization an explicit Settings toggle with battery impact disclosure

---

## Task 7: Recommendation

### RECOMMENDATION: YES — with conditions

**Should Orin implement local speaker diarization? YES.**

#### Justification

**1. The infrastructure exists**
- `SpeakerIdentificationProvider` protocol already designed and in place
- `TranscriptSegment.speakerLabel` is mutable and ready to receive updated labels
- `audioFilePath` is stored on every meeting
- Zero schema changes required for Phase 1

**2. FluidAudio is production-ready**
- 2.1k GitHub stars, Apache 2.0 license, 50+ documented app integrations
- Released May 2026 — actively maintained
- Pure Swift SPM dependency — no Python runtime, no system utilities
- CoreML + ANE acceleration means diarization itself is fast (18–36s for 60-min meeting)

**3. The user experience impact is significant**
- Current state: "Participant: [30 minutes of mixed voices]"
- Post-diarization: "[00:03] Speaker 1: Thanks for joining. [00:10] Speaker 2: Let's begin."
- This is the single most requested improvement for meeting intelligence tools
- Action items attributed to correct speakers improves follow-up accuracy dramatically

**4. Cost is bounded and manageable**
- Engineering: 4–8 weeks for Phase 1 (speaker labels only)
- Battery: ~5% additional per meeting hour (acceptable with opt-in)
- Storage: no additional storage (audio files already stored, diarization output is JSON in DB)
- RAM: compatible with 16+ GB Macs (8 GB Macs get diarization-only, no whisper.cpp)

**5. Risk is low**
- Diarization is post-processing — if it fails, the existing transcript is untouched
- `SpeakerIdentificationProvider` makes the implementation pluggable — if a better model ships next month, swap it in with zero pipeline changes
- Keyword fallback in the analysis pipeline means partial failures degrade gracefully

#### Conditions

| Condition | Action required |
|---|---|
| **User opt-in** | Default OFF. Enable in Settings with "Speaker identification (experimental)" toggle |
| **16 GB minimum for full pipeline** | Auto-detect RAM and use appropriate model tier |
| **First-run download** | Show download progress (models ~300–600 MB) |
| **Power preference** | Option: "Analyze when plugged in only" |
| **Graceful degradation** | If FluidAudio fails, existing "Me/Participant" labels preserved |

#### What NOT to implement now

- Real-time diarization (not feasible with available APIs — SFSpeechRecognizer doesn't give utterance boundaries)
- Persistent speaker identity (Phase 2 — requires embedding storage)
- Named speakers (Phase 3 — requires UI for name assignment)
- Cross-meeting speaker matching (Phase 2/3)
