# Friday sidecar local API contract (v1)

The Python sidecar (`Sidecar/jarvis`, package name kept as `jarvis`) is a child process owned by the native Friday app.
Friday talks to it over HTTP + one WebSocket on the loopback interface. This document is the contract between the two.
If code and this file disagree, fix the code or fix this file in the same change.

Everything below the "Friday additions" heading is new relative to the original Jarvis backend; everything above it is the
original contract, kept unchanged apart from names and defaults.

## Process lifecycle and authentication

* Friday generates a random 256-bit token (hex) per launch and starts the sidecar **as its direct parent process** with
  `FRIDAY_TOKEN=<token>` in the environment. Every variable is read with the `FRIDAY_` prefix first and the original
  `JARVIS_` prefix second (first non-empty value wins):

  | Variable | Meaning | Default |
  | --- | --- | --- |
  | `FRIDAY_TOKEN` / `JARVIS_TOKEN` | bearer token | generated and printed to stderr as `FRIDAY_TOKEN=<hex>` (standalone use only) |
  | `FRIDAY_DATA_DIR` / `JARVIS_DATA_DIR` | SQLite DB, Chrome profile, logs | `~/Library/Application Support/Friday/sidecar` |
  | `FRIDAY_DOWNLOADS_DIR` / `JARVIS_DOWNLOADS_DIR` | files saved by the `download` tool | `~/Downloads/Friday` |
  | `FRIDAY_PORT` / `JARVIS_PORT` | listening port | `0` = pick a free port |
  | `FRIDAY_LOG` / `JARVIS_LOG` | log level | `INFO` (`DEBUG` prints every Laya question/answer) |
  | `FRIDAY_PARENT_PID` / `JARVIS_PARENT_PID` | pid of the host app | unset |
  | `JARVIS_CHROME_FLAGS` | extra Chrome argv (e.g. `--headless=new`) | unset |

* The sidecar binds **127.0.0.1 only**. When it is listening it prints exactly one JSON line to **stdout**:
  `{"event": "ready", "port": 53211, "version": "0.1.0", "pid": 1234}`; all logs go to stderr and to
  `<data dir>/logs/jarvis.log`. Nothing else is ever written to stdout.
* Every HTTP request except `GET /health` carries `Authorization: Bearer <token>`.
* The WebSocket (`/api/events`) is authenticated with a subprotocol: the client offers `["jarvis.v1", "bearer." + token]`;
  the server accepts `jarvis.v1`.
* Requests whose `Host` is not `127.0.0.1:<port>` / `localhost:<port>` / `[::1]:<port>` are rejected (`403 bad_host`). The
  `Origin` header is only checked when present (a native `URLSession` client never sends one); allowed values are
  `tauri://localhost`, `http://tauri.localhost`, `https://tauri.localhost`, `http://localhost:1420`, `http://127.0.0.1:1420`.
* On quit, send `POST /api/shutdown` (graceful: cancels the task, closes managed Chrome per setting, flushes the DB),
  wait ≤ 5 s, then SIGTERM, then SIGKILL. The sidecar also exits by itself, within ~2 s, when its parent goes away: it
  watches both `getppid()` (re-parenting) **and** the pid declared in `FRIDAY_PARENT_PID` (when that pid no longer exists).

Errors are JSON `{"error": {"code": "string", "message": "human readable", "reason"?: "string"}}` with an HTTP status ≥ 400
(`reason` is a finer stable cause when one exists, e.g. a Chrome error code). Besides the
per-endpoint codes, the middleware maps `BrowserNotConnected` → `409 chrome_not_connected` (with `reason`), `LlmError` → `502 llm_error`,
`LayaUnavailable` → `503 laya_unavailable`, `SttUnavailable` → `501 stt_unavailable`, `SttModelMissing` → `409 stt_model_missing`.

## System, onboarding, settings

| Method | Path | Body → Response |
| --- | --- | --- |
| GET | `/health` | → `{"status":"ready","version":"0.1.0"}` (no auth) |
| GET | `/api/status` | → `SystemStatus` |
| POST | `/api/onboarding/check` | → `{"checks": Check[], "ready": bool}` (re-runs all checks) |
| GET | `/api/settings` | → `Settings` |
| PUT | `/api/settings` | partial `Settings` (deep-merged) → `Settings`; `400 invalid_setting` |
| PUT | `/api/secrets/{name}` | `{"value": "..."}` → `{"name","set":true}`; names: `llm_api_key` (macOS Keychain service `com.alejandro.friday.sidecar`, never returned) |
| DELETE | `/api/secrets/{name}` | → `{"name","set":false}` |
| POST | `/api/shutdown` | → `{"ok":true}` (exits ~0.2 s later) |

