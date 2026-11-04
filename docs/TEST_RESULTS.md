# Test results

*4 November 2026, macOS 27.0.1, M2 Max. Automated results are from `swift test` (final run) and the sidecar's
`pytest`; live results from `fridayctl` against the running Debug app. No ChatGPT account or API key was connected
during the build, so model-driven scenarios ran on Apple's on-device model or are marked as needing a provider.*

## Automated suites

| Suite | Tests | Result |
|---|---|---|
| Wake word (WakeWordKit, FridayAudio, WakeWordCore, FridayPlatform, backends, ArchitectureTests) | 109 + 189 + 145 + 30 + 21 + 17 + 13 | all pass (incl. real sherpa-onnx detections of a spoken "Jarvis" with the Mac's voices, chaos tests, boundary rules) |
| Action engine and Apple integrations (FridayCore, FridayInterpreter, FridayIntegrations, FridayIPC — XCTest) | 240 (1 skipped: needs a local Ollama) | all pass |
| FridayIntelligence (normaliser, router, PKCE/JWT, Responses requests, tiering, planner selection/validation, engine pipeline with a scripted model) | 30 | all pass |
| FridaySpeech (energy VAD, ring buffer) | 4 | all pass |
| SherpaOnnxSpeech (Kokoro EN/ES/GB synthesis, rate, cancellation; Silero segments; **Apple recogniser benchmark**) | 16 | all pass — WER 0.05–0.06 over 10 sentences |
| FridayMemory | 21 | all pass |
| FridayComputer (shortcuts, geometry, safety, UI tree, tool contracts, live AX/display/screen) | 54 | all pass — live suites ran (runner is trusted for Accessibility and Screen Recording) |
| FridayBrowser | 4 | all pass |
| FridayAssistant (spoken-text cleaning) | 3 | all pass |
| Sidecar (`pytest tests --ignore=tests/integration`): routing rules + real Laya, Responses API body/SSE, LLM session, env prefixes, watchdog, STT contract | 187 (5 skipped) | all pass |
| **Total** | **893 Swift + 187 Python** | **0 failures** |

Not run: `Sidecar/tests/integration` (opens real Chrome windows and needs a text model) — unchanged from the Jarvis
project, where it passed.

## Acceptance scenarios

Status: **Passed** (verified here), **Partial** (works with a caveat), **Needs provider/permission** (implemented;
cannot be verified without the user's account, microphone, or a macOS prompt), **Unsupported** (platform), **Failed**.

### Voice and understanding

| # | Scenario | Status | Evidence / next action |
|---|---|---|---|
| 1 | "Jarvis, open Chrome." | Passed (pipeline) | wake word unit-tested; `fridayctl "open Chrome"` → fast rule → `system.open_app` (verified with Notes/Calculator); recognition of the sentence WER 0 |
| 2 | "Jarvis, abre Chrome." | Passed (pipeline) | Spanish fast rule + app aliases; recognition WER 0 |
| 3 | "open... no, wait, open Notes instead." | Passed | `UtteranceNormalizerTests`; recognition of the corrected sentence WER 0 |
| 4 | "pon la canción esa de Queen, bohemian something" | Partial | recogniser heard "Ken" for "Queen" (Spanish lane); the planner's fuzzy music search needs a model to resolve "bohemian something" — with the on-device model it lists playlists instead |
| 5 | "add milk, actually oat milk, to my groceries list" | Passed (engine) | `EnginePipelineTests` creates exactly "Almond milk"/"Oat milk"-style titles from a corrected sentence; recognition WER 0 |
| 6 | "abre Google and search for machine learning" | Partial | recognition WER 0.29 on the code-switched sentence ("and search" mangled); needs the browser agent + model |
| 7 | "Jarvis... um... what's the weather tomorrow?" | Needs provider | fillers stripped (unit); weather tool exists (Open-Meteo); the deterministic parser handles "weather tomorrow" directly — not run live (network call) |
| 8 | "no, stop what you're doing." | Passed (unit) | stop phrases → `Assistant.interrupt()`; `fridayctl` cancels via the engine's cancellation |
| 9 | Long pauses and changes of mind | Needs microphone | endpointing waits `endpointSilenceSeconds`; corrections normalised; not exercised with a live microphone |
| 10 | Same command in Spanish, English and mixed | Passed | time/date, open/close apps, arithmetic and timers verified in both languages via `fridayctl` |

### Apple integrations

| # | Scenario | Status | Evidence |
|---|---|---|---|
| 11 | Play a song | Needs permission | `music.play` unit-tested; Automation consent for Music was granted during the run ("pon pausa" → "Música ya estaba en pausa") |
| 12 | Play a playlist with an approximate name | Partial | fuzzy matching unit-tested; live run listed the user's playlists; choosing needs a model or an exact name |
| 13 | Reminder in a list and section | Unsupported (section) | reminder created in the list; sections are not in EventKit — reported honestly |
| 14 | Reminder subtask | Unsupported | same (no public API) |
| 15 | Change a reminder's date | Passed (unit) | `RemindersIntegrationTests`; live create verified ("recuérdame comprar leche mañana a las 8") |
| 16 | Find and update a note | Needs permission | Notes Automation prompt not answered in this session; unit-tested |
| 17 | Create a calendar event | Passed (unit) / Needs provider live | Calendar listing verified live (11 events) |
| 18 | Find an event by approximate description | Needs provider | fuzzy search exists; approximate descriptions need the model |
| 19 | Create a timer | Needs permission | Friday timers: `fridayctl "set a timer for 25 minutes"` → asks for the notification permission (correct); native Clock timers need the user's Shortcuts |
| 20 | Search Mail and summarise a thread | Needs permission + provider | `mail.search/read` unit-tested; summary needs a model |

### Browser

| # | Scenario | Status | Evidence |
|---|---|---|---|
| 21–27 | Google search, open a site, tabs, extract, compare, download, harmless form | Needs provider | sidecar connected Chrome live (`web.connect` → "Chrome está conectado"); tasks need the planning model; the agent's own suites cover these flows |
| 28 | Recover from a changed page structure | Passed (agent) | freshness markers and re-planning in the sidecar (unchanged, unit-tested) |

### Computer control

| # | Scenario | Status | Evidence |
|---|---|---|---|
| 29 | Open and close an application | **Passed live** | "open Notes" → "Opened Notes"; "abre Calculadora"/"cierra Calculadora" |
| 30 | Resize and reposition windows | Passed (unit) | geometry and presets tested; live mutation not run (would move the user's windows) |
| 31 | Locate a file | Passed (unit) | `files.search` (approved roots) |
| 32 | Organise files in a test directory | Passed (unit) | `files.organize` tests |
| 33 | Read selected text | Passed (live, Accessibility) | `AccessibilityService.selectedText` (live suite ran) |
| 34 | Summarise the current web page | Needs provider | `browser.read_tab` + model |
| 35 | Explain a screenshot | **Passed live (capture + OCR)** | 1600×1034 JPEG, 64 OCR lines, AX description; explanation needs a model (text-only) |

### Multi-step intelligence

| # | Scenario | Status | Evidence |
|---|---|---|---|
| 36 | Search, summarise, save in Notes | Needs provider | planner loop verified with a scripted model (`EnginePipelineTests`) |
| 37 | Document → reminders from real deadlines | Needs provider | same; the prompt forbids inventing deadlines |
| 38 | Weather → conditional reminder change | Needs provider | same |
| 39 | Web page → structured data → CSV | Needs provider | `web.task` extraction cards + `files.*` |
| 40 | Folder → document → open | Needs provider | `files.create_folder`, `files.*`, `files.open` |

### Context and memory

| # | Scenario | Status | Evidence |
|---|---|---|---|
| 41 | Refer to the previous turn's document | Passed (engine) | conversation turns are replayed to the model (unit) |
| 42 | Correct an earlier instruction | Passed (engine) | new instruction supersedes pending actions (engine tests) |
| 43 | Follow-up without "Jarvis" | Needs microphone | conversation mode implemented |
| 44 | Save and invoke a reusable workflow | Passed (unit) | routines save/fuzzy match/run without a model |
| 45 | Restart and recover persisted state | **Passed live** | memory (SQLite), schedule file and history survive relaunch; "remember … Deep Focus" recalled after restart |

### Reliability

| # | Scenario | Status | Evidence |
|---|---|---|---|
| 46 | Microphone disconnected mid-session | Passed (unit) | wake-word runtime chaos/lifecycle tests (device loss, fallback, retry) |
| 47 | Chrome restarted during a task | Partial | the sidecar reports the task failed/partial; Friday reports it honestly; automatic resume not implemented |
| 48 | Permission denied | **Passed live** | timers and Music report `permission_required` with the Settings link |
| 49 | LLM provider outage | Passed (unit + live) | provider fallback chain; with no provider Friday says so ("I can't reach a language model…") |
| 50 | Interrupt speech synthesis | Passed (unit) | Kokoro cancellation test; player `stop()` |
| 51 | Cancel a running multi-step task | Passed (engine) | task cancellation + `web.cancel` |
| 52 | Recover from a failed tool | Passed (engine) | failed steps stop dependents, independent steps continue, partial status reported |
| 53 | Prompt injection in a web page | Passed (design + agent tests) | page text is data in every prompt; the sidecar's injection tests; tools validated by schema |
| 54 | No duplicate action after retry | Passed (engine) | duplicate guard + uncertain-write quarantine tests |
| 55 | Sleep/wake | Passed (unit) | runtime sleep/wake tests from the Speech project |

### Failures

None of the automated suites fail. Live scenarios that could not be completed are listed above with their cause
(no provider connected, a permission prompt only the user can answer, or a platform limit). The corrective action for
every "Needs provider" row is the same: Settings ▸ Intelligence ▸ Continue with ChatGPT (or an API key / local server).
