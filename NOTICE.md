# Notices

Friday is © 2026 Alejandro Newport Diaz, MIT licence (see [LICENSE](LICENSE)). It incorporates and builds on:

* **Speech**, **Apple-Integrations**, **Jarvis** — the author's earlier projects, merged here (see docs/INTEGRATION_AUDIT.md).
* **sherpa-onnx** (Apache-2.0) and **ONNX Runtime** (MIT) — `Vendor/SherpaOnnx` (library, downloaded and verified by
  `Scripts/fetch-sherpa.sh`); the keyword-spotting model from the sherpa-onnx `kws-models` release.
  **Licensing note:** Friday vendors the *full* sherpa-onnx build (text-to-speech enabled), which links
  **espeak-ng** and **piper-phonemize** (GPL-3.0-or-later). Friday loads that library at runtime with `dlopen`; it is
  not modified. If you distribute Friday, review the GPL's terms for the bundled library, or re-pin
  `Vendor/SherpaOnnx/sherpa.lock` to the `-no-tts` build (Apache-2.0/MIT only) and use Apple voices for speech.
* **Kokoro-82M** (Apache-2.0, hexgrad) as exported by sherpa-onnx (`kokoro-multi-lang-v1_0`), with **espeak-ng data**
  (GPL-3.0-or-later; data files used unmodified for Spanish and other non-English phonemization) — `Vendor/Speech`.
* **Silero VAD** (MIT) — `Vendor/Speech/silero_vad.onnx`.
* **Laya** (Convai Innovations, Apache-2.0) and **laya-mlx** (Apache-2.0) — used by the sidecar; checkpoint
  `aac6fef/laya-typed-decisions-mlx` downloaded on demand.
* **jev-ultrafast**, **laya-ultrafast**, **browser-harness** (MIT, Browser Use) — the observed-action browser
  architecture and in-page runtime in `Sidecar/jarvis/page.js`, `policy.py`, `browser.py`, `chrome.py` (see `Sidecar/NOTICE`).
* **atticus-mac** (MIT, © 2026 SaarthurR) and **Plip** (MIT, © 2026 Hussain) — Accessibility, window, screenshot,
  permissions and overlay helpers adapted in `Sources/FridayComputer` (see `NOTICE-ATTICUS.md` for the exact pieces and
  the licence texts).
* FastAPI/Starlette/uvicorn (BSD), httpx (BSD), websockets (BSD), huggingface-hub (Apache-2.0), keyring (MIT),
  pydantic (MIT), MLX (MIT) — sidecar dependencies.

Apple frameworks (SpeechAnalyzer, AVFoundation, EventKit, ScreenCaptureKit, Vision, FoundationModels) are used under
the macOS SDK licence.