```ts
type Check = {
  id: "apple_silicon" | "macos" | "chrome" | "python" | "laya_model" | "text_model" | "chrome_connection";
  title: string;
  status: "ok" | "warn" | "error" | "pending";
  detail: string;
  action?: { id: string; label: string };
};
type SystemStatus = {
  version: string;
  arch: "arm64" | "x86_64";
  macos: string;
  mlx_supported: boolean;
  chrome: ChromeStatus;
  laya: LayaStatus;
  llm: LlmStatus;
  busy_task_id: string | null;
};
type Settings = {
  appearance: "system" | "light" | "dark";
  chrome: {
    mode: "managed" | "existing";
    path: string | null;                 // null = auto-detect
    keep_open_on_quit: boolean;          // managed mode only (default false)
    existing_debug_port: number | null;  // optional hint, e.g. 9222
  };
  llm: {
    provider: "ollama" | "lmstudio" | "openrouter" | "openai" | "custom";
    base_url: string;                    // e.g. http://127.0.0.1:11434/v1
    model: string;
    api_key_set: boolean;                // secret itself lives in the Keychain
    json_mode: "auto" | "on" | "off";
    reasoning: "default" | "off";
    api: "chat" | "responses";           // NEW: chat/completions (default) or OpenAI Responses API
  };
  laya: { model: string };               // default "aac6fef/laya-typed-decisions-mlx"
  agent: {
    max_steps: number;                   // default 60
    max_minutes: number;                 // default 10
    confirm_sensitive: boolean;          // default true
    allow_local_urls: boolean;           // default false
    screenshots: "off" | "on_demand" | "per_step";
    upload_folders: string[];            // NEW: folders (besides the downloads folder) the upload tool may read; default []
  };
};
```

## Chrome

```ts
type ChromeStatus = {
  installed: boolean;
  path: string | null;
  version: string | null;
  mode: "managed" | "existing";
  state: "disconnected" | "connecting" | "awaiting_permission" | "connected" | "error";
  debugging: "unknown" | "off" | "on";
  how_to_enable?: string | null;
  profile_dir?: string | null;
  tabs: { id: string; title: string; url: string; active: boolean }[];
  error?: string | null;
  error_code?: string | null;          // NEW: stable cause of `error` (see "Error codes")
  reconnects: number;                  // NEW: connections re-established after a drop since the sidecar started
};
```

| Method | Path | Body → Response |
| --- | --- | --- |
| GET | `/api/chrome/status` | → `ChromeStatus` |
| POST | `/api/chrome/connect` | `{"mode"?: "managed"|"existing"}` → `ChromeStatus` (long poll ≤ 60 s) |
| POST | `/api/chrome/disconnect` | → `ChromeStatus` |
| POST | `/api/chrome/reset-profile` | `{"confirm": true}` → `ChromeStatus` |
| POST | `/api/chrome/focus` | → `ChromeStatus` |
| PUT | `/api/chrome/path` | `{"path": "/Applications/Google Chrome.app"}` → `ChromeStatus` |

## Laya (local decision model) and the text model

```ts
type LayaStatus = {
  model: string;
  downloaded: boolean;
  size_bytes: number | null;
  state: "missing" | "idle" | "downloading" | "loading" | "ready" | "unsupported" | "error";
  load_ms?: number | null;
  warm_ms?: number | null;
  error?: string | null;
};
type LlmStatus = {
  provider: string; base_url: string; model: string;
  api: "chat" | "responses";        // NEW
  remote: boolean;
  reachable: boolean;
  model_available: boolean;
  models: string[];
  error?: string | null;
  disclosure: string[];
  session: boolean;                 // NEW: true while PUT /api/llm/session is in force
  api_key_set: boolean;             // NEW: a key/token is configured (the value is never returned)
};
```

