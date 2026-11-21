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
| `WakeWordKit`, `SherpaOnnxBackend`/`CSherpaOnnx`, `PorcupineBackend`/`CPorcupine` | Speech (+ noise augmentation) | engine-independent detection pipeline, the free keyword-spotting backend (dlopen loader) whose `VoiceTuner` now also checks every recording over babble, music and pink noise (`NoiseAugmentation`), the optional paid backend |
| `FridayAudio` (was JarvisAudio) | Speech + new | AVAudioEngine capture, Core Audio devices, microphone permission; `InjectableCaptureSource` (plays a recording in place of the microphone for `fridayctl --voice` and the end-to-end voice tests) |
| `WakeWordCore` (was JarvisCore) | Speech + new | `WakeWordRuntime` supervisor, activation state machine, `AssistantActivationHandler`, diagnostics, voice lesson (`VoiceLessonScript.friday`: the name, intonations, the user's own variants, requests, ordinary talk — Settings ▸ General ▸ "Train “Jarvis”…"); `activateManually()` (hotkey, menu and mic button open a session even while the wake word is off) |
| `FridayPlatform` (was JarvisPlatform) | Speech | Keychain, login item, sleep/wake, network monitor, resource sampling |
| `FridayCore` (was JarvisCore) | Apple-Integrations | `ActionEngine`, `ToolDescriptor`/`ToolRegistry`/`ToolValidator`, `AppIntegration`, results, settings, history, secrets |
| `FridayInterpreter` | Apple-Integrations | deterministic EN/ES parser, natural dates, chat-completions interpreter (still available) |
| `FridayIntegrations` | Apple-Integrations | the 19 Apple/system integrations and their runners (AppleScript, EventKit, Shortcuts) |
| `FridayIPC`, `fridayctl` | Apple-Integrations | Unix-socket control channel and CLI |
| `FridaySpeech` | new | speech contracts, `MicrophoneRecorder` (16 kHz ring buffer on the wake-word tap), `AppleSpeechRecognizer` (SpeechAnalyzer, bilingual lanes, recognition vocabulary through `AnalysisContext.contextualStrings`), `AppleTextToSpeech`, `EnergyVoiceActivityDetector`, `VoiceActivityDetectorCache`, `SpeechPlayer` (survives output-device changes), `SpokenLanguage` (which voice speaks a mixed reply) |
| `SherpaOnnxSpeech` | new | `KokoroTextToSpeech`, `PiperTextToSpeech` (es_ES "miro", offline Spanish), `SileroVoiceActivityDetector` (same dylib as the wake word; second loader table) |
| `FridayIntelligence` | new | `LLMProvider` contracts, `ResponsesAPIClient`, `ChatCompletionsClient`, `OllamaClient` (native API with an explicit context window), `ChatGPTAuthService` (PKCE, loopback, refresh, revoke, JWKS), providers, `ProviderRegistry` (fallback chain; transport and auth errors mapped to typed, bilingual errors), `IntentRouter` + `KeywordRouter`, `UtteranceNormalizer`, `FridayPlanner` (per-model tool budget `ModelProfile`, Spanish-aware tool search, personal-data guard, `friday.ask_user` round trip, `maxToolRounds`), `FridayMetaIntegration` |
| `FridayBrowser` | new | `WebAgentIntegration`: `web.task` and friends over the sidecar API with approvals and progress; event stream resubscribes and the REST poller is the only terminator, so a dropped socket or an unanswered prompt never holds a task; bilingual approval texts from the sidecar's structured facts |
| `FridayComputer` | new (parts adapted from atticus-mac) | Accessibility tree/actions, windows and displays, ScreenCaptureKit + Vision, permissions, `ComputerIntegration` |
| `FridayMemory` | new | SQLite (`MemoryStore`): preferences/entities/knowledge, conversations, tasks, routines; `MemoryIntegration` |
| `FridaySidecar` | new | `SidecarProcess` (spawn as direct parent, ready line, graceful stop, restart with backoff when the child dies and an `onRestart` hook to re-apply the model session), `SidecarClient` (HTTP + WebSocket) |
| `FridayAssistant` | new | `Assistant` (commands queued per session, voice loop with end phrases, spoken answers to confirmations and browser prompts, echo guard, playback-calibrated barge-in), `VoiceListener` (endpointing, optional wake-word verification, dynamic vocabulary), `SpeechOutput` (also synthesises to files), settings, snapshot for the UI, wake-word bridge |

Rules kept from the source projects and enforced by `Tests/ArchitectureTests`: only a backend module imports its C
module; only the composition root (`App/Composition`) and tools name a backend; the core imports no UI framework; no
key-like literals; no credentials from the environment outside the benchmark tool.

## The request pipeline

1. **Activation** — `WakeWordRuntime` detects "Jarvis" and calls `Assistant.handleActivation`; the detector is gated
   until the session ends (so Friday's own voice cannot retrigger it). The `MicrophoneRecorder` has been receiving the
   raw microphone through the pipeline's audio tap all along, so the command spoken in the same breath is read from the
   ring buffer starting 0.6 s before the wake word's `audioEndTime` (the detector reports the end late; the normaliser
   drops any tail of "Jarvis" the recogniser hears). Optionally (`verifyWakeWord`) a quick recognition of that window
   confirms the keyword before the chime. The hotkey, the menu and the mic button reach the same path through
   `WakeWordRuntime.activateManually()`, with or without the detector running.
2. **Listening** — `VoiceListener` feeds the ring buffer to a VAD (Silero, else energy) and to `SpeechAnalyzer`
   transcribers (one per language; the better hypothesis wins); the utterance ends after `endpointSilenceSeconds` of
   silence or a maximum length; partial text goes to the HUD. A transcript with confidence below 0.8 (or speech with
   no words) gets a second opinion from faster-whisper `small` in the sidecar (`/api/stt/check`, 2.5 s budget).
3. **Interpretation** — `FridayPlanner`: normalise (wake-word residue, fillers, "no wait" corrections) → saved
   routine → deterministic fast path for obvious low-risk commands → `IntentRouter` (keyword rules, then Laya through
   the sidecar) → tool subset sized for the model (`ModelProfile`: 20 schemas for a local server, 64 for a hosted
   model, `friday.find_tools` for the rest) → language model with function tools → one batch of reads or one write.
   A request about the user's own data is accepted only when the model read it through a tool (one retry with a tool
   call required, then an honest refusal); an empty answer is nudged once, then summarised from the real results.
   Refusals ("I can't access the internet", "no tengo acceso…", `looksLikeRefusal`) are never passed on: a direct
   answer that refuses goes on to the tool path; a tool-path refusal is asked again with `web.task` offered and a tool
   required, and a web-shaped request that is still refused becomes a browser task with the user's own words
   (`browserFallback`; never for personal data or dangerous requests). Streamed text is held (`StreamGate`) until it
   is clearly neither a refusal nor a bare "Done." claim.
