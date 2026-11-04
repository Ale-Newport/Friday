# Friday — a voice assistant for your Mac

Friday is a native macOS assistant. Say **“Jarvis”** (the wake word; the app is Friday) and speak naturally — in
Spanish, English or both — and Friday answers, controls your Mac and its apps, browses in Chrome, works with your
files, remembers what matters and comes back with a short spoken reply. Everything that can be said can also be typed.

It merges three earlier projects into one application and adds the missing pieces:

| From | What Friday keeps |
|---|---|
| **Speech** | Local wake-word detection (sherpa-onnx, no key, no network), the microphone pipeline, device/sleep handling, the HUD. |
| **Apple-Integrations** | The Action Engine and its **136 typed tools** for Music, Reminders, Notes, Calendar, Contacts, Mail, Messages, Clock, files, weather, maths, system controls — every action validated, permission-checked and verified. |
| **Jarvis** | The autonomous **Chrome agent** (DevTools Protocol + Laya typed decisions) as a local sidecar. |

New in Friday: on-device speech recognition (Apple `SpeechAnalyzer`), Kokoro text-to-speech, voice sessions with
follow-ups and interruptions, **Sign in with ChatGPT** (official OAuth flow, Responses API) with API-key / local /
Apple on-device fallbacks, Laya intent routing, a planner with tool discovery, persistent memory and routines,
Accessibility-based computer control and screen understanding, and one assistant for voice and chat.

```
"Jarvis."  →  "Yes?"  →  "Open Chrome, find the cheapest direct flight from London to Barcelona next Friday,
                           compare a few options, and save the best one in a note."
```

## Requirements

* macOS 26 or newer on Apple Silicon (built and tested on macOS 27.0.1, M2 Max). The deployment target is 14, but
  voice needs the macOS 26 speech APIs and the browser agent needs MLX.
* Xcode 27 (Swift 6.4, macOS 27 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen), [uv](https://docs.astral.sh/uv/).
* Google Chrome for the browser agent (optional).
* A model: your ChatGPT account (Plus/Pro/…), an OpenAI API key, an OpenAI-compatible server (Ollama, LM Studio), or
  nothing — Apple's on-device model and the deterministic parser still handle common commands.

## Quick start

```bash
make bootstrap     # fetch the speech library + models (checksum-verified), set up the Python sidecar, generate Friday.xcodeproj
make test          # Swift package tests (no microphone, key or network needed)
make run           # build and launch Friday.app (Debug)
```

Then: allow the **Microphone**; say “Jarvis”; open **Settings ▸ Intelligence ▸ Continue with ChatGPT** to connect your
account. See [docs/SETUP.md](docs/SETUP.md) for every step, [docs/PERMISSIONS.md](docs/PERMISSIONS.md) for what each
permission is for, and [docs/CAPABILITY_MATRIX.md](docs/CAPABILITY_MATRIX.md) for what is verified to work.

## Layout

```
App/            SwiftUI app: menu bar, assistant panel, chat, settings, diagnostics (composition root in App/Composition)
Sources/        FridayKit — see ARCHITECTURE.md for the module map
Sidecar/        Python browser agent + Laya (from Jarvis) with Friday's routing and Responses-API additions
Tests/          Swift tests; Sidecar/tests for Python
Scripts/        fetch-sherpa.sh, fetch-speech-models.sh, embed-engine-files.sh, package-sidecar.sh, generate-icon.swift
Vendor/         pinned native library + models (git-ignored contents, lock files committed)
docs/           INTEGRATION_AUDIT, CAPABILITY_MATRIX, SETUP, PERMISSIONS, TEST_RESULTS, PERFORMANCE, KNOWN_LIMITATIONS
```

## Licences

Friday's own code: MIT. Reused work keeps its licence and attribution — see [NOTICE.md](NOTICE.md) (sherpa-onnx,
ONNX Runtime, Kokoro, Silero, Laya, laya-mlx, jev-ultrafast / laya-ultrafast / browser-harness, atticus-mac, Plip).
