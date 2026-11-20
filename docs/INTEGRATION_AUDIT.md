# Integration audit

*Written 4 November 2026, before and during the merge. Facts about the source projects come from reading their code
(not their READMEs) and from measurements on this Mac: macOS 27.0.1, Apple M2 Max, 64 GB, Xcode 27.2 / Swift 6.4.2,
Python 3.12/3.13 with `uv`, XcodeGen 2.45.4.*

## 1. What each project brings

### Speech (earlier project) — the wake word

| | |
|---|---|
| Stack | Swift 6 strict concurrency, SwiftPM package `JarvisKit` + XcodeGen menu-bar app; macOS 14 target, **needs the macOS 27 SDK** (one `AVAudioEngine` API behind `#available`). |
| Detector | sherpa-onnx keyword spotting (Apache-2.0, no key, no network), zipformer `zh-en` 3 M model, "Jarvis" as four phoneme spellings; optional Picovoice Porcupine (paid key). |
| Pipeline | mic (AVAudioEngine tap, hardware rate, 100 ms buffers) → resampler/framing → engine → validator (cooldown 2 s, debounce 0.6 s) → activation state machine → `AssistantActivationHandler`. |
| Measured | 0.09 % CPU / 2.1 mW listening in a quiet room, 1.5 % while sound is present; detection 411–504 ms after the end of the word; 96 % hit rate for English voices, 61 % for Spanish-accented ones; **Spanish speech produces false activations ("ya había")** — mid sensitivity is the measured compromise. |
| Reusable | `WakeWordRuntime` (lifecycle, device changes, sleep/wake, retries), `AssistantActivationHandler` contract (detector gated while the handler runs), `setAudioTap` (raw mic audio delivered after the wake word **without a second capture**), `UtteranceSplitter` (energy endpointing), `StreamingResampler`, `MacSpeech` (`say`-based test audio), `KeychainCredentialStore`, login item, HUD panel, diagnostics, ~550 tests, `ArchitectureBoundaryTests`. |
| Gaps | No STT, no TTS, no assistant; the vendored sherpa dylib is the **no-TTS** build (TTS symbols are stubs). |

### Apple-Integrations (earlier project) — the action engine

| | |
|---|---|
| Stack | Swift 6, SwiftPM `JarvisKit` (JarvisCore, JarvisInterpreter, JarvisIntegrations, JarvisIPC, jarvisctl) + XcodeGen SwiftUI app; macOS 14. |
| Engine | `ActionEngine` actor: text → interpreter → typed `ToolPlan` → schema validation → permission check → duplicate guard → execution with deadline → verified `ToolResult`; single-use confirmation/clarification tokens; observe/replan loop for model-driven workflows; history. |
| Tools | **136 typed tools** across Music (AppleScript), Catalog (iTunes Search), Reminders and Calendar (EventKit), Notes (AppleScript), Clock (user-made Shortcuts), Friday-native timers/stopwatch, Contacts, Mail, Messages, Files (approved roots), Browser tabs (AppleScript), Research (SearXNG), System (volume, brightness, apps, clipboard, screenshot, settings panes), Workflows (Shortcuts), Weather (Open-Meteo), Utilities (math, conversions, currency), Conditions (rain checks via a launchd helper). |
| Interpretation | Deterministic bilingual EN/ES parser (clause splitting, natural dates, contextual follow-ups) + OpenAI-compatible chat-completions interpreter with native function calling and JSON fallback. |
| Reusable | Everything: the engine, the `AppIntegration` contract, the registry/validator, the interpreters, the AppleScript/EventKit/Shortcuts runners, Keychain store, history, IPC socket + `jarvisctl`, 560 tests. |
| Gaps | No voice, no Chrome agent, no ChatGPT sign-in, no memory beyond explicit aliases, no computer control (AX/windows), no planning beyond the provider's chat completions; Reminders **sections/subtasks and native Clock** are platform-limited (documented, honest). |

### Jarvis (earlier project) — the Chrome agent

| | |
|---|---|
| Stack | Python 3.12 (`uv`), FastAPI sidecar bound to 127.0.0.1 with a bearer token; Tauri 2 + React shell (not needed by Friday). |
| Browser | Chrome DevTools Protocol on one persistent connection, managed automation profile or attach to the user's Chrome (with its consent sheet); in-page runtime (from jev-ultrafast, MIT) giving indexed, hit-tested elements and freshness markers. |
| Decisions | **Laya** (421 M typed-decision model, Apache-2.0) on MLX: `choice`/`score`/`noul` questions with probabilities; ~16 ms per question; checkpoint already cached (807 MiB). A text model (OpenAI-compatible) plans ≤ 8 typed steps and replans ≤ 6 times. |
| Safety | Confirmations for purchase/payment/destructive/account/send labels; CAPTCHA/login pauses; budgets; grounded extraction (values must appear on the page); untrusted page text. |
| Reusable | The whole backend as a process; its HTTP/WebSocket API; `laya_engine` for routing questions. |
| Gaps | Needs a text model (Ollama was configured but is not running here); Laya checkpoint is English-only; no voice; the Tauri UI duplicates what Friday's native app does. |

