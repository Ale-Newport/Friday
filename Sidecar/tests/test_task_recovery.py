"""The task runner against a fake browser: Chrome dropping mid-task, structured confirmations, repeated challenges and the
user's language. No Chrome, no Laya, no text model (plans come from the URL fast path or a scripted model)."""

from __future__ import annotations

import asyncio
import uuid
from typing import Any

import pytest
from conftest import ScriptedLLM

from jarvis.browser import BrowserNotConnected, Metrics
from jarvis.cdp import CDPClosed, CDPError
from jarvis.events import EventBus
from jarvis.laya_engine import LayaUnavailable
from jarvis.settings import Secrets, Settings
from jarvis.store import Store
from jarvis.task import MAX_RECONNECTS, ConversationContext, Services, TaskRun

pytestmark = pytest.mark.asyncio(loop_scope="session")


def page_for(url: str, *, text: str = "Hello, a perfectly ordinary page.", title: str | None = None) -> dict[str, Any]:
    return {"url": url, "title": title or f"Page {url}", "text": text, "actions": [], "scroll": {"y": 0, "height": 100}, "h": 50, "w": 100,
            "fingerprint": url, "marker": [url], "page_key": [], "guards": {}, "iframe_hosts": [], "status": 200, "omitted_actions": 0}


class FakeTab:
    def __init__(self, browser: FakeBrowser, url: str = "about:blank"):
        self.browser = browser
        self.id = f"tab-{uuid.uuid4().hex[:6]}"
        self.url = url
        self.title = "" if url == "about:blank" else f"Page {url}"
        self.closed = False
        self.reloads = 0

    async def goto(self, url: str, *, wait: str = "load", timeout: float = 20) -> dict[str, Any]:
        if self.closed:
            raise CDPError("tab is closed")
        if self.browser.drops_left > 0:
            self.browser.drops_left -= 1
            self.browser.simulate_drop()
            raise CDPClosed("browser connection lost: socket closed")
        self.url, self.title = url, f"Page {url}"
        return {"loaded": True, "ms": 1}

    async def observe(self, *, screenshot: bool = False) -> dict[str, Any]:
        if self.closed:
            raise CDPError("tab is closed")
        if self.browser.observations:
            return self.browser.observations.pop(0)
        return page_for(self.url)

    async def reload(self) -> None:
        self.reloads += 1

    async def activate(self) -> None:
        pass

    async def wait_loaded(self, timeout: float = 15) -> bool:
        return True

    async def read(self, **opts: Any) -> dict[str, Any]:
        page = page_for(self.url)
        return {"url": page["url"], "title": page["title"], "text": page["text"], "total_chars": len(page["text"]), "links": [], "headings": [], "meta": {}}


class FakeBrowser:
    """Just enough of BrowserSession for the runner: connection state, tabs, a reconnect() that can be told to fail."""

    def __init__(self) -> None:
        self.state = "connected"
        self.mode = "managed"
        self.metrics = Metrics()
        self.tabs: dict[str, FakeTab] = {}
        self.active: FakeTab | None = None
        self.drops_left = 0  # how many of the next goto() calls drop the connection
        self.observations: list[dict[str, Any]] = []  # scripted observe() results, consumed in order
        self.reconnect_calls = 0
        self.reconnect_fails = False
        self.error = None
        self.error_code = None

    @property
    def connected(self) -> bool:
        return self.state == "connected"

    def simulate_drop(self) -> None:
        self.state = "disconnected"
        self.error, self.error_code = "Chrome closed the DevTools connection.", "chrome_disconnected"
        for tab in self.tabs.values():
            tab.closed = True
        self.tabs.clear()
        self.active = None

    def status(self) -> dict[str, Any]:
        return {"state": self.state, "error": self.error, "error_code": self.error_code, "mode": self.mode}

    async def ensure_connected(self) -> None:
        if not self.connected:
            raise BrowserNotConnected(self.error or "Chrome is not connected.", self.error_code or "chrome_not_connected")

    async def reconnect(self, *, attempts: int = 3, wait: float = 90) -> dict[str, Any]:
        self.reconnect_calls += 1
        if self.reconnect_fails:
            self.error, self.error_code = "Chrome exited immediately (code 1).", "chrome_exited"
            return {"state": "error", "error": self.error, "error_code": self.error_code}
        self.state, self.error, self.error_code = "connected", None, None
        return self.status()

    def get_tab(self, tab_id: str | None = None) -> FakeTab | None:
        return self.tabs.get(tab_id) if tab_id else self.active

    async def new_tab(self, url: str = "about:blank", **_kw: Any) -> FakeTab:
        await self.ensure_connected()
        tab = FakeTab(self, url)
        self.tabs[tab.id] = tab
        self.active = tab
        return tab

    async def close_tab(self, tab: FakeTab) -> None:
        tab.closed = True
        self.tabs.pop(tab.id, None)

    def take_popups(self) -> list[FakeTab]:
        return []


