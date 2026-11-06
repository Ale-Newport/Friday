# Known limitations

Each item names the technical cause. "Platform" means Apple exposes no supported way to do it.

## Voice

* **Spanish speech can trigger the wake-word detector** ("ya había" ≈ "Jarvis"): the free keyword model is bilingual
  Chinese/English and the level normaliser that makes quiet speech detectable also lets look-alikes through. Mid
  sensitivity is the measured compromise; the Speech project's voice lesson (Teach Friday your voice) reduces misses
  and false activations for your voice. A Spanish-specific keyword model does not exist in sherpa-onnx's releases.
* **Changing the wake word** needs a keyword spelling the model's phoneme set can express; "Jarvis" ships with four
  spellings. Other words work by editing the keyword file (Settings ▸ General explains); accuracy is not guaranteed.
* **Language identification is per utterance, not per word**: Apple's `SpeechTranscriber` is one locale per
  transcriber. Friday runs an English and a Spanish transcriber on the same audio and keeps the better hypothesis, so
  code-switched sentences come back mostly right from the dominant language's lane, but a single foreign word may be
  spelt phonetically. Whisper (optional, via the sidecar, `mlx-whisper`) is better at mixed sentences and worse at latency.
* **Barge-in** uses the microphone while Friday speaks through the speakers; with the built-in microphone and no echo
  cancellation, loud playback can look like speech. Friday requires sustained speech energy well above the floor; turn
  the feature off in Settings ▸ Voice if your setup misfires. Acoustic echo cancellation (voice-processing I/O) is not
  enabled because it changes the capture format the wake-word engine was calibrated on.
* **Kokoro Spanish** relies on espeak-ng phonemization (sherpa-onnx 1.13.8 is the last release bundling it); its
  Spanish voices (`ef_dora`, `em_alex`, `em_santa`) are fewer and slightly less natural than its English ones.
* **Apple voices** are only as good as the ones you downloaded (System Settings ▸ Accessibility ▸ Spoken Content);
  compact voices sound robotic.

## Intelligence

* **Laya routing is English-only** (no multilingual typed-decisions checkpoint exists). Spanish requests are routed by
  bilingual keyword rules; anything else goes to the planner with the full tool catalogue, which is correct but slower.
  Laya's `question` probability is not a reliable question detector; it is only used as a hint.
* **ChatGPT plan sharing** is OpenAI's preview flow: usage counts against your plan's shared cap, some accounts may be
  ineligible, and the Responses route rejects audio input, hosted tools and sampling parameters. Friday reports the
  documented error codes verbatim and never retries in a loop. Whether a given account is accepted can only be verified
  by signing in; the flow itself is the one OpenAI documents for open-source apps.
* **Image understanding** of screenshots is sent to the model only when the active provider accepts images (API key
  path); on the plan path Friday answers screen questions from Accessibility text and OCR.
* The deterministic fast path covers common music/system/timer/weather/calculation commands; everything else needs a
  model. Without any provider, Friday says so instead of guessing.

## Apple apps (platform)

* **Reminders sections and subtasks**: `EKReminder` exposes neither. The tools exist, accept the parameters and
  explain honestly that the reminder was *not* created in a section/as a subtask rather than silently flattening it.
* **Clock alarms and timers** have no scripting interface; Friday uses the user-created Shortcuts from the
  Apple-Integrations project (Settings ▸ Integrations ▸ Clock shows which exist and the steps to build the missing
  ones), and otherwise its own notification timers.
* **Notes rich text**: notes are written as simple HTML; attachments and locked notes are never rewritten.
* **Mail/Messages delivery** cannot be verified after sending; results say "sent (unverified)".
* **Music** goes through AppleScript (MusicKit's system player is unavailable on macOS); catalog metadata comes from the
  iTunes Search API.

## Computer control

* Accessibility works only for apps that expose their UI (most native apps, Electron apps with accessibility on; some
  games and custom-drawn views do not). Friday falls back to OCR for reading, never to blind coordinate clicking.
* No background input: Friday brings a window to the front before clicking or typing (private APIs that type into
  background windows were deliberately not reused from Atticus).

## Browser agent

* One task at a time (one Chrome connection). File uploads, drag and drop, cross-origin iframes and closed shadow DOM
  are not supported by the in-page runtime. CAPTCHAs and sign-ins are handed to you. Purchases always ask.
* The agent plans with the same model Friday uses; with a small local model it is slow (tens of seconds per plan).

## Background tasks

* Scheduled and conditional tasks run while Friday is running (it is a login item). The one separate launchd helper is
  the rain-check condition agent ported from Apple-Integrations: `Friday Condition Agent.app` is built by the
  `FridayConditionAgent` target and embedded in Friday.app (`Contents/Library/LoginItems`, with its launchd plist in
  `Contents/Library/LaunchAgents`). It is off until you enable it in Settings ▸ Integrations ▸ Future conditions, which
  registers it with `SMAppService` (macOS asks for approval under Login Items & Extensions) and lets you authorise its
  notifications; launchd then runs one bounded pass every 15 minutes, with Friday open or closed. It needs the app in a
  stable location (/Applications); sleep or offline periods delay checks, and expired jobs do not fire. Friday never
  claims any other task will run after it quits.

## Licensing

* The vendored sherpa-onnx library is the full build with text-to-speech, which links espeak-ng and piper-phonemize
  (GPL-3.0-or-later). The wake word alone works with the `-no-tts` build (Apache-2.0/MIT); Kokoro's Spanish output does
  not. See NOTICE.md before redistributing a bundle.

## Packaging

* The Debug app uses `Sidecar/.venv`; the Release app embeds a PyInstaller build (≈ 275 MB with MLX). The Laya
  checkpoint is downloaded on first use, not bundled.
* Ad-hoc signed builds lose macOS permissions on every rebuild; use `Config/Local.xcconfig` with a real identity.
