# Setup

## 1. Build

```bash
git clone … Friday && cd Friday
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

```bash
fridayctl "Add buy milk to my Shopping reminders list"      # from Friday.app/Contents/Helpers/fridayctl
fridayctl --tools | --status | --confirm TOKEN
```

## 6. Development

```bash
swift test                                   # package tests
swift test --filter RecognitionBenchmark     # speech-recognition benchmark (synthesised voices)
cd Sidecar && uv run pytest tests --ignore=tests/integration -q
cd Sidecar && uv run pytest tests/integration # real Chrome windows
Friday.app/Contents/MacOS/Friday --synthetic-audio   # no microphone needed
```