class FakeLaya:
    async def ensure_loaded(self) -> None:
        raise LayaUnavailable("no Laya in this test")


def make_run(goal: str, browser: FakeBrowser, *, language: str = "en", llm: ScriptedLLM | None = None, tmp_path=None) -> tuple[TaskRun, EventBus]:
    bus = EventBus()
    store = Store(":memory:")
    secrets = Secrets()
    secrets._keyring = None
    secrets.backend = "memory"
    settings = Settings(store, secrets)
    settings.update({"agent": {"max_minutes": 2}})
    conversation = store.create_conversation()
    ctx = ConversationContext(language=language)
    services = Services(browser, FakeLaya(), llm or ScriptedLLM({}), settings, bus, store, tmp_path or store.path if hasattr(store, "path") else tmp_path)
    run = TaskRun(services, task_id=str(uuid.uuid4()), conversation_id=conversation["id"], message_id=str(uuid.uuid4()), goal=goal, ctx=ctx)
    return run, bus


async def finished(run: TaskRun, queue: asyncio.Queue, timeout: float = 20) -> list[dict[str, Any]]:
    await asyncio.wait_for(run.start(), timeout)
    events = []
    while not queue.empty():
        events.append(queue.get_nowait())
    return events


# Chrome going away mid-task -------------------------------------------------------------------------------------------------


async def test_a_dropped_connection_is_reconnected_and_the_step_continues(tmp_path):
    browser = FakeBrowser()
    browser.drops_left = 1
    run, bus = make_run("open example.com", browser, tmp_path=tmp_path)
    queue = bus.subscribe()
    events = await finished(run, queue)
    assert run.status == "done", (run.error, run.result and run.result["markdown"])
    assert browser.reconnect_calls == 1 and run.reconnects == 1
    assert run.page["url"] == "https://example.com"
    kinds = [s["kind"] for s in run.steps]
    assert kinds == ["navigate", "tab", "navigate"]  # the failed step, the recovery, the same step again
    assert run.steps[0]["status"] == "error" and "connection lost" in run.steps[0]["error"]
    assert run.steps[1]["title"] == "Chrome disconnected — reconnecting…" and run.steps[1]["status"] == "ok"
    assert run.steps[2]["status"] == "ok"
    notices = [e["data"]["notice"] for e in events if e["type"] == "task.status" and e["data"].get("notice")]
    assert notices == ["Resumed after Chrome reconnected."]
    assert run.to_dict()["notices"] == ["Resumed after Chrome reconnected."] and run.to_dict()["reconnects"] == 1
    assert all(e["data"].get("reconnects") in {0, 1} for e in events if e["type"] == "task.status")


async def test_recovery_happens_in_spanish_when_the_request_was_spanish(tmp_path):
    browser = FakeBrowser()
    browser.drops_left = 1
    run, bus = make_run("open example.com", browser, language="es", tmp_path=tmp_path)
    queue = bus.subscribe()
    events = await finished(run, queue)
    assert run.status == "done" and run.language == "es"
    assert run.steps[1]["title"] == "Chrome se desconectó — reconectando…"
    assert [e["data"]["notice"] for e in events if e["type"] == "task.status" and e["data"].get("notice")] == ["Reanudado tras reconectar Chrome."]
    assert run.result["markdown"].startswith("Hecho — **Page https://example.com** está abierta")
    assert all(e["data"].get("language") == "es" for e in events if e["type"] == "task.status")


async def test_a_second_drop_in_the_same_task_is_recovered_through_a_replan(tmp_path):
    browser = FakeBrowser()
    browser.drops_left = 2  # the retry after the first recovery drops again: the step fails, the plan continues after a replan
    plan = {"interpretation": "open it", "steps": [{"tool": "goto", "url": "https://example.com", "expect": {"host": ["example.com"]}}], "then": "done"}
    run, bus = make_run("open example.com", browser, llm=ScriptedLLM({"plan": lambda _user: plan}), tmp_path=tmp_path)
    queue = bus.subscribe()
    await finished(run, queue)
    assert run.status == "done", run.error
    assert run.reconnects == 2 and browser.reconnect_calls == 2
    assert [s["kind"] for s in run.steps] == ["navigate", "tab", "navigate", "plan", "navigate", "tab", "navigate"]


async def test_when_chrome_cannot_come_back_the_task_fails_honestly_with_a_code(tmp_path):
    browser = FakeBrowser()
    browser.drops_left = 1
    browser.reconnect_fails = True
    run, bus = make_run("open example.com", browser, tmp_path=tmp_path)
    queue = bus.subscribe()
    events = await finished(run, queue)
    assert run.status == "failed"
    assert run.error_code == "chrome_exited" and "could not be reconnected" in run.error and "Chrome exited" in run.error
    assert run.steps[1]["kind"] == "tab" and run.steps[1]["status"] == "error"
    assert run.result["markdown"].startswith("I couldn't complete that: Chrome disconnected")
    final = [e for e in events if e["type"] == "task.status" and e["data"]["status"] == "failed"][-1]
    assert final["data"]["error_code"] == "chrome_exited"


