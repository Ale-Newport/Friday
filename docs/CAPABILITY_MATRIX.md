# Capability matrix

Legend — **Verified live**: exercised on this Mac on the integrated build through the running app (`fridayctl`,
synthesised audio played into the microphone pipeline, or the browser agent driving Chrome). **Verified (unit)**:
covered by the automated suites with fakes. **Needs a model**: the planner path; exercised here with a local Ollama
model (qwen2.5 7B / qwen3 8B), whose quality bounds the result; works with any connected provider and is expected to
be noticeably better with ChatGPT. **Pending user**: needs a macOS permission prompt or an account only the user can
grant. **Unsupported**: a platform limit, reported honestly by the tool.

## Voice

| Capability | State | Evidence |
|---|---|---|
| Wake word "Jarvis", local, low power | **Verified live** | 12-item bilingual corpus (`Scripts/voice-e2e.sh`): detection, capture from 0.6 s before the detector's keyword end, transcription, action, spoken reply; 553 wake-word tests |
| Optional wake-word verification (second recognition pass) | Verified (unit) | `WakeWordVerificationLatencyTests`: 12/12 correct on Kokoro clips, median 125 ms; off by default (Settings ▸ Voice) |
| Configurable wake word | Partial | Settings field; needs a keyword the model can express (docs/KNOWN_LIMITATIONS.md) |
| Command in the same breath ("Jarvis what time is it") | **Verified live** | corpus: "What time is it?" heard whole (was "is it?" before the capture margin) |
| Spanish / English / mixed recognition, on device, with dynamic vocabulary (app names, playlists, contacts) | **Verified live** | WER 0.05 benchmark; corpus; `ContextualStringsTests`; vocabulary of 166 names loaded at launch |
| End of utterance (Silero / energy) | Verified | `SileroVoiceActivityDetectorTests`, `EnergyVADTests`, one cached detector per listener |
| Follow-ups without the wake word (conversation mode), end phrases, re-prompt on unintelligible speech | Verified (unit, `VoiceLoopTests`) + live (sessions end promptly after replies) | |
| Interruptions ("stop", "cancel", "espera") and barge-in while speaking | Verified (unit): `bargeInStopsTheSpeechAndHearsTheInterruption`; playback-calibrated floor, echo guard | no acoustic echo cancellation (docs/KNOWN_LIMITATIONS.md) |
| Spoken replies in the reply's language (Kokoro, Apple fallback) | **Verified live** | mixed replies pick the voice per sentence language (`SpokenLanguage`) |
| Keyboard shortcut, menu bar, chat input, click-to-talk — also with the wake word off | Verified (unit: `ManualActivationTests`) + build | `WakeWordRuntime.activateManually()` |

## Understanding

| Capability | State | Evidence |
|---|---|---|
| Fillers, wake-word residue (incl. a heard tail of "Jarvis"), "no wait" corrections (EN/ES) | **Verified live** | "open... no, wait, open Notes instead" → Notes opened; `UtteranceNormalizerTests` |
| Deterministic fast path (time/date, open/close apps incl. Spanish names and articles, arithmetic, Friday timers, "remember that …", music/system, weather) | **Verified live** | corpus and acceptance table in docs/TEST_RESULTS.md |
| Keyword routing (bilingual) and Laya routing through the sidecar | **Verified live** | 75–130 ms per route |
| Planner: per-model tool budget, Spanish-aware tool search, function calling, batch rule, `friday.find_tools`, `friday.ask_user` round trip (free text, options), `maxToolRounds` | **Verified** | `NarrowingTests`, `EnginePipelineTests`, `PersonalDataGuardTests`, `LocalModelTests` (live Ollama) |
| Honest answers about the user's data (calendar, reminders, mail, files, screen…): tool required, invented answers never shown | **Verified live** | calendar question through the local model lists the real events; a tool-free "answer" is rejected and retried |
| Provider chain ChatGPT → API key → compatible → Apple on-device, typed bilingual errors, 404/offline fall through, a vanished local model replaced by one the server lists | Verified (unit) + live (Ollama model change) | `ProviderFallbackTests`, `ProviderErrorMappingTests` |
| Sign in with ChatGPT (dynamic client, PKCE, loopback, refresh, revoke, JWKS), compared with OpenAI's documentation | Implemented, **pending user** | cannot be exercised without the user's account; every failure path ends with a bilingual error |
| Local model auto-discovery (Ollama, LM Studio) | Verified (build) | Settings ▸ Intelligence ▸ Detect local servers; applied at launch when nothing is configured |
| Apple on-device model as offline fallback | **Verified live** | general questions answered when the local server is down |
| Context across turns, memory of facts | **Verified live** | "remember that my favourite editor is Xcode" → "what is my favourite editor?" → "Xcode" |

