# Setup

## 1. Build

```bash
git clone https://github.com/Ale-Newport/Friday.git && cd Friday
make bootstrap      # ≈ 1 GB of downloads the first time: sherpa-onnx library (17 MB), wake-word model (5 MB),
                    # Kokoro multilingual int8 (126 MB), Silero VAD (2 MB); `uv sync` for the sidecar; xcodegen
make run            # Debug build → build/DerivedData/Build/Products/Debug/Friday.app
```

The Laya checkpoint (≈ 810 MB) is downloaded by the sidecar on first use (Settings ▸ Browser shows progress) or by
`cd Sidecar && uv run python -c "from huggingface_hub import snapshot_download; snapshot_download('aac6fef/laya-typed-decisions-mlx')"`.

**Signing.** Builds are ad-hoc signed by default so a fresh clone builds. macOS then treats every rebuild as a new app
and asks for permissions again. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` with your team id and
identity (`security find-identity -v -p codesigning`) for a stable identity; you may also set
`ENABLE_HARDENED_RUNTIME = YES` there.

**Release.** `make package-sidecar && make release && make install` embeds the PyInstaller-built sidecar in
`Friday.app/Contents/Resources/backend` and copies the app to /Applications (needed for Open at Login).

## 2. First launch

1. macOS asks for the **Microphone**: allow it. The menu-bar icon shows a waveform while Friday listens.
2. Say **“Jarvis”** — a chime plays and the panel appears. Say something simple: “what time is it?”, “abre Notas”.
3. Open **Settings** (menu bar ▸ Settings… or ⌘,):
   * **Intelligence ▸ Continue with ChatGPT** — see below.
   * **Voice** — choose the English and Spanish voices (Kokoro voices appear when the models are installed) and test them.
   * **Browser** — start the sidecar and connect Chrome (Friday's own profile; sign in to sites there once).
4. The first command that touches an Apple app triggers that app's permission prompt (Automation, Reminders, Calendar,
   Contacts). Computer control asks for **Accessibility**; “what is on my screen?” asks for **Screen Recording**.

## 3. Connect your ChatGPT account

Friday implements OpenAI's documented *Sign in with ChatGPT* flow for open-source, locally hosted apps:

1. Settings ▸ Intelligence ▸ **Continue with ChatGPT**. Your browser opens `auth.openai.com`.
2. Sign in and approve the requested scopes, including **plan usage** (`chatgpt.tokens.use.direct`). The browser is
   redirected to `http://127.0.0.1:<port>/auth/callback`, a listener Friday opened just for this sign-in.
3. Friday exchanges the code (PKCE, no client secret), validates the ID token, stores the tokens in the macOS Keychain
   and lists the models your account offers. Pick one or leave “Automatic”.

Tokens are refreshed automatically (access tokens last an hour; the refresh token rotates and lasts 30 days). **Sign out**
revokes the refresh token at OpenAI and clears the Keychain entry. Friday never reads ChatGPT's cookies or your ChatGPT
conversations. If plan usage was not granted, or your plan's shared usage limit is reached, Friday says so and falls
back to the next enabled provider (API key only if you enabled it, a local server, Apple's on-device model).

Alternatives: an **OpenAI API key** (metered; off by default, stored in the Keychain), an **OpenAI-compatible server**
(Ollama `http://localhost:11434/v1`, LM Studio `http://127.0.0.1:1234/v1`), and **Apple's on-device model** (free,
offline, small).

## 4. Microphone and macOS permissions

See [PERMISSIONS.md](PERMISSIONS.md). Everything is requested on first use with an explanation; nothing is required
up front except the microphone for voice.

## 5. Command line

`fridayctl` lives in `Friday.app/Contents/Helpers/` and talks to the running app over its local socket:

```bash
fridayctl "Add buy milk to my Shopping reminders list"      # through the Action Engine (same as a typed command)
fridayctl --say "¿qué tengo en el calendario mañana?"       # through the assistant (transcript, memory; --speak to hear it)
fridayctl --tools | --status | --transcript 20 | --confirm TOKEN | --cancel TOKEN | --choose TOKEN INDEX
fridayctl --synthesize "Jarvis, abre Notas" --output /tmp/abre.wav --language es   # Friday's own voice, no playback
fridayctl --voice /tmp/abre.wav                              # play the file into the microphone pipeline as if spoken
```

`--status` includes a `voice` section (wake-word state, microphone authorisation, input device, assistant phase).
`--voice` is how the whole voice path is tested without a person: the file replaces the microphone samples for its
duration (wake word included), and the reply lists whether the wake word fired, what was heard, the phases and the
latencies. `Scripts/voice-e2e.sh` runs a bilingual corpus this way; `Scripts/acceptance.sh` runs typed scenarios.

## 6. Development

```bash
swift test                                   # package tests (the XCTest suites cannot be --filter'ed; Swift Testing ones can)
swift test --filter RecognitionBenchmark     # speech-recognition benchmark (synthesised voices)
swift test --filter LocalModelTests          # live planner/provider checks against an Ollama server, skipped when none runs
cd Sidecar && uv run pytest tests --ignore=tests/integration -q
cd Sidecar && uv run pytest tests/integration # real Chrome windows
Friday.app/Contents/MacOS/Friday --synthetic-audio   # no microphone needed
Scripts/voice-e2e.sh                         # wake word → recognition → planner → reply, from synthesised audio
Scripts/acceptance.sh > results.md           # typed acceptance scenarios as a Markdown table
Scripts/link-worktree-assets.sh              # in a git worktree: link the vendored libraries/models/venv from the main checkout
```

The Makefile's `app` target hides compiler errors behind `tail -5`; when a build fails run `xcodebuild -project
Friday.xcodeproj -scheme Friday -configuration Debug -derivedDataPath build/DerivedData build | grep error:`.

### Local models

With an OpenAI-compatible server enabled (Settings ▸ Intelligence), Friday detects Ollama behind the endpoint and
drives it through Ollama's native API with an explicit 16k-token context window: through `/v1` Ollama silently
truncates prompts that exceed the model's default window, which turned planning requests into empty answers. Models
are sized by the planner: a local server gets ≤ 20 relevant tool schemas per call (plus `friday.find_tools` to load
more), short observations and three conversation turns; a hosted model gets up to 64 tools. Answers about your own
data (calendar, reminders, mail, files…) are only accepted when the model read them through a tool; a small model
that "answers" without reading is asked once more with a tool call required, and otherwise Friday says it could not.
