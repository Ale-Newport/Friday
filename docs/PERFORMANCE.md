# Performance

Measured on this Mac (Apple M2 Max, 64 GB, macOS 27.0.1) on 4 November 2026, Debug builds unless noted. Methods are
reproducible with the commands given; numbers from the source projects are marked as such.

## Voice pipeline

| Stage | Measurement | How |
|---|---|---|
| Wake-word detection (sherpa-onnx KWS) | median 417 ms, p90 504 ms after the end of the word (synthetic voices); engine→handler 0.11 ms | Speech project, `jarvis-bench latency` (Release) |
| Wake-word idle cost | 0.09 % CPU, 2.1 mW, 60 MB in a quiet room; ≈1.5 % while sound is present | Speech project, `Scripts/measure-app.sh` |
| Speech recognition (Apple `SpeechAnalyzer`, on device) | **average WER 0.05** over 10 Kokoro-synthesised sentences (4 English, 4 Spanish, 2 mixed); finalisation 78–298 ms after the last audio chunk (median ≈130 ms); 8 of 10 sentences exact | `swift test --filter RecognitionBenchmark` (writes `stt-benchmark-apple.json`) |
| Recognition misses | "Queen" → "Ken" in a Spanish sentence; "and search for" → "Ansiarch For" in a code-switched one | same |
| Text-to-speech (Kokoro int8 multilingual, in process) | model load 0.64 s; first audio after 0.86 s (Spanish, 3.3 s of speech) to 1.26 s (English, 2.4 s); a 25 s six-sentence answer streams its first sentence after 2.9 s and finishes in 17.6 s (≈1.4× real time); cancellation stops generation at the next sentence | `swift test --filter KokoroTextToSpeechTests` (samples in the scratchpad `tts-samples/`) |
| Voice activity (Silero, in process) | 1.0 s of speech padded with silence → one segment starting at 0.97 s lasting 0.77 s | `swift test --filter SileroVoiceActivityDetectorTests` |
| Voice activity (energy fallback) | 20 ms frames, segment closed 0.7 s after speech ends (configurable) | `FridaySpeechTests` |

End-to-end voice latency (wake word → spoken answer) is the sum of: detection (~0.4 s) + the utterance + endpoint
silence (0.8 s default) + finalisation (~0.13 s) + routing (0–80 ms) + planning (model-dependent) + tool time +
first TTS audio (~1 s). For a fast-path command ("open Notes", "what time is it") that is ≈ 2.5 s from the end of the
sentence to the first spoken word; the model-driven path adds the provider's time to first token (not measured here:
no model account was connected during this session).

## Intelligence

| Stage | Measurement | How |
|---|---|---|
| Keyword routing (Swift, bilingual) | < 1 ms | unit tests |
| Laya routing through the sidecar (HTTP, warm) | **75–80 ms** per request (99 ms worst seen); rules-only path 1.4–1.6 ms over HTTP; model load 118 ms + warm-up 69 ms at sidecar start | sidecar smoke run, `POST /api/route` |
| Laya accuracy (zero-shot, 13 categories, English) | 9/13 correct; misses go to the catch-all; `dangerous` separates well (0.58 for a delete vs ≤ 0.31 benign) | sidecar probe; see `Sidecar/README.md` |
| Fast path (deterministic rules + parser) | 1–8 ms end-to-end through the engine (`fridayctl "what time is it"`: 1 ms; `"open Notes"`: 300 ms including the launch) | `fridayctl` timings from the engine's `durationMs` |
| Apple on-device model (fallback) | 1–4 s per answer; 4k-token window — Friday sends it ≤ 10 tools and compact results | `fridayctl` with no cloud provider |
| Sidecar browser planner | unchanged from the Jarvis project: Laya decisions ≈ 16 ms, CDP round trip 0.4 ms; wall time dominated by the text model | `Sidecar/scripts/benchmark.py` |

## Resources (Debug build, both processes running, no requests)

| Process | CPU | Memory | Notes |
|---|---|---|---|
| Friday.app | 2.4 % average over 30 s (sampled while this Mac was also compiling; a quiet room with the wake-word gate idle is ≈ 0.1 % in the Speech project's measurements) | 316 MB | includes the loaded Kokoro model (≈ 140 MB) and the Apple speech assets |
| Sidecar (Python, Laya on MLX) | 0.2 % | 2.5 GB | Laya weights (fp16) + Metal kernels; starts in ≈ 3 s, loads Laya in 0.2 s |

The app's memory can be reduced by not pre-loading Kokoro (Settings ▸ Voice ▸ engine "Apple voices") at the cost of
≈ 0.6 s on the first spoken answer.

## Targets set from these measurements

* Simple local commands: ≤ 2.5 s from end of speech to first spoken word (met on the fast path).
* Routing: ≤ 100 ms (met: 0–80 ms).
* Idle: ≤ 0.5 % CPU in a quiet room (to be confirmed on a quiet machine; the detector's own figure is 0.09 %).
* Model-driven commands: time to first token depends on the provider; Friday streams tokens to the panel and
  starts speaking only when the answer is complete (speaking partial answers that may be revised was judged worse
  than a short wait). Not measured here.
