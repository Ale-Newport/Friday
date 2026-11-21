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
sentence to the first spoken word.

### End to end, from synthesised audio (5 November 2026)

`Scripts/voice-e2e.sh` plays Kokoro-synthesised files ("Jarvis," in English, then the command) into the microphone
pipeline of the running app (`fridayctl --voice`) and reads back what happened. Debug build, Ollama
`qwen2.5:7b-instruct-q4_K_M` as the planning model, Mac also compiling at the time:

| Command | Wake word | Heard | Path | Engine time |
|---|---|---|---|---|
| what time is it? / ¿qué hora es? | detected | exact | fast rule → `friday.current_time` | 1–2 ms |
| abre Notas / cierra Notas / open Calculator / close Calculator | detected | exact | fast rule → `system.open_app` / `close_app` | 120–550 ms (app launch) |
| what's 17 times 24? | detected | exact | fast rule → `utilities.calculate` | 1 ms |
| what's the weather in Madrid tomorrow? | detected | exact | deterministic parser → `weather.forecast` (Open-Meteo) | 560–640 ms |
| ¿qué tengo en el calendario mañana? | detected | exact | local model → `calendar.list_events` → spoken summary | 7–13 s (one model round plus the personal-data retry) |
| recuerda que mi color favorito es el azul / ¿cuál es mi color favorito? | detected | exact | fast rule → `memory.remember`; model answer from remembered facts | 5 ms; 6–8 s |
| ¿cuánto es diecisiete por veinticuatro? | detected | "de asiciete por venti cuatro" | — | — (the Spanish Kokoro voice's number words are not recognised; a person's are, see the WER benchmark) |

Ten of twelve corpus items pass; the two misses are synthesis artefacts, not pipeline failures. The command capture
starts 0.6 s before the detector's reported keyword end (the detector needs right context), otherwise the first word
after "Jarvis" was lost ("is it?" for "what time is it?").

### Voice overhaul (17 November 2026)

| Change | Measurement |
|---|---|
| Online neural voice (sidecar, warm WebSocket pool) | first phrase 0.30–0.57 s per request with warm connections (two in parallel 0.57 s; a 9-word phrase 0.71 s); a cold connection adds ≈0.45 s (opened on the wake word); after > 25 s idle a phrase took 1.7 s (reconnect) |
| Phrase pipeline | the first phrase is cut at the first clause ("Claro,") and plays from its first audio chunk; the next phrase is synthesised while it plays; model text is spoken while it is still being generated (held until 40–60 characters prove it is not a refusal or a bare "Done.") |
| Endpointing | 0.8 → 0.7 s of silence ends an utterance (migrated from the old default only) |
| Stop while working | "¡Para!" 9 s into a slow request: heard by the watcher 0.84 s segment, command cancelled and the session ended within 10 ms, nothing spoken, detector listening again (`fridayctl --voice`, live app) |
| `Scripts/voice-e2e.sh` | **11 / 12** (wake clip: Kokoro af_heart, commands: the online neural voice; the miss is the known synthetic "diecisiete por veinticuatro") — 10 / 12 before |

Findings on the way: Silero does not report a lone short synthetic "¡para!" as speech at all (the watcher uses the energy
detector); a bilingual recognition keeps the longer hypothesis and heard "¡Para!" as "But uh." (the watcher recognises
each language separately); `URLSession.AsyncBytes.lines` drops the empty lines that end SSE events, so every Responses
API stream failed with "The stream ended before the response completed" (fixed in `SSEStream.lines`).

### Second-opinion recognition with faster-whisper (21 November 2026)

Apple's recogniser streams and finishes ≈0.13 s after the user stops, but garbles some Spanish (numbers above all) and
says so through its confidence. On the eight e2e command clips:

| Recogniser | Exact | Time after the end of speech | Note |
|---|---|---|---|
| Apple `SpeechAnalyzer` (bilingual) | 7 / 8 | ≈ 0.13 s | the miss, "de asiciete, por venti cuatro", had confidence **0.58**; "¡Para!" → "But..." **0.31**; right answers 0.92–1.00 |
| faster-whisper `small` int8, CPU (8 threads) | 8 / 8 | 0.62–0.75 s (mean 0.68) | model 0.6 s to load from cache |
| faster-whisper `large-v3-turbo` int8, CPU | 8 / 8 | mean 3.29 s | too slow |
| faster-whisper `large-v3-turbo` fp16, MPS (experimental) | 8 / 8 | mean 0.68 s | experimental backend |

So Whisper is not faster, but it is more accurate: Friday keeps Apple's transcript when its confidence is ≥ 0.8 (no cost
in the common case) and asks faster-whisper `small` in the sidecar (`/api/stt/check`, CPU, so it never competes with
Laya or a local model on the GPU) otherwise, within a 2.5 s budget. Live, "¿cuánto es diecisiete por veinticuatro?"
now reaches `utilities.calculate`.

Not adopted: **obscura** (a from-scratch Rust/V8 browser engine). It speaks CDP, but it is pre-1.0 with a single
maintainer, built for bot-detection evasion (spoofed Windows Chrome fingerprint), unsigned binaries, and by its own
account weak on heavy sites (Amazon, airlines, rich editors) — Chrome stays the browser agent's engine.

### Local model sizing (Ollama, qwen2.5 7B q4, 8k default window)

| Tool schemas in the prompt | Prompt tokens | Time | Answer to "What is the capital of Australia?" |
|---|---|---|---|
| 10 | 1 510 | 2.5 s | "The capital of Australia is Canberra." |
| 30 | 3 899 | 4.9 s | starts "looking it up" instead of answering |
| 60 | 6 892 | 6.2 s | same |
| 200 (whole catalogue, ≈ 50k tokens) | truncated by the server | 11.8 s | empty |

Hence the per-model tool budget (20 for local servers, 64 for hosted models) and the native Ollama API with an
explicit 16k context (`OllamaClient`). Through the native API the same 7B model answers the question in 1.8 s and
emits a correct `reminders__create` tool call in 0.65 s (`LocalModelTests`).

## Intelligence

| Stage | Measurement | How |
|---|---|---|
| Keyword routing (Swift, bilingual) | < 1 ms | unit tests |
| Laya routing through the sidecar (HTTP, warm) | **75–80 ms** per request (99 ms worst seen); rules-only path 1.4–1.6 ms over HTTP; model load 118 ms + warm-up 69 ms at sidecar start | sidecar smoke run, `POST /api/route` |
| Laya accuracy (zero-shot, 13 categories, English) | 9/13 correct; misses go to the catch-all; `dangerous` separates well (0.58 for a delete vs ≤ 0.31 benign) | sidecar probe; see `Sidecar/README.md` |
| Fast path (deterministic rules + parser) | 1–8 ms end-to-end through the engine (`fridayctl "what time is it"`: 1 ms; `"open Notes"`: 300 ms including the launch) | `fridayctl` timings from the engine's `durationMs` |
| Apple on-device model (fallback) | 1–4 s per answer; 4k-token window — Friday sends it ≤ 10 tools and compact results | `fridayctl` with no cloud provider |
| Local 7B model (Ollama, native API) | general question 0.7–1.8 s; "abre Notas"-class commands that miss the fast path 0.4–0.6 s; calendar question with tool round 7–13 s; Spanish calendar listing 14.9 s typed | `fridayctl --say`, `LocalModelTests` |
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