### Atticus for Mac (`github.com/SaarthurR/atticus-mac`, MIT) — reference

Single-file AppKit app (8.5 k lines) + Python "brain" driving Claude Code; macOS 26+. Not adopted as an architecture
(shell-command tools, private SkyLight APIs, HTML UI, `say` TTS). Adapted with attribution (`NOTICE-ATTICUS.md`): the
Accessibility helper core (tree capture with stable ids, label resolution, actions, shortcut parser, secure-field
masking), window helpers, ScreenCaptureKit screenshot + Vision OCR, the permissions helper and the overlay-panel
configuration. Its `enum Hands` adapts ideas from Plip (MIT, Hussain) — that notice is kept too.

## 2. Reusable vs duplicated vs missing

**Duplicated across projects (resolved):**

* Two SwiftPM packages both named `JarvisKit`, both with a `JarvisCore` module → copied into one package `FridayKit`
  with renames where names collided (`JarvisCore`→`WakeWordCore` / `FridayCore`, `JarvisAudio`→`FridayAudio`,
  `JarvisPlatform`→`FridayPlatform`); file contents unchanged apart from `import` lines and identity strings.
* Two Keychain stores (`KeychainCredentialStore` for engine keys, `KeychainSecretStore` for model keys) — both kept, one
  service name `com.alejandro.friday`.
* Two settings mechanisms (wake-word `SettingsStore`, engine `UserDefaultsSettingsStore`) — kept; Friday adds one JSON
  store for voice and intelligence settings.
* Two menu-bar apps, two settings windows, two chat/HUD surfaces → one app in `App/`, reusing the HUD panel and the
  chat/settings patterns.
* Jarvis's Tauri shell and React UI → replaced by the native app; its sidecar launcher (`backend.rs`) → `SidecarProcess`.
* Two "browser" integrations: the AppleScript tab reader (`browser.*`) stays for reading the current Safari/Chrome tab;
  the autonomous agent is `web.*`.

**Missing before Friday (built):** speech recognition, text-to-speech, voice session (endpointing, barge-in,
follow-ups), ChatGPT sign-in and the Responses API, provider fallback chain, Laya *intent* routing (the sidecar only
used Laya for page decisions), planner with tool discovery, persistent memory and routines, computer control, screen
understanding, a single assistant for voice and chat.

## 3. Dependencies

| Component | Dependency | Licence | Network |
|---|---|---|---|
| Wake word, TTS, VAD | sherpa-onnx 1.13.8 + ONNX Runtime (vendored dylibs, SHA-256 pinned) | Apache-2.0 / MIT | none |
| Wake-word model | `sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20` | see `docs/LICENSING_AND_PRIVACY.md` of the Speech project | none |
| TTS model | Kokoro-82M v1.0 multilingual (sherpa-onnx export, int8) + espeak-ng data | Apache-2.0 (Kokoro), GPL-3.0 (espeak-ng data, used as data files by the library) | none |
| VAD model | Silero VAD v5 ONNX | MIT | none |
| STT | Apple `SpeechAnalyzer` (macOS 26+; Spanish and English assets installed) | system | none |
| Routing | Laya typed decisions (`aac6fef/laya-typed-decisions-mlx`, Apache-2.0) via `laya-mlx` 0.4 in the sidecar | Apache-2.0 | one-time download |
| Planning | ChatGPT plan (Sign in with ChatGPT, Responses API) / OpenAI API key / OpenAI-compatible server / Apple FoundationModels | per provider | yes for cloud providers |
| Browser | Chrome DevTools Protocol, FastAPI, httpx, websockets, keyring | BSD/MIT | local |
| Memory | SQLite (system) with FTS5 | public domain | none |

## 4. Compatibility

* macOS 27.0.1 here; deployment target 14.0, but voice needs macOS 26+ (`SpeechAnalyzer`) and the capture source needs
  the macOS 27 SDK to **build**. Older systems get the deterministic parser and Apple voices only (untested).
* Apple Silicon required for Laya (MLX); Intel Macs get rule-based routing and no browser agent.
* Atticus requires macOS 26+; only self-contained helpers were adapted, under Swift 6 strict concurrency.
* `MusicKit`'s `SystemMusicPlayer` is unavailable on macOS; the Music app stays under AppleScript (as in
  Apple-Integrations). `EKReminder` has no sections or subtasks (confirmed in the current SDK): those tools stay
  declared and unsupported, with an honest explanation.
