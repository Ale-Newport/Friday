# Changelog

All notable changes to Friday are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

### Fixed
- Arithmetic with grouped numbers: "what's 18% of 2,450?" answered 0.441 because the English thousands separator was
  read as a decimal comma. Digit grouping now follows the command's language ("2,450" in English, "2.450" in Spanish).
- `Scripts/fetch-speech-models.sh` can no longer turn an empty argument into `rm -rf` of the whole vendor directory.
- `Scripts/link-worktree-assets.sh` finds the main checkout with `git worktree list` instead of a hard-coded path.

[Unreleased]: https://github.com/Ale-Newport/Friday/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Ale-Newport/Friday/releases/tag/v0.1.0