| Method | Path | Body → Response |
| --- | --- | --- |
| GET | `/api/laya/status` | → `LayaStatus` |
| POST | `/api/laya/download` | → `LayaStatus` immediately; progress arrives as `laya.download` events |
| POST | `/api/laya/load` | → `LayaStatus` (loads + warms; call once after the ready line and wait for `state == "ready"` before routing) |
| GET | `/api/llm/status` | → `LlmStatus` |
| GET | `/api/llm/detect` | → `{"candidates":[{"provider","base_url","models":[...],"reachable":true}]}` |
| POST | `/api/llm/test` | → `{"ok":bool,"latency_ms":n,"error"?:str}` |
| POST | `/api/llm/pull` | `{"model":"qwen3:8b"}` → `{"ok":true}`; Ollama only; progress as `llm.pull` events |
| POST | `/api/ollama/start` | → `{"ok":bool}` |

## Conversations, messages, tasks

Unchanged from the original contract: `GET/POST /api/conversations`, `GET/PATCH/DELETE /api/conversations/{id}`,
`POST /api/conversations/{id}/clear`, `POST /api/conversations/{id}/messages` (`{"text", "language"?: "en"|"es"}` →
`{"message","task"}`, starts a browser task; `409 task_running` while one runs; `400 bad_language` for any other language;
the language sticks to the conversation until a later message sets another one), `GET /api/tasks?limit=30`,
`GET /api/tasks/{id}`, `POST /api/tasks/{id}/pause|resume|cancel|retry|confirm`, `GET /api/tasks/{id}/screenshot`,
`POST /api/open-path`.

```ts
type Task = {
  id: string; conversation_id: string; message_id: string; goal: string;
  status: "queued" | "running" | "paused" | "waiting_user" | "done" | "partial" | "failed" | "cancelled";
  started_at: string | null; finished_at: string | null; elapsed_ms: number;
  steps: Step[];
  current: { title: string; url: string | null; page_title: string | null } | null;
  waiting: Waiting | null;
  error: string | null;
  error_code: string | null;             // NEW: a stable reason for `error` (see "Error codes" below)
  timings: Timings | null;
  parent_task_id: string | null;
  language: "en" | "es";                 // NEW: the language of the request (answers and sidecar-written texts use it)
  reconnects: number;                    // NEW: Chrome recoveries performed during the task (reconnect / reopened tab)
  notices: string[];                     // NEW: user-facing notes, e.g. "Resumed after Chrome reconnected." (in `language`)
};
// `waiting` carries the same structured facts as the matching confirm.request / needs_user event, so a client that
// missed the event (its socket dropped) can show the prompt from a GET /api/tasks/{id} snapshot.
type Waiting =
  | { kind: "confirm"; confirm_kind: ConfirmKind; message: string; confirmation_id: string; detail: string; language: "en" | "es";
      label?: string; host?: string; url?: string; title?: string;              // sensitive clicks
      name?: string; folder?: string; path?: string; size?: number; field?: string }  // download / upload
  | { kind: "captcha" | "login" | "manual"; message: string; url: string; wait_id: string; language: "en" | "es"; host: string };
type ConfirmKind = "payment" | "purchase" | "destructive" | "account" | "send" | "download" | "upload" | "sensitive";
type Step = {
  id: string; index: number;
  kind: "navigate" | "search" | "click" | "type" | "select" | "scroll" | "read" | "extract" | "plan" | "wait"
      | "tab" | "download" | "upload" | "drag" | "verify" | "key" | "back" | "forward";
  title: string; detail?: string; url?: string;
  status: "running" | "ok" | "error" | "skipped";
  started_at: string; elapsed_ms: number | null; error?: string | null;
};
type Timings = { total_ms: number; planning_ms: number; laya_ms: number; browser_ms: number; page_load_ms: number; llm_calls: number; laya_calls: number; browser_ops: number };
type Message = { id: string; conversation_id: string; role: "user" | "assistant" | "system"; text: string; cards: Card[]; task_id: string | null; created_at: string };
type Conversation = { id: string; title: string; created_at: string; updated_at: string; last_task_status?: string };
```

## WebSocket events: `GET /api/events` (upgrade)

```ts
type Event = { seq: number; ts: string; type: string; conversation_id?: string; task_id?: string; data: any };
```