4. **Execution** — `ActionEngine` validates, checks permissions, guards duplicates, executes with a deadline, verifies,
   and calls the planner again with real results (`ToolPlan.continues`) until the model answers in prose.
5. **Reply** — spoken while it is still being generated: `VoiceReplyStream` turns the planner's streamed text into
   phrases (`SpeechSegmenter`: the first phrase is cut at the first clause, later ones at sentence ends), and
   `SpeechOutput` synthesises each phrase as soon as it arrives while the previous one plays. Each phrase is voiced by
   the first engine of the chain for its language that can say it: the online neural voice (Microsoft "Read aloud"
   through the sidecar's warm WebSocket pool, `/api/tts/*`), then Piper es_ES (offline Spanish), Kokoro and Apple.
   The wake word pre-opens the voice connections and pre-loads the local model (`ProviderRegistry.prewarm`).
   The user can interrupt (sustained speech louder than the playback stops it); with conversation mode on, Friday
   listens again without the wake word.
6. **Stop** — `VoiceListener.watchForCommand` runs next to the command and the reply (its own short-endpoint
   detector and one-off recognitions of short segments). "Para", "cállate", "basta", "stop", "gracias, eso es todo"
   (`Assistant.stopKind`) cancel the command, the speech and any open question and end the session silently, back to
   the wake word; "espera" stops and listens again. A command still working after 3 s gets a spoken "un momento".

Confirmations (destructive tools, sends, browser purchases) and questions (`friday.ask_user`, free text or options)
surface as `PendingPrompt`s: spoken, shown in the HUD and the chat, and answerable by voice ("yes"/"no", an option, or
the answer itself), buttons, or `fridayctl --confirm`/`--choose`. Commands queue per session: a new command from the
same session supersedes the running one; a scheduled or typed command waits for a voice command instead of aborting it.

## Processes

* **Friday.app** — everything above.
* **Sidecar** (`Sidecar/`, Python) — spawned by `SidecarProcess` as a direct child with a per-launch bearer token;
  provides Chrome automation (`/api/conversations/*`, `/api/tasks/*`), Laya routing (`/api/route`, `/api/laya/decide`)
  and the browser planner's model session (`PUT /api/llm/session`, in memory). It exits when Friday does.
* **Chrome** — launched by the sidecar with Friday's automation profile, or attached with the user's consent. If it
  dies mid-task the sidecar relaunches and reconnects (up to three times) and resumes the plan from the current step.
* **Friday Condition Agent.app** — a login item (`Contents/Library/LoginItems`, `LaunchAgents/com.alejandro.friday.conditions.plist`)
  that evaluates the rain-check conditions while Friday is not running; enabled from Settings ▸ Integrations.
* **Control channel** — `fridayctl` (`Contents/Helpers`) over `~/Library/Application Support/Friday/friday.sock`:
  engine requests plus the assistant-level `--say`, `--voice`, `--synthesize` and `--transcript` served by
  `AssistantIPCExtension` in the app.
