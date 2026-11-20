# Changelog

All notable changes to Friday are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] — 2026-11-19

### Added
- **Downloadable app** for Apple Silicon on every release, built by the public Release workflow: ad-hoc signed (not
  notarized — see [docs/INSTALL.md](docs/INSTALL.md)), with the packaged browser sidecar and speech models, a SHA-256,
  a build-provenance attestation, every third-party notice, and the corresponding source of the GPL/LGPL components.
  Closes #6 as far as possible without a paid Developer ID.
- Unit conversion: yards, nautical miles, knots, stone, tonnes, milligrams, centi/decilitres, cubic metres, US and
  imperial gallons, pints and fluid ounces, quarts, cups, tablespoons, teaspoons, area (m², km², ft², hectares, acres…)
  and fuel economy (km/l, mpg), in English and Spanish; multi-word unit names. (#4)

### Fixed
- An English voice command could be answered in Spanish when the recognizer's Spanish lane won; the words now decide
  the reply language. (#3)
- Apps are named in the reply's language ("Abrí Calculadora", "Opened Calculator") whatever the system language. (#2)
- Conversion answers are rounded for speech ("42.16 kilometers") and grouped ("20.000 metros cuadrados"). (#1)
- Spanish conversions ("convierte 3 tazas en mililitros") now take the instant deterministic path instead of the model.
- Closing an app right after opening it no longer fails; closing an app that isn't running says so.
- The test suite no longer deadlocks or starves on machines with few cores: blocking test helpers moved off Swift's
  cooperative thread pool, the architecture-boundary tests parse each file once (6 minutes → 1 second), and CI runs the
  functional suites in parallel and the wall-clock-timing suites on their own. (#8)
- Removing the recognition-vocabulary provider while it was still answering could bring its words back.

### Changed
- `NOTICE.md` lists the CC BY-NC-SA 4.0 Spanish Piper voice and the LGPL-3.0 edge-tts library.

## [0.1.0] — 2026-11-19

First public release: Speech, Apple-Integrations and Jarvis merged into one native macOS assistant.

### Added
- **Voice:** local "Jarvis" wake word (sherpa-onnx, no key, no network), on-device bilingual speech recognition
  (Apple `SpeechAnalyzer`) with a dynamic vocabulary of app, playlist and contact names, follow-ups without the wake
  word, barge-in, and silent stop ("para", "cállate", "stop").
- **"Train “Jarvis”" lesson** that learns your own ways of saying the wake word and checks them over babble, music and
  noise before installing them.
- **Natural spoken replies** that start while the answer is still being written: online neural voices through the
  sidecar, with offline Piper (Spanish), Kokoro and Apple voices as fallbacks.
- **136 typed Mac actions** (Music, Reminders, Notes, Calendar, Contacts, Mail, Messages, Clock, files, weather,
  maths, system controls), each validated, permission-checked and verified; approval prompts for anything that sends,
  deletes or publishes.
- **Autonomous Chrome agent** (DevTools Protocol + Laya typed decisions) in a loopback-only, token-authenticated
  Python sidecar, with approvals for downloads and uploads.
- **Models:** Sign in with ChatGPT (OAuth + Responses API), OpenAI API key, OpenAI-compatible local servers (Ollama,
  LM Studio) and Apple's on-device model, with real fallback between them; a planner with tool discovery and an
  `ask_user` round trip.
- Persistent memory and routines (SQLite), Accessibility-based computer control and screen understanding.
- `fridayctl` command-line control, including `--voice` (play a recording into the microphone pipeline) and
  `--synthesize`; `Scripts/voice-e2e.sh` bilingual end-to-end voice corpus.
- Repository: CI (Swift, Python sidecar, shellcheck, gitleaks), CodeQL, Dependabot, dependency review, security
  policy, contribution guide, issue and PR templates, CODEOWNERS and owner-approved branch rulesets.

### Security
- Sidecar dependencies upgraded: certifi 2026.10.23 (compromised emSign roots removed), filelock 4.2.12,
  opentelemetry-api 1.45.2, setuptools 84.2.1, pytest 9.2.0.

### Fixed
- Arithmetic with grouped numbers: "what's 18% of 2,450?" answered 0.441 because the English thousands separator was
  read as a decimal comma. Digit grouping now follows the command's language ("2,450" in English, "2.450" in Spanish).
- Unit conversion understands spoken unit names in English and Spanish ("convert 26.2 miles to kilometers",
  "convierte 5 kilómetros a millas"); it used to accept only symbols such as `km` and `mi`.
- Speech made with macOS `say` is cached only when it decodes to real audio; the old byte-size check let
  near-empty files (the speech service unreachable) through because `afconvert` pads the header.
- The Swift package builds with Swift 6.3 / Xcode 26 as well as Xcode 27: two locals that shadowed a method
  or a property inside their own scope were renamed, and the macOS 27-only throwing tap API is used only
  when the macOS 27 SDK is present.
- Test suite: runs on 3-core machines (CI uses `--no-parallel` until the semaphore-based test helpers are
  made asynchronous, #8); desktop, Keychain, system-voice and hardware-counter tests are skipped on headless
  CI (`FRIDAY_HEADLESS_CI`).
- The browser agent recognises image searches and provider hosts by exact hostname, so look-alike hosts such as
  `notbing.com` or `google.evil.com` are no longer treated as Bing or Google (found by CodeQL).
- `Scripts/fetch-speech-models.sh` can no longer turn an empty argument into `rm -rf` of the whole vendor directory.
- `Scripts/link-worktree-assets.sh` finds the main checkout with `git worktree list` instead of a hard-coded path.

[Unreleased]: https://github.com/Ale-Newport/Friday/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Ale-Newport/Friday/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Ale-Newport/Friday/releases/tag/v0.1.0
