"""The local HTTP + WebSocket API (docs/API.md). Loopback only, bearer-token authenticated.

Spawned by the Friday app as a direct child: it reads one JSON ready line from stdout and exits when the parent goes away.
Configuration comes from the environment; every variable is read with the FRIDAY_ prefix first and the original JARVIS_
prefix second (`env()`)."""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
import os
import secrets
import signal
import subprocess
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import Body, FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response

from . import __version__
from .app import ApiError, App
from .browser import BrowserNotConnected
from .laya_engine import LayaUnavailable
from .llm import LlmError, detect_local_servers
from .routing import DEFAULT_CATEGORIES, RouteError, check_categories, check_context
from .settings import SECRET_NAMES
from .stt import LANGUAGES, SttModelMissing, SttUnavailable, decode_pcm

log = logging.getLogger("jarvis.server")

ALLOWED_ORIGINS = {"tauri://localhost", "http://tauri.localhost", "https://tauri.localhost", "http://localhost:1420", "http://127.0.0.1:1420"}
DEFAULT_DATA_DIR = Path.home() / "Library" / "Application Support" / "Friday" / "sidecar"
ENV_PREFIXES = ("FRIDAY_", "JARVIS_")


def env(name: str, default: str | None = None) -> str | None:
    """`FRIDAY_<name>` if set (non-empty), else `JARVIS_<name>`, else the default."""
    for prefix in ENV_PREFIXES:
        value = os.environ.get(prefix + name)
        if value:
            return value
    return default


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by someone else
    return True


def parent_gone(initial_ppid: int, declared_pid: int | None) -> bool:
    """True when the process that launched us is no longer there: we were re-parented (getppid changed) or the pid the
    host declared through FRIDAY_PARENT_PID no longer exists."""
    if os.getppid() != initial_ppid:
        return True
    return declared_pid is not None and not pid_alive(declared_pid)