async def test_recoveries_are_bounded_per_task(tmp_path):
    browser = FakeBrowser()
    run, _bus = make_run("open example.com", browser, tmp_path=tmp_path)
    run.tab = await browser.new_tab()
    for _ in range(MAX_RECONNECTS):
        browser.simulate_drop()
        await run.recover_browser("reconnect")
    browser.simulate_drop()
    with pytest.raises(BrowserNotConnected) as caught:
        await run.recover_browser("reconnect")
    assert caught.value.code == "chrome_disconnected" and f"after {MAX_RECONNECTS} attempts" in str(caught.value)
    assert browser.reconnect_calls == MAX_RECONNECTS


async def test_a_closed_tab_is_reopened_without_reconnecting(tmp_path):
    browser = FakeBrowser()
    run, _bus = make_run("open example.com", browser, tmp_path=tmp_path)
    run.tab = await browser.new_tab("https://example.com/start")
    run.page = page_for("https://example.com/start")
    assert run.browser_recovery_for(CDPError("Runtime.evaluate timed out after 30s")) is None  # an ordinary protocol error is not a drop
    assert run.browser_recovery_for(ValueError("Invalid observed node")) is None
    run.tab.closed = True  # the user closed it
    assert run.browser_recovery_for(CDPError("tab is closed")) == "reopen"
    await run.recover_browser("reopen")
    assert browser.reconnect_calls == 0 and run.tab is browser.active and not run.tab.closed
    assert run.tab.url == "https://example.com/start" and run.page["url"] == "https://example.com/start"
    assert run.reconnects == 1 and run.notices == ["Resumed after Chrome reconnected."]


# Confirmations and challenges carry what the host app needs ---------------------------------------------------------------------


async def test_confirmations_carry_structured_facts_and_the_language(tmp_path):
    run, bus = make_run("comprar leche", FakeBrowser(), language="es", tmp_path=tmp_path)
    queue = bus.subscribe()
    run.set_status("running")

    async def answer() -> None:
        while run.status != "waiting_user":
            await asyncio.sleep(0.01)
        assert run.waiting["kind"] == "confirm" and run.waiting["confirm_kind"] == "purchase" and run.waiting["label"] == "Comprar"
        assert run.answer_confirmation(run.waiting["confirmation_id"], True)

    answering = asyncio.create_task(answer())
    approved = await run.confirm("purchase", "¿Continúo?", "detalle", data={"label": "Comprar", "host": "amazon.es", "url": "https://amazon.es/x", "title": "Cesta"})
    await answering
    assert approved and run.status == "running"
    request = next(e for e in [queue.get_nowait() for _ in range(queue.qsize())] if e["type"] == "confirm.request")
    assert request["data"]["kind"] == "purchase" and request["data"]["language"] == "es" and request["data"]["label"] == "Comprar"
    assert request["data"]["host"] == "amazon.es" and request["data"]["question"] == "¿Continúo?" and request["data"]["confirmation_id"]


async def test_each_repeated_challenge_prompt_has_its_own_wait_id(tmp_path):
    browser = FakeBrowser()
    run, bus = make_run("open example.com", browser, tmp_path=tmp_path)
    queue = bus.subscribe()
    run.tab = await browser.new_tab("https://x.test/")
    captcha = page_for("https://x.test/", text="Verify you are human", title="Just a moment...")
    browser.observations = [captcha, captcha, page_for("https://x.test/")]  # still blocked after the first try (and the reload), then clear

    async def user_clicks_done() -> None:
        for _ in range(2):
            while not (run.status == "waiting_user" and run._manual and not run._manual.done()):
                await asyncio.sleep(0.01)
            await asyncio.sleep(0.01)
            run.resume()

    clicker = asyncio.create_task(user_clicks_done())
    assert await asyncio.wait_for(run.handle_challenge(captcha), 10)
    await clicker
    prompts = [e["data"] for e in [queue.get_nowait() for _ in range(queue.qsize())] if e["type"] == "needs_user"]
    assert len(prompts) == 2 and prompts[0]["wait_id"] != prompts[1]["wait_id"]
    assert all(p["kind"] == "captcha" and p["language"] == "en" and p["host"] == "x.test" and "Resume" not in p["message"] for p in prompts)
    assert run.tab.reloads == 1 and run.status == "running"


async def test_the_task_dict_and_status_events_expose_language_and_codes(tmp_path):
    run, bus = make_run("open example.com", FakeBrowser(), language="es", tmp_path=tmp_path)
    queue = bus.subscribe()
    run.error, run.error_code = "x", "chrome_not_found"
    run.set_status("failed")
    event = queue.get_nowait()
    assert event["data"]["error_code"] == "chrome_not_found" and event["data"]["language"] == "es" and event["data"]["notice"] is None
    snapshot = run.to_dict()
    assert snapshot["language"] == "es" and snapshot["error_code"] == "chrome_not_found" and snapshot["reconnects"] == 0 and snapshot["notices"] == []