On connect the server sends `{"type":"hello","data":{"seq":N}}` (its `ts` is empty). No replay: re-fetch REST state on
reconnect. Types: `task.created`, `task.status`, `step.started`, `step.finished`, `page.updated`, `assistant.delta`,
`assistant.message`, `confirm.request`, `needs_user`, `task.timings`, `chrome.status`, `laya.status`, `laya.download`
(`{bytes, total, file, done}`), `llm.pull`, and the new `stt.status` (`SttStatus`) and `stt.download`
(`{model, bytes, total, file, done}`).

Event payloads changed for Friday (all additive):

* `task.status` data: `{status, waiting, error, error_code, current, started_at, elapsed_ms, language, reconnects, notice}`.
  `notice` is set on the status emitted right after a Chrome recovery ("Resumed after Chrome reconnected.", in the task's
  language) and `null` otherwise.
* `confirm.request` data: `{confirmation_id, kind: ConfirmKind, question, detail, language, ...facts}` where the facts are
  the same optional fields as `Waiting` (`label`/`host`/`url`/`title` for a click, `name`/`folder`/`url`/`host` for a
  download, `name`/`path`/`size`/`host`/`url`/`field` for an upload). `question`/`detail` are the fallback copy (English or
  Spanish by `language`, naming Friday); the host app phrases its own prompt from the facts.
* `needs_user` data: `{kind: "captcha"|"login"|"manual", message, url, wait_id, language, host}`. `message` only describes
  the obstacle ("This page shows a CAPTCHA."); the instruction (how to resume) is the host's. `wait_id` is new for every
  prompt: a challenge that is still there after the user tried is asked again with the same `message` and a fresh id, so
  clients must not de-duplicate prompts by their text.
* `chrome.status` (= `ChromeStatus`) gained `error_code` and `reconnects`.

### Error codes

`ChromeStatus.error_code`, `Task.error_code` and the `reason` field of a `409 chrome_not_connected` error body carry a stable
cause so the host app can localise it instead of echoing the message:

| code | meaning |
| --- | --- |
| `chrome_not_found` | no Google Chrome installed (or the chosen path is not one: `not_chrome`) |
| `profile_in_use` | Friday's automation profile is open in a Chrome window Friday did not start |
| `chrome_exited` | Chrome quit right after launching |
| `devtools_timeout` | Chrome did not open its DevTools port in time |
| `chrome_not_running` | existing mode: Chrome is not running |
| `remote_debugging_off` | existing mode: remote debugging is not enabled / not listening |
| `chrome_disconnected` | the DevTools connection dropped (and, for a task, could not be re-established) |
| `chrome_not_connected` | any other connection failure |
| task-only: `llm_error`, `laya_unavailable`, `budget_exceeded`, `unexpected` | the text model, Laya, the time/action budget, a bug |

### Chrome recovery during a task

