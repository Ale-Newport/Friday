# Capability matrix

Legend — **Verified**: exercised on this Mac during the build (automated test or a live run through `fridayctl`,
the app's socket). **Unit-tested**: covered by the automated suites with fakes (the integration code is unchanged from
Apple-Integrations, whose live behaviour that project verified). **Needs a model**: the planner path; works with any
connected provider, exercised here only with Apple's on-device model (no ChatGPT account was connected during the
build). **Pending user**: needs a macOS permission prompt or account only the user can grant. **Unsupported**: a
platform limit, reported honestly by the tool.

## Voice

| Capability | State | Evidence |
|---|---|---|
| Wake word "Jarvis", local, low power | Verified (engine) / Pending user (microphone prompt) | 553 wake-word tests pass; the app starts the runtime; the Speech project's measurements |
| Configurable wake word | Partial | Settings field; needs a keyword the model can express (docs/KNOWN_LIMITATIONS.md) |
| Command in the same breath ("Jarvis open Chrome") | Verified (design + unit) | ring buffer read from the wake word's `audioEndTime`; `MicrophoneRecorderTests` |
| Spanish / English / mixed recognition, on device | **Verified** | WER 0.05 on Kokoro-synthesised sentences, finalisation ≈130 ms |
| End of utterance (Silero / energy) | Verified | `SileroVoiceActivityDetectorTests`, `EnergyVADTests` |
| Follow-ups without the wake word (conversation mode) | Implemented | `Assistant.handleActivation` loop; not exercised live (no microphone input in this session) |
| Interruptions ("stop", "cancel", "espera") and barge-in while speaking | Implemented | `Assistant.process` stop phrases; sustained-speech barge-in; not exercised live |
| Spoken replies in the reply's language (Kokoro, Apple fallback) | **Verified** | Kokoro EN/ES samples generated; `SpeechOutput` picks the voice per language |
| Keyboard shortcut, menu bar, chat input, click-to-talk | Verified (build) | ⌃⌥Space registered via Carbon; menu bar and chat windows |

## Understanding

| Capability | State | Evidence |
|---|---|---|
| Fillers, wake-word residue, "no wait" corrections (EN/ES) | **Verified** | `UtteranceNormalizerTests` |
| Deterministic fast path (time/date, open/close apps incl. Spanish names, arithmetic, Friday timers, "remember that …", music/system commands) | **Verified live** | `fridayctl`: "what time is it", "qué hora es", "open Notes", "abre Calculadora", "cierra Calculadora", "pon pausa", "what's 17 times 24", "cuánto es 2450 por 17,5 por ciento", "remember that my study playlist is called Deep Focus" |
| Keyword routing (bilingual) | **Verified** | `KeywordRouterTests` |
| Laya routing through the sidecar | **Verified** | sidecar tests (187) + live `POST /api/route` (75–80 ms) |
| Planner: tool subset, function calling, batch rule, discovery (`friday.find_tools`), questions to the user (`friday.ask_user`) | **Verified** | `EnginePipelineTests` (scripted model drives the real engine end to end) |
| Provider chain ChatGPT → API key → compatible → Apple on-device, never a silent paid fallback | Verified (unit) / Pending user (sign-in) | `ProviderRegistry`; sign-in needs the user's browser |
| Sign in with ChatGPT (dynamic registration, PKCE, loopback, refresh, revoke, JWKS) | Implemented, pending user | documented flow; cannot be exercised without the user's account |
| Apple on-device model as offline fallback | **Verified live** | "what's the capital of France" → "Paris"; "¿quién escribió El Quijote?" → Cervantes |
| Context across turns, memory of facts | **Verified live** | "remember that …" then "what is my study playlist called" recalls it |

## Apple apps (136 tools from Apple-Integrations, unchanged)

| Integration | State | Notes |
|---|---|---|
| Music (play/pause/next/volume/playlists/shuffle/repeat, fuzzy library matching, catalog) | Verified live (pause, playlist listing) + unit-tested | Automation consent granted during the run |
| Reminders (create/list/update/complete/delete, lists, recurrence, batch) | Verified live (create with date) + unit-tested | sections/subtasks: **Unsupported** (EventKit) |
| Notes (create/search/read/append/update/folders/merge/backups) | Unit-tested; pending Automation prompt | |
| Calendar (events, conflicts, free slots, recurrence, time zones) | Verified live (list) + unit-tested | |
| Contacts | Unit-tested; off by default | |
| Mail (search/read/draft/reply/send with confirmation) / Messages | Unit-tested; pending Automation prompt | delivery unverifiable |
| Clock alarms/timers via Shortcuts | **Unsupported until the user creates the Shortcuts**; Friday's own timers verified (pending notification permission) | |
| Weather (Open-Meteo), maths, conversions, currency | Unit-tested; weather needs network | |
| System: volume, brightness, open/close apps, clipboard, settings panes, screenshot | Verified live (open/close) + unit-tested | |
| Files: search, metadata, read, move/copy/rename/trash, duplicates, organize, compress/extract, convert text/image | Unit-tested (approved roots) | |
| Browser tabs (Safari/Chrome tab reading) | Unit-tested; needs "Allow JavaScript from Apple Events" | |

## New capabilities

| Capability | State | Evidence |
|---|---|---|
| Browser agent (`web.task`, status, connect, cancel, focus) through the sidecar | Verified (sidecar runs as Friday's child; status/connect live) / Needs a model for tasks | the agent's own 187 unit tests; browsing tasks need the planning model |
| Computer control: windows, displays, focus, arrange, UI tree, click, type, keys, menus, selected text | Verified (live AX capture, window list, menu bar) | 54 `FridayComputerTests`; mutating actions unit-tested only |
| Screen understanding: screenshot + OCR + AX description | **Verified live** | `LiveScreenTests` (1600×1034 capture, 64 OCR lines) |
| Dark mode / lock screen | Implemented (`computer.set_appearance`, `computer.lock_screen`) | not exercised live |
| Memory: preferences, entities, knowledge, conversations, tasks, routines, export, disable | **Verified** | 21 `FridayMemoryTests` + live remember/recall |
| Scheduled commands ("at 8 PM …", daily/weekdays/weekly) | Implemented; unit-level only | `ScheduleIntegration` + `CommandScheduler` (runs while Friday is open) |
| Routines (save trigger phrases → tool steps, fuzzy EN/ES match, run without a model) | Verified (unit) | `FridayMemoryTests` |
| Local control channel (`fridayctl`, socket) | **Verified live** | ping/status/tools/commands |
| Permissions UI, provider status, diagnostics with latency table | Verified (build) | |

## Not built

* Voice lesson UI ("teach Friday your voice") — the engine supports it (`VoiceTuner`, `friday-bench kws-tune`); the window was not ported.
* Automatic offer to save repeated workflows as routines — routines are saved on request only.
* Image input to the model for screen questions — text (AX + OCR) only.
* Spotify, WhatsApp, Slack, Notion, Home Assistant … — not implemented and not claimed.