def error_response(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse({"error": {"code": code, "message": message}}, status_code=status)


def create_app(core: App, token: str, port_getter=lambda: 0, on_shutdown=lambda: None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        await core.start()
        yield
        await core.shutdown()

    api = FastAPI(title="Friday sidecar", version=__version__, lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    def host_ok(host: str | None) -> bool:
        port = port_getter()
        return bool(host) and host in {f"127.0.0.1:{port}", f"localhost:{port}", f"[::1]:{port}"} if port else bool(host) and host.split(":")[0] in {"127.0.0.1", "localhost", "[::1]"}

    @api.middleware("http")
    async def guard(request: Request, call_next):
        if not host_ok(request.headers.get("host")):
            return error_response(403, "bad_host", "Requests must target the loopback address.")
        origin = request.headers.get("origin")
        if origin and origin not in ALLOWED_ORIGINS:
            return error_response(403, "bad_origin", "This origin may not use the Friday sidecar API.")
        if request.method == "OPTIONS":
            response = Response(status_code=204)
        elif request.url.path == "/health":
            response = JSONResponse({"status": "ready", "version": __version__})
        else:
            supplied = request.headers.get("authorization", "")
            if not hmac.compare_digest(supplied, f"Bearer {token}"):
                return error_response(401, "unauthorized", "Missing or invalid token.")
            try:
                response = await call_next(request)
            except ApiError as error:
                response = error_response(error.status, error.code, error.message)
            except BrowserNotConnected as error:
                response = error_response(409, "chrome_not_connected", str(error))
            except LlmError as error:
                response = error_response(502, "llm_error", str(error))
            except LayaUnavailable as error:
                response = error_response(503, "laya_unavailable", str(error))
            except SttUnavailable as error:
                response = error_response(501, "stt_unavailable", str(error))
            except SttModelMissing as error:
                response = error_response(409, "stt_model_missing", str(error))
        if origin:
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Access-Control-Allow-Headers"] = "authorization, content-type"
            response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
            response.headers["Vary"] = "Origin"
        return response

    @api.exception_handler(ApiError)
    async def api_error(_request: Request, error: ApiError):
        return error_response(error.status, error.code, error.message)

    # System -------------------------------------------------------------------------------------------------

    @api.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ready", "version": __version__}

    @api.get("/api/status")
    async def status() -> dict[str, Any]:
        return await core.system_status()

    @api.post("/api/onboarding/check")
    async def onboarding() -> dict[str, Any]:
        return await core.onboarding()

    @api.get("/api/settings")
    async def get_settings() -> dict[str, Any]:
        return core.settings.public()

    @api.put("/api/settings")
    async def put_settings(patch: dict[str, Any] = Body(...)) -> dict[str, Any]:
        return await core.update_settings(patch)

    @api.put("/api/secrets/{name}")
    async def put_secret(name: str, body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        if name not in SECRET_NAMES:
            raise ApiError(404, "unknown_secret", "Unknown secret name.")
        value = str(body.get("value", "")).strip()
        if not value:
            raise ApiError(400, "empty", "The value is empty.")
        core.settings.secrets.set(name, value)
        core.llm.configure(core._llm_config())
        return {"name": name, "set": True}

    @api.delete("/api/secrets/{name}")
    async def delete_secret(name: str) -> dict[str, Any]:
        if name not in SECRET_NAMES:
            raise ApiError(404, "unknown_secret", "Unknown secret name.")
        core.settings.secrets.delete(name)
        core.llm.configure(core._llm_config())
        return {"name": name, "set": False}

    @api.post("/api/shutdown")
    async def shutdown() -> dict[str, bool]:
        asyncio.get_running_loop().call_later(0.2, on_shutdown)
        return {"ok": True}

    # Chrome -------------------------------------------------------------------------------------------------

    @api.get("/api/chrome/status")
    async def chrome_status() -> dict[str, Any]:
        return core.browser.status()

    @api.post("/api/chrome/connect")
    async def chrome_connect(body: dict[str, Any] | None = Body(default=None)) -> dict[str, Any]:
        mode = (body or {}).get("mode")
        if mode and mode not in {"managed", "existing"}:
            raise ApiError(400, "bad_mode", "mode must be managed or existing.")
        if core.running and not core.running.finished and mode and mode != core.browser.mode:
            raise ApiError(409, "task_running", "Finish or cancel the running task before switching modes.")
        if mode and mode != core.settings.get("chrome.mode"):
            await core.update_settings({"chrome": {"mode": mode}})
        return await core.browser.connect(mode, wait=60)

    @api.post("/api/chrome/disconnect")
    async def chrome_disconnect() -> dict[str, Any]:
        if core.running and not core.running.finished:
            raise ApiError(409, "task_running", "A task is running.")
        return await core.browser.disconnect()

    @api.post("/api/chrome/reset-profile")
    async def chrome_reset(body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        if body.get("confirm") is not True:
            raise ApiError(400, "confirm_required", "Pass {\"confirm\": true} to delete the automation profile.")
        if core.running and not core.running.finished:
            raise ApiError(409, "task_running", "A task is running.")
        from .chrome import ChromeError

        try:
            await core.browser.reset_profile()
        except ChromeError as error:
            raise ApiError(409, "profile_in_use", str(error)) from error
        return core.browser.status()

    @api.post("/api/chrome/focus")
    async def chrome_focus() -> dict[str, Any]:
        await core.browser.focus()
        return core.browser.status()

    @api.put("/api/chrome/path")
    async def chrome_path(body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        from .chrome import ChromeError, inspect_app

        try:
            install = inspect_app(Path(str(body.get("path", ""))))
        except ChromeError as error:
            raise ApiError(400, "not_chrome", str(error)) from error
        await core.update_settings({"chrome": {"path": str(install.app)}})
        core.browser.install = install
        return core.browser.status()

    # Laya + text model -----------------------------------------------------------------------------------------

    @api.get("/api/laya/status")
    async def laya_status() -> dict[str, Any]:
        return core.laya.status()

    @api.post("/api/laya/download")
    async def laya_download() -> dict[str, Any]:
        return await core.laya.download()

    @api.post("/api/laya/load")
    async def laya_load() -> dict[str, Any]:
        try:
            await core.laya.ensure_loaded()
        except Exception as error:
            log.warning("laya load: %s", error)
        return core.laya.status()

    @api.get("/api/llm/status")
    async def llm_status() -> dict[str, Any]:
        return await core.llm_status()

    @api.get("/api/llm/detect")
    async def llm_detect() -> dict[str, Any]:
        return {"candidates": await detect_local_servers()}

    @api.post("/api/llm/test")
    async def llm_test() -> dict[str, Any]:
        await core.ensure_llm_ready()
        return await core.llm.ping()

    @api.post("/api/llm/pull")
    async def llm_pull(body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        model = str(body.get("model", "")).strip()
        if not model or len(model) > 100:
            raise ApiError(400, "bad_model", "Give a model name such as qwen3:8b.")
        await core.pull_model(model)
        return {"ok": True}

    @api.post("/api/ollama/start")
    async def ollama_start() -> dict[str, bool]:
        return {"ok": await core.start_ollama()}

    @api.put("/api/llm/session")
    async def llm_session(body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        base_url = str(body.get("base_url", "")).strip().rstrip("/")
        model = str(body.get("model", "")).strip()
        api_kind = str(body.get("api", "chat")).strip() or "chat"
        api_key = body.get("api_key")
        if not base_url.startswith(("http://", "https://")) or len(base_url) > 500:
            raise ApiError(400, "bad_session", "base_url must be an http(s) URL.")
        if not model or len(model) > 200:
            raise ApiError(400, "bad_session", "model is required.")
        if api_kind not in {"chat", "responses"}:
            raise ApiError(400, "bad_session", "api must be chat or responses.")
        if api_key is not None and not isinstance(api_key, str):
            raise ApiError(400, "bad_session", "api_key must be a string.")
        core.set_llm_session(base_url=base_url, model=model, api=api_kind, api_key=(api_key or "").strip() or None)
        return await core.llm_status()

    @api.delete("/api/llm/session")
    async def llm_session_clear() -> dict[str, Any]:
        core.clear_llm_session()
        return await core.llm_status()

    # Laya routing ------------------------------------------------------------------------------------------------

    @api.post("/api/laya/decide")
    async def laya_decide(body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        state = body.get("state")
        questions = body.get("questions")
        if not isinstance(state, (str, dict, list)) or (isinstance(state, str) and not state.strip()):
            raise ApiError(400, "bad_state", "state must be a non-empty string, an object or a list of turns.")
        if not isinstance(questions, dict) or not questions:
            raise ApiError(400, "bad_question", "questions must be a non-empty object of {id: {type, instructions, criteria}}.")
        try:
            return await core.router.decide(state, questions, min_confidence=body.get("min_confidence"))
        except ValueError as error:  # laya_mlx rejected the question schema or the threshold
            raise ApiError(400, "bad_question", str(error)) from error

    @api.get("/api/route/categories")
    async def route_categories() -> dict[str, Any]:
        return {"categories": DEFAULT_CATEGORIES, "questions": ["multistep", "dangerous", "question"]}

    @api.post("/api/route")
    async def route(body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        text = " ".join(str(body.get("text", "")).split())
        if not text:
            raise ApiError(400, "empty", "text is required.")
        if len(text) > 1000:
            raise ApiError(400, "too_long", "text must be at most 1,000 characters.")
        language = body.get("language")
        if language is not None and language not in {"en", "es"}:
            raise ApiError(400, "bad_language", "language must be en, es or null.")
        try:
            categories = check_categories(body.get("categories"))
            context = check_context(body.get("context"))
        except RouteError as error:
            raise ApiError(400, "bad_categories" if "categor" in str(error) else "bad_context", str(error)) from error
        return await core.router.route(text, language=language, context=context, categories=categories)

    # Speech-to-text (optional) ------------------------------------------------------------------------------------

    @api.get("/api/stt/status")
    async def stt_status() -> dict[str, Any]:
        return core.stt.status()

    @api.post("/api/stt/download")
    async def stt_download(body: dict[str, Any] | None = Body(default=None)) -> dict[str, Any]:
        model = str((body or {}).get("model", "")).strip() or None
        if model and (len(model) > 200 or model.startswith("-")):
            raise ApiError(400, "bad_model", "Give a Hugging Face repo id such as mlx-community/whisper-large-v3-turbo.")
        return await core.stt.download(model)

    @api.post("/api/stt/transcribe")
    async def stt_transcribe(request: Request, language: str = "auto", model: str | None = None) -> dict[str, Any]:
        if language not in LANGUAGES:
            raise ApiError(400, "bad_language", "language must be auto, en or es.")
        if model is not None and (not model.strip() or len(model) > 200):
            raise ApiError(400, "bad_model", "Give a Hugging Face repo id such as mlx-community/whisper-large-v3-turbo.")
        content_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if content_type != "application/octet-stream":
            raise ApiError(415, "bad_content_type", "Send raw float32 PCM (16 kHz, mono, little-endian) as application/octet-stream.")
        try:
            pcm = decode_pcm(await request.body())
        except ValueError as error:
            raise ApiError(400, "bad_audio", str(error)) from error
        return await core.stt.transcribe(pcm, language=language, model=model.strip() if model else None)

    # Conversations -----------------------------------------------------------------------------------------------

    @api.get("/api/conversations")
    async def conversations() -> list[dict[str, Any]]:
        return core.store.list_conversations()

    @api.post("/api/conversations")
    async def new_conversation(body: dict[str, Any] | None = Body(default=None)) -> dict[str, Any]:
        return core.store.create_conversation((body or {}).get("title"))

    @api.get("/api/conversations/{conversation_id}")
    async def get_conversation(conversation_id: str) -> dict[str, Any]:
        conversation = core.store.get_conversation(conversation_id)
        if conversation is None:
            raise ApiError(404, "not_found", "Conversation not found.")
        tasks = []
        for stored in core.store.tasks_for(conversation_id):
            live = core.task(stored["id"])
            tasks.append(live.to_dict() if live else stored)
        return {"conversation": conversation, "messages": core.store.messages(conversation_id), "tasks": tasks}

    @api.patch("/api/conversations/{conversation_id}")
    async def rename(conversation_id: str, body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        updated = core.store.rename_conversation(conversation_id, str(body.get("title", "")))
        if updated is None:
            raise ApiError(404, "not_found", "Conversation not found.")
        return updated

    @api.delete("/api/conversations/{conversation_id}")
    async def delete_conversation(conversation_id: str) -> dict[str, bool]:
        if core.running and core.running.conversation_id == conversation_id and not core.running.finished:
            raise ApiError(409, "task_running", "Cancel the running task first.")
        core.store.delete_conversation(conversation_id)
        core.contexts.pop(conversation_id, None)
        return {"ok": True}

    @api.post("/api/conversations/{conversation_id}/clear")
    async def clear(conversation_id: str) -> dict[str, bool]:
        if core.running and core.running.conversation_id == conversation_id and not core.running.finished:
            raise ApiError(409, "task_running", "Cancel the running task first.")
        core.store.clear_conversation(conversation_id)
        core.contexts.pop(conversation_id, None)
        return {"ok": True}

    @api.post("/api/conversations/{conversation_id}/messages")
    async def post_message(conversation_id: str, body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        message, task = await core.send_message(conversation_id, str(body.get("text", "")))
        return {"message": message, "task": task}

    # Tasks ------------------------------------------------------------------------------------------------------------

    def live_or_stored(task_id: str) -> dict[str, Any]:
        live = core.task(task_id)
        task = live.to_dict() if live else core.store.get_task(task_id)
        if task is None:
            raise ApiError(404, "not_found", "Task not found.")
        return task

    def live(task_id: str):
        run = core.task(task_id)
        if run is None:
            raise ApiError(409, "not_active", "That task is no longer active.")
        return run

    @api.get("/api/tasks")
    async def recent_tasks(limit: int = 30) -> list[dict[str, Any]]:
        return [live_or_stored(t["id"]) for t in core.store.recent_tasks(max(1, min(limit, 200)))]

    @api.get("/api/tasks/{task_id}")
    async def get_task(task_id: str) -> dict[str, Any]:
        return live_or_stored(task_id)

    @api.post("/api/tasks/{task_id}/pause")
    async def pause(task_id: str) -> dict[str, Any]:
        run = live(task_id)
        run.pause()
        return run.to_dict()

    @api.post("/api/tasks/{task_id}/resume")
    async def resume(task_id: str) -> dict[str, Any]:
        run = live(task_id)
        run.resume()
        return run.to_dict()

    @api.post("/api/tasks/{task_id}/cancel")
    async def cancel(task_id: str) -> dict[str, Any]:
        run = live(task_id)
        run.cancel()
        for _ in range(40):  # let the task unwind so the response reflects the final state
            if run.finished:
                break
            await asyncio.sleep(0.05)
        return run.to_dict()

    @api.post("/api/tasks/{task_id}/retry")
    async def retry(task_id: str) -> dict[str, Any]:
        previous = live_or_stored(task_id)
        message, task = await core.send_message(previous["conversation_id"], previous["goal"], parent_task_id=task_id)
        return {"message": message, "task": task}

    @api.post("/api/tasks/{task_id}/confirm")
    async def confirm(task_id: str, body: dict[str, Any] = Body(...)) -> dict[str, Any]:
        run = live(task_id)
        if not run.answer_confirmation(str(body.get("confirmation_id", "")), bool(body.get("approved"))):
            raise ApiError(409, "no_such_confirmation", "That confirmation is no longer pending.")
        return run.to_dict()

    @api.get("/api/tasks/{task_id}/screenshot")
    async def screenshot(task_id: str) -> Response:
        if core.settings.get("agent.screenshots") == "off":
            raise ApiError(403, "screenshots_off", "Screenshots are turned off in Settings.")
        run = live(task_id)
        if run.tab is None or run.tab.closed:
            raise ApiError(409, "no_tab", "The task has no open tab.")
        return Response(await run.tab.screenshot_bytes(), media_type="image/jpeg", headers={"Cache-Control": "no-store"})

    @api.post("/api/open-path")
    async def open_path(body: dict[str, Any] = Body(...)) -> dict[str, bool]:
        path = Path(str(body.get("path", ""))).resolve()
        root = core.downloads_dir.resolve()
        if root not in path.parents and path != root:
            raise ApiError(403, "outside_downloads", "Only files in the Friday downloads folder can be revealed.")
        if not path.exists():
            raise ApiError(404, "missing", "That file no longer exists.")
        subprocess.Popen(["open", "-R", str(path)])  # noqa: S603,S607
        return {"ok": True}

    # Events ----------------------------------------------------------------------------------------------------------

    @api.websocket("/api/events")
    async def events(ws: WebSocket) -> None:
        origin = ws.headers.get("origin")
        offered = [p.strip() for p in ws.headers.get("sec-websocket-protocol", "").split(",")]
        supplied = next((p[len("bearer."):] for p in offered if p.startswith("bearer.")), "")
        if (origin and origin not in ALLOWED_ORIGINS) or not host_ok(ws.headers.get("host")) or not hmac.compare_digest(supplied, token):
            log.warning("rejected a WebSocket: origin=%r host=%r token_ok=%s", origin, ws.headers.get("host"), hmac.compare_digest(supplied, token))
            await ws.close(code=4401)
            return
        await ws.accept(subprotocol="jarvis.v1")
        queue = core.bus.subscribe()
        try:
            await ws.send_text(json.dumps({"seq": core.bus.seq, "ts": "", "type": "hello", "data": {"seq": core.bus.seq}}))

            async def reader() -> None:
                try:
                    while True:
                        await ws.receive_text()  # we only need to notice a disconnect
                except (WebSocketDisconnect, RuntimeError):
                    return

            read_task = asyncio.create_task(reader())
            while True:
                getter = asyncio.create_task(queue.get())
                done, _ = await asyncio.wait({getter, read_task}, return_when=asyncio.FIRST_COMPLETED)
                if read_task in done:
                    getter.cancel()
                    break
                await ws.send_text(json.dumps(getter.result(), default=str))
        except WebSocketDisconnect:
            pass
        finally:
            core.bus.unsubscribe(queue)

    return api


# Entry point ----------------------------------------------------------------------------------------------------------


def configure_logging(data_dir: Path) -> None:
    logs = data_dir / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr), logging.FileHandler(logs / "jarvis.log")]
    logging.basicConfig(level=env("LOG", "INFO"), handlers=handlers, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)


async def serve() -> None:
    data_dir = Path(env("DATA_DIR") or DEFAULT_DATA_DIR)
    configure_logging(data_dir)
    token = env("TOKEN")
    if not token:
        token = secrets.token_hex(32)
        print(f"FRIDAY_TOKEN={token}", file=sys.stderr, flush=True)  # standalone use only; the host app always supplies one
    downloads = env("DOWNLOADS_DIR")
    core = App(data_dir, downloads_dir=Path(downloads) if downloads else None)
    state: dict[str, Any] = {"port": 0}
    server: uvicorn.Server

    def stop() -> None:
        server.should_exit = True

    api = create_app(core, token, lambda: state["port"], stop)
    config = uvicorn.Config(api, host="127.0.0.1", port=int(env("PORT", "0") or 0), log_level="warning", ws_max_size=1 << 20,
                            access_log=False, lifespan="on")
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve())
    while not server.started:
        if task.done():
            task.result()
        await asyncio.sleep(0.02)
    state["port"] = server.servers[0].sockets[0].getsockname()[1]
    print(json.dumps({"event": "ready", "port": state["port"], "version": __version__, "pid": os.getpid()}), flush=True)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop)
    parent = os.getppid()
    declared = env("PARENT_PID")
    try:
        parent_pid = int(declared) if declared else None
    except ValueError:
        log.warning("ignoring non-numeric parent pid %r", declared)
        parent_pid = None
    if parent_pid is not None and parent_pid != parent:
        log.info("declared parent pid %d differs from getppid() %d; watching both", parent_pid, parent)

    async def watch_parent() -> None:
        while not server.should_exit:
            await asyncio.sleep(2)
            if parent_gone(parent, parent_pid):  # the host died: do not linger with a browser connection open
                log.warning("parent process exited; shutting down")
                stop()

    watcher = asyncio.create_task(watch_parent())
    await task
    watcher.cancel()


def main() -> None:
    started = time.perf_counter()
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        pass
    logging.getLogger("jarvis").info("stopped after %.1fs", time.perf_counter() - started)


if __name__ == "__main__":
    main()