When the DevTools connection drops mid-task (Chrome quit or crashed, the socket closed) or the task's tab was closed, the
runner recovers instead of failing: it forgets the dead connection, connects again (managed mode relaunches Chrome when it
died; existing mode waits for the user's permission sheet again), reopens the last page in a new tab and re-runs the
interrupted step. The timeline shows a `tab` step ("Chrome disconnected — reconnecting…"), the next `task.status` carries
the `notice`, and `Task.reconnects` / `Task.notices` keep the count. At most three recoveries per task; after that the task
fails with `error_code: "chrome_disconnected"`.

### Uploads and drag & drop

Two planner tools were added. `upload {file, target?}` attaches a local file to an `<input type=file>` on the current page
through `DOM.setFileInputFiles` (hidden inputs included), after a `confirm.request` of kind `upload`. Only files inside the
approved folders can be chosen: the downloads folder (`FRIDAY_DOWNLOADS_DIR`) plus `Settings.agent.upload_folders`
(absolute paths, `~` allowed, at most 20). `file` is an absolute path inside those folders or a file name searched there
(case-insensitively; symlinks that lead outside are refused); files over 200 MB are refused. The field is read back after
the call and the step fails when it does not hold the file. `drag {item, target}` drags a visible item (list entries,
cards, rows, `[draggable]` elements) onto another item or a drop zone, delivering a native HTML5 drag through
`Input.setInterceptDrags` / `Input.dispatchDragEvent` when the page starts one and a plain pointer drag otherwise; the
result is verified from the page (document order, container membership) and reported as confirmed, "changed but not
confirmed" (a warning) or failed.

---

# Friday additions

## Voice-command routing (Laya)

Routing is one Laya `system_one` call that asks four questions at once: a `choice` over at most **ten** categories (ten keeps
the question inside the checkpoint's calibrated `choice:6-10` temperature bucket; the `choice:11+` bucket is clamped and
sharpened) and three `noul` propositions. Before the model runs, a deterministic bilingual (English/Spanish) keyword
pre-pass answers the obvious cases without touching MLX.

| Method | Path | Body → Response |
| --- | --- | --- |
| GET | `/api/route/categories` | → `{"categories": Category[], "questions": ["multistep","dangerous","question"]}` (the default list, in order) |
| POST | `/api/route` | `RouteRequest` → `RouteResult` (always `200` unless the body is invalid) |
| POST | `/api/laya/decide` | `DecideRequest` → raw laya_mlx `system_one` result + `latency_ms`; `503 laya_unavailable`, `400 bad_state` / `bad_question` |

```ts
type Category = { id: string; description: string };   // description is rendered into the prompt; keep it short

type RouteRequest = {
  text: string;                                   // 1..1000 chars (whitespace collapsed); 400 empty / too_long
  language?: "en" | "es" | null;                  // 400 bad_language otherwise
  context?: {
    frontmost_app?: string; has_selection?: boolean; browser_tab?: string;
    conversation?: string[];                      // the last 4 turns are used
  };                                              // 400 bad_context
  categories?: Category[];                        // 2..10 unique ids; default list when omitted; 400 bad_categories
};
type RouteResult = {
  category: string;                               // a category id, or "unknown"
  confidence: number;                             // rules: 0.9; laya: answer_confidence (= max probability); none: 0
  probabilities: { [id: string]: number };        // rules: {id: 0.9}; laya: the full distribution; none: {}
  multistep: number | null;                       // P(true) of "needs more than one distinct action / a sequence"; null unless source == "laya"
  dangerous: number | null;                       // P(true) of "deletes data, sends a message/email, spends money, changes security settings"
  question: number | null;                        // P(true) of "a question to answer rather than a command"
  latency_ms: number;                             // whole call, including the hop to the Laya thread
  model: string | null;                           // "rules", the Laya checkpoint id, or null
  source: "rules" | "laya" | "none";              // "none" = Laya unavailable and no rule matched: fall back to the LLM
  error?: string;                                 // only with source "none"
};
```

Rules pre-pass: the request is lower-cased, accent-stripped and matched on word boundaries against per-category keyword
lists (e.g. `reminder/recuérdame/recordatorio` → reminders, `play/pon/música/canción/playlist` → music, `note/nota/apunta`
→ notes, `timer/temporizador/alarma/alarm` → clock, `email/correo/mail/mensaje/whatsapp` → communication,
`search/busca/google/website/web/chrome/youtube/flight/vuelo` and `*.com`-style domains → browser,
`file/archivo/carpeta/folder/download/descarga/rename` → files, `volume/volumen/brightness/brillo/open/abre/close/cierra/
window/ventana/screenshot/captura` → system, `weather/tiempo/clima/calculate/calcula/cuánto/what is/qué es/traduce/translate`
→ information, `event/evento/meeting/reunión/calendar/calendario/cita` → calendar). When **exactly one** of the offered
categories is named, it is returned with `source: "rules"` and `confidence: 0.9`; when zero or several are named, Laya
decides. With custom `categories`, only rules for ids in that list apply.

Laya state string, one line per known field:

```
Request: <text>
Language: <en|es|unknown>
Frontmost app: <context.frontmost_app>
Text selected: <yes|no>
Browser tab: <context.browser_tab>
Recent conversation:
- <turn>
```

Timing (M-series Mac, model warm): rules ≈ 0 ms; Laya path ≈ 75 ms end-to-end through HTTP (the first call of a new
question shape is slower while Metal kernels compile; the sidecar warms the production shape at startup). All Laya work
serialises on one thread, so a route request queues behind an in-flight browser decision.

```ts
type DecideRequest = {
  state: string | object | string[];                 // laya_mlx state (a list is a conversation, truncated from the left)
  questions: { [qid: string]: { type: "choice" | "score" | "noul"; instructions: string; criteria?: any; labels?: any } };
  min_confidence?: number | { [bucket: string]: number };   // turns on laya_mlx's abstention gate
};
// Response: {"model":"laya-rl-agent","answers":{qid: Answer},"usage":{...},"latency_ms":n}
// choice Answer: {type, choice, probabilities:{label:p}, confidence, answer_confidence, action, abstention?, low_confidence?}
// noul Answer:   {type, noul: P(true), confidence, answer_confidence, action, ...}
// score Answer:  {type, score, legend, probabilities, confidence, answer_confidence, action, ...}
```

## LLM session override and the Responses API

`llm.api` selects the wire protocol of the planner's text model: `chat` (`POST {base_url}/chat/completions`, unchanged) or
`responses` (`POST {base_url}/responses`, OpenAI Responses API). Friday's ChatGPT sign-in tokens are only valid for the
latter. On the Responses path the client:

* puts the system prompt in the top-level `instructions` field and never sends a `{role: "system"}` input item; other
  messages become `input` items with roles `user` / `assistant`;
* always sends `"store": false` and `"stream": true`; never sends `temperature`, `max_output_tokens`, `reasoning`,
  `reasoning_effort` or `user`;
* maps a JSON-schema request to `"text": {"format": {"type": "json_schema", "name": "plan", "schema": ..., "strict": false}}`
  and plain JSON mode to `{"type": "json_object"}` (a `400` mentioning the format downgrades once, as on the chat path);
* reads the SSE stream: `response.output_text.delta` is text, `response.completed` marks success (its `usage`/`model` are
  reported), `response.failed`, `response.incomplete` and `error` raise `LlmError` with the provider's `code` preserved, and a
  stream that ends without `response.completed` is an error (`incomplete_stream`);
* lists models from `GET {base_url}/models` in either shape: `{"data":[{"id"}]}` or
  `{"models":[{"slug","display_name","visibility"}]}` (only `visibility == "list"`, by `slug`).

| Method | Path | Body → Response |
| --- | --- | --- |
| PUT | `/api/llm/session` | `{"base_url": str, "model": str, "api": "chat"|"responses", "api_key"?: str}` → `LlmStatus`; `400 bad_session` |
| DELETE | `/api/llm/session` | → `LlmStatus` (back to the stored settings) |

The session override lives **in memory only** for the lifetime of the process: nothing is written to the settings DB or the
Keychain, `GET /api/settings` keeps showing the stored values, and `GET /api/llm/status` reports `session: true`,
`provider: "friday"`, the override's `base_url`/`model`/`api`, `api_key_set` — and never the key. Friday refreshes it with
another `PUT` when its token rotates. Settings writes while the override is active do not displace it.

## Speech-to-text (optional, mlx-whisper)

Installed only with `uv sync --extra whisper`. Without it every STT endpoint answers `501 stt_unavailable` and nothing else
changes. Transcription runs on the Laya worker thread (the single MLX thread) and mlx-whisper keeps the last model loaded,
so only the first request pays the load.

| Method | Path | Body → Response |
| --- | --- | --- |
| GET | `/api/stt/status` | → `SttStatus` |
| POST | `/api/stt/download` | `{"model"?: str}` → `SttStatus` immediately; progress as `stt.download` events; `501 stt_unavailable` |
| POST | `/api/stt/transcribe?language=auto|en|es&model=<repo>` | body `application/octet-stream`: raw little-endian **float32 mono PCM at 16 kHz** (≤ 600 s) → `Transcript`; `501 stt_unavailable`, `409 stt_model_missing`, `415 bad_content_type`, `400 bad_audio` / `bad_language` / `bad_model` |

```ts
type SttStatus = {
  available: boolean;                  // mlx_whisper importable
  model: string;                       // default "mlx-community/whisper-large-v3-turbo"
  downloaded: boolean; size_bytes: number | null;
  state: "unavailable" | "unsupported" | "missing" | "downloading" | "idle" | "busy" | "ready" | "error";
  loaded: string | null;               // repo currently held in memory
  load_ms: number | null; last_latency_ms: number | null; error: string | null;
};
type Transcript = {
  text: string;                        // whitespace-normalised
  language: string;                    // detected (or the requested) language code
  segments: { start: number; end: number; text: string }[];
  latency_ms: number;
  model: string;
};
```
