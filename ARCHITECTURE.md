# Architecture

```
                 ┌──────────────── Friday.app (SwiftUI) ────────────────┐
  menu bar · assistant panel (HUD) · chat window · settings · diagnostics · fridayctl (IPC)
                 └───────────────────────┬──────────────────────────────┘
                                         ▼
                              FridayAssistant.Assistant (actor)
          voice session: wake word → ring buffer → VAD + STT → normalise → engine → speak → follow-ups
          chat: text → engine (same pipeline) → transcript
                                         ▼
                          FridayCore.ActionEngine (actor, from Apple-Integrations)
      interpreter → validation → permission → duplicate guard → execute with deadline → verified result
                 │                                                              ▲
                 ▼                                                              │ tools (AppIntegration)
      FridayIntelligence.FridayPlanner                      FridayIntegrations (136)  FridayBrowser (web.*)
      routine? → fast path → route (rules / Laya) →         FridayComputer (computer.*)  FridayMemory (memory.*, routines.*)
      tool subset → LLM (function tools) → next batch       FridayMetaIntegration (friday.find_tools, ask_user)
                 │
                 ▼ ProviderRegistry: ChatGPT plan (SIWC, Responses API) → OpenAI key → OpenAI-compatible → Apple on-device
```

## Modules (Swift package `FridayKit`)

| Module | Origin | Contents |
|---|---|---|
| `WakeWordKit`, `SherpaOnnxBackend`/`CSherpaOnnx`, `PorcupineBackend`/`CPorcupine` | Speech, unchanged | engine-independent detection pipeline, the free keyword-spotting backend (dlopen loader), the optional paid backend |
| `FridayAudio` (was JarvisAudio) | Speech | AVAudioEngine capture, Core Audio devices, microphone permission |
| `WakeWordCore` (was JarvisCore) | Speech | `WakeWordRuntime` supervisor, activation state machine, `AssistantActivationHandler`, diagnostics, voice lesson |
| `FridayPlatform` (was JarvisPlatform) | Speech | Keychain, login item, sleep/wake, network monitor, resource sampling |
| `FridayCore` (was JarvisCore) | Apple-Integrations | `ActionEngine`, `ToolDescriptor`/`ToolRegistry`/`ToolValidator`, `AppIntegration`, results, settings, history, secrets |
| `FridayInterpreter` | Apple-Integrations | deterministic EN/ES parser, natural dates, chat-completions interpreter (still available) |
| `FridayIntegrations` | Apple-Integrations | the 19 Apple/system integrations and their runners (AppleScript, EventKit, Shortcuts) |
| `FridayIPC`, `fridayctl` | Apple-Integrations | Unix-socket control channel and CLI |
| `FridaySpeech` | new | speech contracts, `MicrophoneRecorder` (16 kHz ring buffer on the wake-word tap), `AppleSpeechRecognizer` (SpeechAnalyzer, bilingual lanes), `AppleTextToSpeech`, `EnergyVoiceActivityDetector`, `SpeechPlayer` |
| `SherpaOnnxSpeech` | new | `KokoroTextToSpeech`, `SileroVoiceActivityDetector` (same dylib as the wake word; second loader table) |
| `FridayIntelligence` | new | `LLMProvider` contracts, `ResponsesAPIClient`, `ChatCompletionsClient`, `ChatGPTAuthService` (PKCE, loopback, refresh, revoke, JWKS), providers, `ProviderRegistry`, `IntentRouter` + `KeywordRouter`, `UtteranceNormalizer`, `FridayPlanner`, `FridayMetaIntegration` |
| `FridayBrowser` | new | `WebAgentIntegration`: `web.task` and friends over the sidecar API with approvals and progress |
| `FridayComputer` | new (parts adapted from atticus-mac) | Accessibility tree/actions, windows and displays, ScreenCaptureKit + Vision, permissions, `ComputerIntegration` |
| `FridayMemory` | new | SQLite (`MemoryStore`): preferences/entities/knowledge, conversations, tasks, routines; `MemoryIntegration` |
| `FridaySidecar` | new | `SidecarProcess` (spawn as direct parent, ready line, graceful stop), `SidecarClient` (HTTP + WebSocket) |
| `FridayAssistant` | new | `Assistant`, `VoiceListener`, `SpeechOutput`, settings, snapshot for the UI, wake-word bridge |

Rules kept from the source projects and enforced by `Tests/ArchitectureTests`: only a backend module imports its C
module; only the composition root (`App/Composition`) and tools name a backend; the core imports no UI framework; no
key-like literals; no credentials from the environment outside the benchmark tool.

## The request pipeline

1. **Activation** — `WakeWordRuntime` detects "Jarvis" and calls `Assistant.handleActivation`; the detector is gated
   until the session ends (so Friday's own voice cannot retrigger it). The `MicrophoneRecorder` has been receiving the
   raw microphone through the pipeline's audio tap all along, so the command spoken in the same breath is read from the
   ring buffer starting at the wake word's `audioEndTime`.
2. **Listening** — `VoiceListener` feeds the ring buffer to a VAD (Silero, else energy) and to `SpeechAnalyzer`
   transcribers (one per language; the better hypothesis wins); the utterance ends after `endpointSilenceSeconds` of
   silence or a maximum length; partial text goes to the HUD.
3. **Interpretation** — `FridayPlanner`: normalise (wake-word residue, fillers, "no wait" corrections) → saved
   routine → deterministic fast path for obvious low-risk commands → `IntentRouter` (keyword rules, then Laya through
   the sidecar) → tool subset → language model with function tools → one batch of reads or one write.
4. **Execution** — `ActionEngine` validates, checks permissions, guards duplicates, executes with a deadline, verifies,
   and calls the planner again with real results (`ToolPlan.continues`) until the model answers in prose.
5. **Reply** — `SpeechOutput` picks a voice for the reply's language (Kokoro, else Apple) and streams audio; the user
   can interrupt (sustained speech stops playback); with conversation mode on, Friday listens again without the wake word.

Confirmations (destructive tools, sends, browser purchases) surface as `PendingPrompt`s: spoken, shown in the HUD and
the chat, and answerable by voice ("yes"/"no"), buttons, or `fridayctl --confirm`.

## Processes

* **Friday.app** — everything above.
* **Sidecar** (`Sidecar/`, Python) — spawned by `SidecarProcess` as a direct child with a per-launch bearer token;
  provides Chrome automation (`/api/conversations/*`, `/api/tasks/*`), Laya routing (`/api/route`, `/api/laya/decide`)
  and the browser planner's model session (`PUT /api/llm/session`, in memory). It exits when Friday does.
* **Chrome** — launched by the sidecar with Friday's automation profile, or attached with the user's consent.
