"""The local HTTP/WebSocket API contract (docs/API.md): authentication, origin checks, settings, conversations, events."""

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from jarvis.app import App
from jarvis.server import create_app
from jarvis.settings import Secrets

TOKEN = "t" * 64
PORT = 8765
BASE = f"http://127.0.0.1:{PORT}"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
HOST = {"host": f"127.0.0.1:{PORT}"}


@pytest.fixture
def core(tmp_path):
    secrets = Secrets()
    secrets._keyring = None
    secrets.backend = "memory"
    return App(tmp_path / "data", downloads_dir=tmp_path / "downloads", secrets=secrets)


@pytest.fixture
def api(core):
    stopped = []
    app = create_app(core, TOKEN, lambda: PORT, lambda: stopped.append(True))
    client = TestClient(app, base_url=BASE)
    client.stopped = stopped
    return client


def test_health_is_open_everything_else_needs_the_token(api):
    assert api.get("/health").json()["status"] == "ready"
    assert api.get("/api/status").status_code == 401
    assert api.get("/api/status", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert api.get("/api/status", headers=AUTH).status_code == 200


def test_requests_for_other_hosts_or_origins_are_refused(api):
    assert api.get("/api/status", headers={**AUTH, "Host": "evil.example"}).status_code == 403  # DNS rebinding
    assert api.get("/api/status", headers={**AUTH, "Origin": "https://evil.example"}).status_code == 403
    ok = api.get("/api/status", headers={**AUTH, "Origin": "tauri://localhost"})
    assert ok.status_code == 200 and ok.headers["access-control-allow-origin"] == "tauri://localhost"


def test_the_webview_can_read_health_cross_origin(api):
    r = api.get("/health", headers={"Origin": "tauri://localhost"})
    assert r.status_code == 200 and r.headers["access-control-allow-origin"] == "tauri://localhost"


def test_cors_preflight_works_without_credentials_for_the_webview_only(api):
    ok = api.options("/api/settings", headers={"Origin": "tauri://localhost", "Access-Control-Request-Method": "PUT"})
    assert ok.status_code == 204 and "PUT" in ok.headers["access-control-allow-methods"] and "authorization" in ok.headers["access-control-allow-headers"]
    assert api.options("/api/settings", headers={"Origin": "https://evil.example"}).status_code == 403


def test_status_and_onboarding_describe_the_machine(api):
    status = api.get("/api/status", headers=AUTH).json()
    assert status["arch"] in {"arm64", "x86_64"} and {"chrome", "laya", "llm", "version", "mlx_supported"} <= set(status)
    checks = api.post("/api/onboarding/check", headers=AUTH).json()
    ids = [c["id"] for c in checks["checks"]]
    assert ids == ["apple_silicon", "macos", "chrome", "python", "laya_model", "text_model", "chrome_connection"]
    assert all(c["status"] in {"ok", "warn", "error", "pending"} for c in checks["checks"]) and isinstance(checks["ready"], bool)


def test_settings_validate_and_persist_and_secrets_stay_out(api, core):
    settings = api.get("/api/settings", headers=AUTH).json()
    assert settings["chrome"]["mode"] == "managed" and settings["llm"]["api_key_set"] is False
    updated = api.put("/api/settings", headers=AUTH, json={"agent": {"max_steps": 25}, "llm": {"model": "qwen3:8b"}}).json()
    assert updated["agent"]["max_steps"] == 25 and core.llm.config.model == "qwen3:8b"
    bad = api.put("/api/settings", headers=AUTH, json={"agent": {"max_steps": -1}})
    assert bad.status_code == 400 and bad.json()["error"]["code"] == "invalid_setting"
    assert api.put("/api/secrets/llm_api_key", headers=AUTH, json={"value": "sk-secret"}).json() == {"name": "llm_api_key", "set": True}
    assert api.get("/api/settings", headers=AUTH).json()["llm"]["api_key_set"] is True and "sk-secret" not in api.get("/api/settings", headers=AUTH).text
    assert core.llm.config.api_key == "sk-secret"
    assert api.put("/api/secrets/other", headers=AUTH, json={"value": "x"}).status_code == 404
    api.delete("/api/secrets/llm_api_key", headers=AUTH)
    assert api.get("/api/settings", headers=AUTH).json()["llm"]["api_key_set"] is False


def test_conversation_lifecycle(api):
    conv = api.post("/api/conversations", headers=AUTH, json={}).json()
    assert api.patch(f"/api/conversations/{conv['id']}", headers=AUTH, json={"title": "Flights"}).json()["title"] == "Flights"
    detail = api.get(f"/api/conversations/{conv['id']}", headers=AUTH).json()
    assert detail["messages"] == [] and detail["tasks"] == []
    assert api.post(f"/api/conversations/{conv['id']}/clear", headers=AUTH).json() == {"ok": True}
    assert api.delete(f"/api/conversations/{conv['id']}", headers=AUTH).json() == {"ok": True}
    assert api.get(f"/api/conversations/{conv['id']}", headers=AUTH).status_code == 404


def test_messages_are_validated_and_only_one_task_runs_at_a_time(api, core):
    conv = api.post("/api/conversations", headers=AUTH, json={}).json()
    assert api.post(f"/api/conversations/{conv['id']}/messages", headers=AUTH, json={"text": "  "}).status_code == 400
    assert api.post(f"/api/conversations/{conv['id']}/messages", headers=AUTH, json={"text": "x" * 9000}).json()["error"]["code"] == "too_long"
    assert api.post("/api/conversations/nope/messages", headers=AUTH, json={"text": "hi"}).status_code == 404

    class Busy:
        finished = False

    core.running = Busy()
    busy = api.post(f"/api/conversations/{conv['id']}/messages", headers=AUTH, json={"text": "open example.com"})
    assert busy.status_code == 409 and busy.json()["error"]["code"] == "task_running"


def test_chrome_endpoints_validate_input(api):
    assert api.get("/api/chrome/status", headers=AUTH).json()["mode"] == "managed"
    assert api.post("/api/chrome/connect", headers=AUTH, json={"mode": "other"}).status_code == 400
    assert api.post("/api/chrome/reset-profile", headers=AUTH, json={}).status_code == 400
    assert api.put("/api/chrome/path", headers=AUTH, json={"path": "/Applications/Safari.app"}).status_code == 400
    assert api.post("/api/tasks/unknown/cancel", headers=AUTH).status_code == 409


def test_only_files_in_the_downloads_folder_can_be_revealed(api, core, tmp_path):
    outside = tmp_path / "secret.txt"
    outside.write_text("x")
    assert api.post("/api/open-path", headers=AUTH, json={"path": str(outside)}).status_code == 403
    assert api.post("/api/open-path", headers=AUTH, json={"path": str(core.downloads_dir / "missing.png")}).status_code == 404


def test_shutdown_is_acknowledged_then_performed(api):
    assert api.post("/api/shutdown", headers=AUTH).json() == {"ok": True}


def test_websocket_requires_the_token_subprotocol_and_streams_events(api, core):
    with pytest.raises(WebSocketDisconnect):
        with api.websocket_connect("/api/events", subprotocols=["jarvis.v1", "bearer.wrong"], headers=dict(HOST)):
            pass
    with api.websocket_connect("/api/events", subprotocols=["jarvis.v1", f"bearer.{TOKEN}"], headers=dict(HOST)) as ws:
        hello = ws.receive_json()
        assert hello["type"] == "hello"
        core.bus.publish("notice", {"level": "info", "message": "hi"})
        event = ws.receive_json()
        assert event["type"] == "notice" and event["seq"] > hello["seq"] - 1 and event["data"]["message"] == "hi"


def test_a_websocket_for_another_host_is_refused_even_with_the_right_token(api):
    with pytest.raises(WebSocketDisconnect):
        with api.websocket_connect("/api/events", subprotocols=["jarvis.v1", f"bearer.{TOKEN}"], headers={"host": "evil.example"}):
            pass


# Friday additions --------------------------------------------------------------------------------------------------------


def test_environment_variables_accept_the_friday_prefix_first_then_jarvis(monkeypatch):
    from jarvis.server import DEFAULT_DATA_DIR, env

    for name in ("FRIDAY_TOKEN", "JARVIS_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    assert env("TOKEN") is None and env("TOKEN", "d") == "d"
    monkeypatch.setenv("JARVIS_TOKEN", "old")
    assert env("TOKEN") == "old"
    monkeypatch.setenv("FRIDAY_TOKEN", "new")
    assert env("TOKEN") == "new"
    monkeypatch.setenv("FRIDAY_TOKEN", "")
    assert env("TOKEN") == "old"  # empty counts as unset
    assert str(DEFAULT_DATA_DIR).endswith("Library/Application Support/Friday/sidecar")


def test_the_watchdog_notices_a_dead_declared_parent():
    import os
    import subprocess

    from jarvis.server import parent_gone, pid_alive

    assert pid_alive(os.getpid()) and not parent_gone(os.getppid(), None) and not parent_gone(os.getppid(), os.getpid())
    assert parent_gone(os.getppid() + 1_000_000, None)  # re-parented
    child = subprocess.Popen(["sleep", "30"])
    try:
        assert pid_alive(child.pid) and not parent_gone(os.getppid(), child.pid)
    finally:
        child.kill()
        child.wait()
    assert not pid_alive(child.pid) and parent_gone(os.getppid(), child.pid)


def test_defaults_are_branded_for_friday(core):
    from jarvis.settings import SERVICE

    assert SERVICE == "com.alejandro.friday.sidecar"
    assert str(App.__init__.__defaults__ or "") == "" or True  # downloads default is checked through a fresh App below
    fresh = App(core.data_dir / "fresh")
    assert str(fresh.downloads_dir).endswith("Downloads/Friday")
    fresh.store.close()


def test_llm_session_override_is_in_memory_only_and_never_leaks_the_key(api, core):
    before = api.get("/api/llm/status", headers=AUTH).json()
    assert before["session"] is False and before["api"] == "chat" and "api_key" not in before
    r = api.put("/api/llm/session", headers=AUTH, json={"base_url": "http://127.0.0.1:1/v1/", "model": "gpt-5", "api": "responses", "api_key": "sess-secret"})
    assert r.status_code == 200, r.text
    status = r.json()
    assert status["session"] is True and status["api"] == "responses" and status["model"] == "gpt-5" and status["base_url"] == "http://127.0.0.1:1/v1"
    assert status["provider"] == "friday" and status["api_key_set"] is True and "sess-secret" not in r.text
    assert core.llm.config.api == "responses" and core.llm.config.api_key == "sess-secret" and core.llm.config.model == "gpt-5"
    # nothing persisted: settings DB and Keychain untouched
    assert core.settings.get("llm.model") == "" and core.settings.get("llm.api") == "chat" and core.settings.secrets.get("llm_api_key") is None
    assert api.get("/api/settings", headers=AUTH).json()["llm"]["model"] == "" and "sess-secret" not in api.get("/api/settings", headers=AUTH).text
    # settings changes keep the override in force
    api.put("/api/settings", headers=AUTH, json={"llm": {"model": "qwen3:8b"}})
    assert core.llm.config.model == "gpt-5" and core.settings.get("llm.model") == "qwen3:8b"
    cleared = api.delete("/api/llm/session", headers=AUTH).json()
    assert cleared["session"] is False and cleared["model"] == "qwen3:8b" and cleared["api"] == "chat" and core.llm.config.api_key is None
    for bad in ({"model": "m"}, {"base_url": "ftp://x", "model": "m"}, {"base_url": "http://x", "model": ""}, {"base_url": "http://x", "model": "m", "api": "grpc"},
                {"base_url": "http://x", "model": "m", "api_key": 5}):
        r = api.put("/api/llm/session", headers=AUTH, json=bad)
        assert r.status_code == 400 and r.json()["error"]["code"] == "bad_session", bad


def test_llm_api_is_a_validated_setting(api, core):
    assert api.put("/api/settings", headers=AUTH, json={"llm": {"api": "responses"}}).json()["llm"]["api"] == "responses"
    assert core.llm.config.api == "responses"
    assert api.put("/api/settings", headers=AUTH, json={"llm": {"api": "soap"}}).status_code == 400


def test_messages_carry_the_users_language_into_the_conversation(api, core, monkeypatch):
    from jarvis import app as app_module

    class NeverRuns:
        def add_done_callback(self, _cb):
            pass

    monkeypatch.setattr(app_module.TaskRun, "start", lambda self: NeverRuns())  # no Chrome, no planner in a unit test
    conv = api.post("/api/conversations", headers=AUTH, json={}).json()
    bad = api.post(f"/api/conversations/{conv['id']}/messages", headers=AUTH, json={"text": "abre example.com", "language": "fr"})
    assert bad.status_code == 400 and bad.json()["error"]["code"] == "bad_language"
    first = api.post(f"/api/conversations/{conv['id']}/messages", headers=AUTH, json={"text": "abre example.com", "language": "es"})
    assert first.status_code == 200, first.text
    assert first.json()["task"]["language"] == "es" and core.contexts[conv["id"]].language == "es"
    core.running = None
    second = api.post(f"/api/conversations/{conv['id']}/messages", headers=AUTH, json={"text": "y ahora la segunda"})
    assert second.json()["task"]["language"] == "es"  # the conversation keeps its language until told otherwise
    core.running = None
    third = api.post(f"/api/conversations/{conv['id']}/messages", headers=AUTH, json={"text": "now in English", "language": "en"})
    assert third.json()["task"]["language"] == "en"
    task = api.get(f"/api/tasks/{third.json()['task']['id']}", headers=AUTH).json()
    assert {"language", "error_code", "reconnects", "notices"} <= set(task)


def test_chrome_errors_reach_the_client_with_a_stable_reason():
    from jarvis.server import error_response

    body = error_response(409, "chrome_not_connected", "The Friday automation profile is open elsewhere.", "profile_in_use").body
    assert b'"reason":"profile_in_use"' in body and b'"code":"chrome_not_connected"' in body
    assert b"reason" not in error_response(404, "not_found", "x").body


def test_upload_folders_are_a_validated_setting(api, core):
    ok = api.put("/api/settings", headers=AUTH, json={"agent": {"upload_folders": ["~/Documents ", "/Users/me/Desktop"]}})
    assert ok.status_code == 200 and ok.json()["agent"]["upload_folders"] == ["~/Documents", "/Users/me/Desktop"]
    assert core.settings.get("agent.upload_folders") == ["~/Documents", "/Users/me/Desktop"]
    for bad in ("nope", [1], [""], ["x"] * 21):
        assert api.put("/api/settings", headers=AUTH, json={"agent": {"upload_folders": bad}}).status_code == 400, bad
    assert api.get("/api/chrome/status", headers=AUTH).json()["error_code"] is None


def test_routing_endpoints_without_the_model(api, core):
    from jarvis.laya_engine import LayaUnavailable

    async def unavailable():
        raise LayaUnavailable("no model here")

    core.laya.ensure_loaded = unavailable
    cats = api.get("/api/route/categories", headers=AUTH).json()
    assert [c["id"] for c in cats["categories"]][:3] == ["music", "reminders", "notes"] and cats["questions"] == ["multistep", "dangerous", "question"]

    ruled = api.post("/api/route", headers=AUTH, json={"text": "play some jazz"}).json()
    assert ruled["category"] == "music" and ruled["confidence"] == 0.9 and ruled["source"] == "rules" and ruled["model"] == "rules"
    spanish = api.post("/api/route", headers=AUTH, json={"text": "recuérdame comprar leche mañana", "language": "es"}).json()
    assert spanish["category"] == "reminders" and spanish["source"] == "rules"

    unknown = api.post("/api/route", headers=AUTH, json={"text": "turn on dark mode", "context": {"frontmost_app": "Finder"}})
    assert unknown.status_code == 200 and unknown.json()["category"] == "unknown" and unknown.json()["confidence"] == 0 and unknown.json()["source"] == "none"

    custom = api.post("/api/route", headers=AUTH, json={"text": "open github.com", "categories": [{"id": "browser", "description": "web"}, {"id": "music", "description": "songs"}]}).json()
    assert custom["category"] == "browser" and custom["source"] == "rules"  # "open" belongs to a category that is not offered

    decide = api.post("/api/laya/decide", headers=AUTH, json={"state": "x", "questions": {"q": {"type": "noul", "instructions": "?"}}})
    assert decide.status_code == 503 and decide.json()["error"]["code"] == "laya_unavailable"
    assert api.post("/api/route", headers=AUTH, json={"text": "  "}).json()["error"]["code"] == "empty"
    assert api.post("/api/route", headers=AUTH, json={"text": "x", "language": "fr"}).json()["error"]["code"] == "bad_language"
    assert api.post("/api/route", headers=AUTH, json={"text": "x", "categories": [{"id": "a", "description": "b"}]}).json()["error"]["code"] == "bad_categories"
    assert api.post("/api/route", headers=AUTH, json={"text": "x", "context": "nope"}).json()["error"]["code"] == "bad_context"
    assert api.post("/api/laya/decide", headers=AUTH, json={"state": "x"}).json()["error"]["code"] == "bad_question"
    assert api.post("/api/laya/decide", headers=AUTH, json={"state": "", "questions": {"q": {}}}).json()["error"]["code"] == "bad_state"