* The vendored sherpa dylib had to change from the "no-tts" to the full build of the **same** version (1.13.8), which
  is also the last release bundling espeak-ng — required for Spanish Kokoro output. Newer sherpa-onnx (2.x) dropped
  espeak-ng and would need client-side phonemization.

## 5. Security concerns and how Friday handles them

* **Prompt injection from pages, notes, tool results**: every model prompt labels such content as data; the planner only
  turns model output into typed tool calls that are validated against schemas; destructive tools confirm; the browser
  agent never executes model-written selectors or JavaScript and treats page text as untrusted.
* **Credentials**: ChatGPT tokens, API keys and engine keys live in the Keychain; the sidecar receives the model token
  through an in-memory session endpoint (never persisted there); no secrets in logs (`privacy: .private`), none from the
  environment outside the benchmark tool (enforced by `ArchitectureBoundaryTests`).
* **Local services**: the sidecar binds 127.0.0.1 with a per-launch random bearer token and Host checks; the IPC socket
  is user-only (0600, peer-uid check).
* **Permissions**: requested lazily per capability with a rationale; Accessibility and Screen Recording are asked only
  by computer-control tools; the app never approves macOS prompts itself.
* **Risky actions**: deletions, sends, purchases, closing windows, risky UI labels (Delete/Pay/Send and Spanish
  equivalents) require explicit confirmation; the browser agent's purchase/payment confirmations cannot be disabled.
* **Residual risks (documented in KNOWN_LIMITATIONS.md)**: the sherpa library aborts the process on malformed model
  input (mitigated by SHA-256 checks and byte-exact keyword validation, inherited from Speech); hardened runtime is off
  for ad-hoc builds so the dylibs load — enable it with a real signing identity (`Config/Local.xcconfig`).

## 6. Architecture selected for Friday

One native app, one Swift package, one Python process:

```
Friday.app (SwiftUI, menu bar + panel + chat + settings)
 └─ FridayKit
     ├─ wake word: WakeWordKit · SherpaOnnxBackend/CSherpaOnnx · PorcupineBackend · FridayAudio · WakeWordCore · FridayPlatform   (from Speech)
     ├─ actions:   FridayCore (ActionEngine, ToolRegistry, validation, permissions, confirmations) · FridayInterpreter · FridayIntegrations (136 tools) · FridayIPC/fridayctl   (from Apple-Integrations)
     ├─ speech:    FridaySpeech (contracts, mic ring buffer, Apple SpeechAnalyzer, Apple voices, energy VAD, player) · SherpaOnnxSpeech (Kokoro, Silero)   (new)
     ├─ brain:     FridayIntelligence (ChatGPT sign-in, Responses/Chat Completions clients, provider chain, Laya/keyword router, planner, meta tools)   (new)
     ├─ skills:    FridayBrowser (web.* through the sidecar) · FridayComputer (AX, windows, screen) · FridayMemory (SQLite memory, routines, tasks)   (new)
     └─ glue:      FridaySidecar (process + client) · FridayAssistant (voice session, speech output, one pipeline for voice and chat)   (new)
 └─ Sidecar/ (Python): Chrome agent + Laya decisions + /api/route + Responses-API planner support   (from Jarvis, extended)
```

The request pipeline is: wake word → ring-buffer audio from the end of the keyword → VAD + streaming STT → normalise →
routine? → deterministic fast path (obvious, low-risk) → rules/Laya route → tool subset → language model with function
tools (ChatGPT → API key → local → Apple on-device) → Action Engine (validate, permission, confirm, execute, verify)
→ observe/replan → spoken reply → optional follow-up window. Typed commands enter at "normalise".

Decisions and reasons:

* **Keep the Action Engine as the single tool system.** It already enforces validation, permissions, confirmations,
  duplicate protection, deadlines and verification; new capabilities are `AppIntegration`s, so voice, chat, IPC and the
  planner all go through the same rules.
* **Keep the browser agent in Python.** It owns MLX (Laya) and CDP and has integration tests against real Chrome;
  rewriting it in Swift would be a regression risk with no user-visible gain. Friday drives it over its local API and
  passes its own model credentials through an in-memory session.
* **Native speech first.** Apple's `SpeechAnalyzer` is on-device, streams partial results, has Spanish and English
  assets installed and needs no download; Whisper (mlx-whisper) is available as an optional sidecar engine for
  comparison. Kokoro runs in-process through the same sherpa-onnx library that already does wake-word detection.
* **Laya as the fast layer, not the brain.** Keyword rules answer the obvious cases in microseconds; Laya answers the rest
  in ~75 ms (measured over HTTP); low confidence falls through to the planner with the full tool catalogue, and the
  planner can always ask for more tools (`friday.find_tools`).
* **ChatGPT through the documented flow only** (dynamic registration, PKCE, loopback redirect, Responses API at
  api.openai.com, model list from the account) with an API key, a local server and Apple's on-device model as
  explicit, never silent, fallbacks.
