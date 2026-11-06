# Friday sidecar (Python)

The Python half of Friday: a loopback HTTP + WebSocket server that the native macOS app spawns as a direct child. It owns
the **Laya** typed-decision model (voice-command routing and generic typed decisions), the **Chrome** DevTools automation
agent with its LLM planner, and optional on-device **speech-to-text**.

It is a copy of the original Jarvis backend (MIT; see [`Sidecar/NOTICE`](NOTICE) for the Browser Use attribution and the
licence text of the code derived from jev-ultrafast / laya-ultrafast), adapted for Friday. The Python package is still called `jarvis` and the original console script `jarvis-backend` still works; the
new name is `friday-sidecar`. The full API contract is in [docs/API.md](docs/API.md).

## Run it

```bash
cd Sidecar
uv sync                        # creates .venv (Python ≥ 3.12, Apple Silicon for MLX)
uv sync --extra whisper        # optional: adds mlx-whisper for /api/stt/*
FRIDAY_TOKEN=test uv run friday-sidecar
# stdout: {"event": "ready", "port": 54321, "version": "0.1.0", "pid": 12345}
curl -s -H 'Authorization: Bearer test' -H 'Content-Type: application/json' \
     -d '{"text": "recuérdame comprar leche mañana"}' http://127.0.0.1:54321/api/route
```

Environment: `FRIDAY_TOKEN`, `FRIDAY_DATA_DIR` (default `~/Library/Application Support/Friday/sidecar`),
`FRIDAY_DOWNLOADS_DIR` (default `~/Downloads/Friday`), `FRIDAY_PORT` (default `0` = free port), `FRIDAY_LOG` (`INFO`),
`FRIDAY_PARENT_PID`. Each one is also accepted with the original `JARVIS_` prefix (the `FRIDAY_` value wins).

The host must be the **direct parent** of the process: the watchdog exits when `getppid()` changes or when the declared
parent pid no longer exists. Shut it down with `POST /api/shutdown`.

Tests (no Chrome needed; tests marked `laya` load the real checkpoint when it is cached and are skipped otherwise):

```bash
uv run pytest tests --ignore=tests/integration -q
uv run ruff check jarvis tests
uv run pytest tests/integration   # original Chrome + Laya integration suite (opens real Chrome windows)
```

## What changed from the Jarvis backend

* **Branding and defaults.** Project renamed to `friday-sidecar` (`pyproject.toml`), console script alias
  `friday-sidecar`, data dir `~/Library/Application Support/Friday/sidecar`, downloads `~/Downloads/Friday`, Keychain service
  `com.alejandro.friday.sidecar`. Log file name unchanged (`logs/jarvis.log`). Environment variables accept both the
  `FRIDAY_` and the `JARVIS_` prefix (`jarvis/server.py::env`). The ready line format is unchanged.
* **Parent watchdog honours `FRIDAY_PARENT_PID`** in addition to the `getppid()` check (`server.py::parent_gone`).
* **Laya routing** (`jarvis/routing.py`): `POST /api/route` classifies a voice request into ≤ 10 categories (default list
  from `GET /api/route/categories`) and answers three extra `noul` questions (`multistep`, `dangerous`, `question`) in the
  same `system_one` call. A bilingual keyword pre-pass (English/Spanish) answers obvious requests without the model
  (`source: "rules"`, confidence 0.9); when Laya is not available and no rule matches the result is `category: "unknown"`,
  `source: "none"` so the app can fall back to its LLM. `POST /api/laya/decide` exposes raw typed decisions
  (`system_one` with optional `min_confidence`). `LayaUnavailable` is mapped to `503 laya_unavailable`.
  `LayaEngine.system_one` now forwards `min_confidence`, and the route question shape is warmed at startup.
* **LLM: OpenAI Responses API** (`jarvis/llm.py`): `LlmConfig.api` / setting `llm.api` = `chat` (unchanged default) or
  `responses` (`POST {base_url}/responses`, streamed SSE, `store: false`, system prompt as `instructions`, JSON schema via
  `text.format`, provider error codes kept on `LlmError.code`). `GET /models` replies in the ChatGPT shape
  (`{"models":[{"slug","visibility"}]}`) are understood. `PUT`/`DELETE /api/llm/session` set/clear an in-memory
  base URL / model / API / token override that never touches the settings DB or the Keychain.
* **Speech-to-text** (`jarvis/stt.py`, optional extra `whisper`): `POST /api/stt/transcribe` takes raw float32 16 kHz mono
  PCM and returns text + segments; `GET /api/stt/status`, `POST /api/stt/download` (progress events `stt.download`).
  Runs on the Laya worker thread (the one MLX thread). `501 stt_unavailable` without mlx-whisper, `409 stt_model_missing`
  until the checkpoint is cached.
* Everything else (Chrome automation, conversations/tasks, events, settings, secrets, onboarding) is unchanged. The
  PyInstaller spec and `scripts/` are the original ones and have not been re-validated for Friday's packaging.

## Layout

```
jarvis/            the package (server.py entry point, app.py state, routing.py, stt.py, llm.py, laya_engine.py, browser/CDP, planner, tools, …)
tests/             unit tests (fast, no Chrome) + tests/integration (real Chrome + Laya) + tests/live (real websites, --live)
docs/API.md        the HTTP/WebSocket contract
scripts/           benchmark / eval helpers from the original project
```