## Apple apps (136 tools from Apple-Integrations)

| Integration | State | Notes |
|---|---|---|
| Music (play/pause/next/volume/playlists/shuffle/repeat, fuzzy library matching, catalog) | **Verified live** (pause, playlist listing) + unit-tested | queue playlist now "Friday Queue" (a legacy "Jarvis Queue" is renamed once) |
| Reminders (create/list/update/complete/delete, lists, recurrence, batch) | **Verified live** (create with date) + unit-tested | sections/subtasks: **Unsupported** (EventKit) |
| Notes (create/search/read/append/update/folders/merge/backups) | Unit-tested; **pending user** (Automation prompt) | |
| Calendar (events, conflicts, free slots, recurrence, time zones) | **Verified live** (list, by voice and typed) + unit-tested | |
| Contacts | Unit-tested; off by default; **pending user** | |
| Mail (search/read/draft/reply/send with confirmation, delivery verified in Sent) / Messages | Unit-tested; **pending user** (Automation prompt) | Messages delivery unverifiable (docs/KNOWN_LIMITATIONS.md) |
| Clock alarms/timers via Shortcuts | **Unsupported until the user creates the Shortcuts** (guide in Settings ▸ Integrations); Friday's own timers verified, **pending user** (notification permission) | |
| Weather (Open-Meteo), maths, conversions, currency | **Verified live** (weather, arithmetic) | default location in Settings ▸ Integrations |
| System: volume, brightness, open/close apps, clipboard, settings panes, screenshot | **Verified live** (open/close) + unit-tested | |
| Files: search, metadata, read, move/copy/rename/trash, duplicates, organize, compress/extract, convert | Unit-tested; approved folders configured in Settings ▸ Integrations | |
| Browser tabs (Safari/Chrome tab reading) | Unit-tested; needs "Allow JavaScript from Apple Events" | |
| Rain-check condition agent (login item + launchd) | Built and packaged; **pending user** (enable + notifications) | `ConditionAgentPackagingTests` |

## New capabilities

| Capability | State | Evidence |
|---|---|---|
| Browser agent (`web.task`, status, connect, cancel, focus) through the sidecar, with Chrome reconnect/resume, uploads, drag and drop, bilingual approvals, CAPTCHA/sign-in handed to the user | **Verified live** (search, open page, extract a table into a card, tabs, compare, fill a form) | docs/TEST_RESULTS.md 21–28; Google's CAPTCHA correctly stopped the agent |
| Computer control: windows, displays, focus, arrange, UI tree, click, type, keys, menus, selected text | **Verified live** (AX capture, window list, menu bar) | 67 `FridayComputerTests`; mutating actions unit-tested only |
| Screen understanding: screenshot + OCR + AX description (AX-only without Screen Recording) | **Verified live** | `LiveScreenTests` |
| Dark mode / lock screen | Implemented, honest verification | not exercised live |
| Memory: preferences, entities, knowledge, conversations, tasks, routines, export to a file, retention, off switch | **Verified live** + 27 `FridayMemoryTests` | |
| Scheduled commands ("at 8 PM …", daily/weekdays/weekly) | Verified (unit); runs while Friday is open | |
| Routines (whole-phrase trigger match, run without a model) | Verified (unit) | |
| Local control channel (`fridayctl` incl. `--say`, `--voice`, `--synthesize`, `--transcript`) | **Verified live** | every live result in docs/TEST_RESULTS.md went through it |
| Settings: integrations capability setup (file roots, Shortcuts, SearXNG, weather default, Clock guide), permissions with refresh, provider status, local model detection, diagnostics | Verified (build) | |

## Not built

* Voice lesson UI ("teach Friday your voice") — the engine supports it (`VoiceTuner`, `friday-bench kws-tune`); the window was not ported.
* Automatic offer to save repeated workflows as routines — routines are saved on request only.
* Image input to the model for screen questions — text (AX + OCR) only.
* Whisper recognition through the sidecar is implemented server-side (`/api/stt/*`) but not registered as a recogniser in the app.
* Spotify, WhatsApp, Slack, Notion, Home Assistant … — not implemented and not claimed.
