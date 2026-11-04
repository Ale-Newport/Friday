"""Voice-command routing: the bilingual keyword pre-pass (no model), the Laya question shape, and the real model through
/api/route (marked `laya`; skipped when the checkpoint is not downloaded)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from jarvis.app import App
from jarvis.laya_engine import DEFAULT_MODEL, LayaUnavailable, cached_path, check_support
from jarvis.routing import (
    DEFAULT_CATEGORIES,
    MAX_CATEGORIES,
    RouteError,
    Router,
    answer_summary,
    build_questions,
    build_state,
    check_categories,
    check_context,
    keyword_matches,
    route_by_rules,
)
from jarvis.server import create_app
from jarvis.settings import Secrets

TOKEN = "t" * 64
PORT = 8766
AUTH = {"Authorization": f"Bearer {TOKEN}"}


# Rules -------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "category"),
    [
        ("play some jazz", "music"),
        ("Pon música de jazz", "music"),
        ("recuérdame comprar leche mañana", "reminders"),
        ("recuerdame comprar leche manana", "reminders"),
        ("remind me to call mom at six", "reminders"),
        ("take a note: buy milk and eggs", "notes"),
        ("apunta que tengo que llamar al dentista", "notes"),
        ("set a timer for ten minutes", "clock"),
        ("ponme una alarma a las siete", "clock"),
        ("send an email to Anna", "communication"),
        ("mándale un mensaje a Pedro", "communication"),
        ("search for cheap flights to Madrid", "browser"),
        ("busca vuelos baratos a Madrid", "browser"),
        ("rename the file report.pdf", "files"),
        ("mueve el archivo a la carpeta de proyectos", "files"),
        ("turn the volume down", "system"),
        ("sube el brillo", "system"),
        ("close the window", "system"),
        ("what is 18 percent of 240", "information"),
        ("qué es la fotosíntesis", "information"),
        ("what's the weather like", "information"),
        ("schedule a meeting with Laura on Friday", "calendar"),
        ("¿tengo alguna reunión mañana?", "calendar"),
    ],
)
def test_single_category_keywords_route_without_the_model(text, category):
    ruled = route_by_rules(text)
    assert ruled is not None and ruled[0] == category and ruled[1]


@pytest.mark.parametrize(
    "text",
    ["turn on dark mode", "text Anna that I'm running late", "how tall is the Eiffel tower", "open github.com", "what's on my calendar tomorrow",
     "open the notes app", "¿cuánto tiempo queda en el temporizador?", "download the song and email it to me"],
)
def test_ambiguous_or_keyword_free_requests_are_left_to_the_model(text):
    assert route_by_rules(text) is None


def test_keyword_matching_is_accent_and_case_insensitive_and_word_bounded():
    assert keyword_matches("RECUÉRDAME") == {"reminders": ["recuerdame"]}
    assert keyword_matches("the website is slow") == {"browser": ["website"]}
    assert keyword_matches("webinar replay") == {}  # "web"/"play" only match whole words
    assert keyword_matches("open github.com", allowed={"browser"}) == {"browser": ["github.com"]}
    assert route_by_rules("open github.com", allowed={"browser"}) == ("browser", ["github.com"])


# Laya question shape -----------------------------------------------------------------------------------------------------


def test_default_categories_fit_the_calibrated_choice_bucket():
    assert 2 <= len(DEFAULT_CATEGORIES) <= MAX_CATEGORIES == 10
    assert [c["id"] for c in DEFAULT_CATEGORIES] == ["music", "reminders", "notes", "calendar", "browser", "files", "system", "communication", "information", "clock"]
    assert all(len(c["description"].split()) <= 20 for c in DEFAULT_CATEGORIES)
    questions = build_questions(DEFAULT_CATEGORIES)
    assert questions["category"]["type"] == "choice" and set(questions["category"]["criteria"]) == {c["id"] for c in DEFAULT_CATEGORIES}
    assert all(questions[q]["type"] == "noul" and questions[q]["instructions"].endswith("?") for q in ("multistep", "dangerous", "question"))


def test_state_lists_the_request_language_and_context():
    assert build_state("play jazz", None, {}) == "Request: play jazz\nLanguage: unknown"
    state = build_state("hi", "es", check_context({"frontmost_app": "Safari", "has_selection": True, "browser_tab": "GitHub", "conversation": ["a", "b", "c", "d", "e"]}))
    assert state.splitlines() == ["Request: hi", "Language: es", "Frontmost app: Safari", "Text selected: yes", "Browser tab: GitHub", "Recent conversation:",
                                  "- b", "- c", "- d", "- e"]


def test_category_and_context_validation():
    assert check_categories(None) is DEFAULT_CATEGORIES
    assert check_categories([{"id": "a", "description": "x"}, {"id": "b", "description": "y"}]) == [{"id": "a", "description": "x"}, {"id": "b", "description": "y"}]
    for bad in ([], [{"id": "a", "description": "x"}], [{"id": "a", "description": "x"}] * 2, [{"id": f"c{i}", "description": "d"} for i in range(11)],
                [{"id": "", "description": "x"}, {"id": "b", "description": "y"}], ["a", "b"]):
        with pytest.raises(RouteError):
            check_categories(bad)
    with pytest.raises(RouteError):
        check_context("nope")
    assert check_context(None) == {} and check_context({"has_selection": None}) == {}


class ScriptedEngine:
    """Stands in for LayaEngine: a fixed system_one answer, or LayaUnavailable."""

    model_name = "scripted"

    def __init__(self, answers=None):
        self.answers = answers
        self.calls = []

    async def ensure_loaded(self):
        if self.answers is None:
            raise LayaUnavailable("not here")

    async def run(self, fn, *args, **kwargs):
        return fn(*args, **kwargs)

    def system_one(self, state, questions, *, min_confidence=None):
        self.calls.append((state, questions, min_confidence))
        return {"model": "laya-rl-agent", "answers": self.answers, "usage": {}}


ANSWERS = {
    "category": {"type": "choice", "choice": "system", "probabilities": {"system": 0.7, "browser": 0.2, "music": 0.1}, "confidence": 0.5, "answer_confidence": 0.7},
    "multistep": {"type": "noul", "noul": 0.1, "confidence": 0.9, "answer_confidence": 0.9},
    "dangerous": {"type": "noul", "noul": 0.2, "confidence": 0.8, "answer_confidence": 0.8},
    "question": {"type": "noul", "noul": 0.05, "confidence": 0.95, "answer_confidence": 0.95},
}


async def test_router_prefers_rules_then_laya_then_reports_unknown():
    engine = ScriptedEngine(ANSWERS)
    router = Router(engine)
    ruled = await router.route("play some jazz")
    assert ruled["category"] == "music" and ruled["confidence"] == 0.9 and ruled["source"] == "rules" and engine.calls == []
    assert ruled["multistep"] is None and ruled["dangerous"] is None and ruled["question"] is None and ruled["latency_ms"] >= 0

    decided = await router.route("turn on dark mode", language="en", context={"frontmost_app": "Finder"})
    assert decided["source"] == "laya" and decided["category"] == "system" and decided["confidence"] == 0.7
    assert decided["probabilities"] == {"system": 0.7, "browser": 0.2, "music": 0.1}
    assert (decided["multistep"], decided["dangerous"], decided["question"]) == (0.1, 0.2, 0.05) and decided["model"] == "scripted"
    state, questions, min_confidence = engine.calls[0]
    assert state == "Request: turn on dark mode\nLanguage: en\nFrontmost app: Finder" and set(questions) == {"category", "multistep", "dangerous", "question"}
    assert min_confidence is None

    unknown = await Router(ScriptedEngine(None)).route("turn on dark mode")
    assert unknown["category"] == "unknown" and unknown["confidence"] == 0 and unknown["source"] == "none" and unknown["probabilities"] == {}
    assert answer_summary({"answers": ANSWERS})["category"] == "system"


async def test_decide_forwards_min_confidence_and_measures_latency():
    engine = ScriptedEngine(ANSWERS)
    result = await Router(engine).decide({"request": "x"}, {"q": {"type": "noul", "instructions": "?"}}, min_confidence=0.5)
    assert result["answers"] is ANSWERS and result["latency_ms"] >= 0 and engine.calls[0][2] == 0.5


# The real model ----------------------------------------------------------------------------------------------------------


@pytest.fixture(scope="module")
def laya_api(tmp_path_factory):
    supported, reason = check_support()
    if not supported:
        pytest.skip(reason)
    if cached_path(DEFAULT_MODEL) is None:
        pytest.skip("the Laya checkpoint is not downloaded")
    secrets = Secrets()
    secrets._keyring = None
    secrets.backend = "memory"
    root = tmp_path_factory.mktemp("route")
    core = App(root / "data", downloads_dir=root / "dl", secrets=secrets)
    client = TestClient(create_app(core, TOKEN, lambda: PORT, lambda: None), base_url=f"http://127.0.0.1:{PORT}")
    status = client.post("/api/laya/load", headers=AUTH).json()
    assert status["state"] == "ready", status
    yield client
    core.store.close()


@pytest.mark.laya
def test_route_through_the_real_model(laya_api):
    categories = laya_api.get("/api/route/categories", headers=AUTH).json()["categories"]
    assert [c["id"] for c in categories] == [c["id"] for c in DEFAULT_CATEGORIES]

    expectations = {
        "what's on my calendar tomorrow": "calendar",
        "text Anna that I'm running late": "communication",
        "turn on dark mode": "system",
        "how tall is the Eiffel tower": "information",
    }
    results = {}
    for text, expected in expectations.items():
        for _ in range(2):  # the first call of a new question shape may compile kernels; measure the second
            r = laya_api.post("/api/route", headers=AUTH, json={"text": text, "language": "en"})
        assert r.status_code == 200, r.text
        body = r.json()
        results[text] = body
        assert body["source"] == "laya" and body["model"] == DEFAULT_MODEL
        assert set(body["probabilities"]) == set(expectations.values()) | {"music", "reminders", "notes", "browser", "files", "clock"}
        assert abs(sum(body["probabilities"].values()) - 1) < 0.02 and body["probabilities"][body["category"]] == max(body["probabilities"].values())
        assert body["confidence"] == pytest.approx(body["probabilities"][body["category"]])
        assert all(0 <= body[q] <= 1 for q in ("multistep", "dangerous", "question"))
        assert body["category"] == expected, (text, body)
        assert body["latency_ms"] < 1000, body["latency_ms"]
    print({t: (b["category"], round(b["confidence"], 2), b["latency_ms"], {q: round(b[q], 2) for q in ("multistep", "dangerous", "question")}) for t, b in results.items()})

    # rules win without touching the model, in both languages
    for text, expected in (("play some jazz", "music"), ("recuérdame comprar leche mañana", "reminders")):
        body = laya_api.post("/api/route", headers=AUTH, json={"text": text}).json()
        assert body["category"] == expected and body["source"] == "rules" and body["confidence"] == 0.9

    # the generic endpoint returns the raw laya_mlx payload
    raw = laya_api.post("/api/laya/decide", headers=AUTH, json={
        "state": {"request": "delete every photo from last year"},
        "questions": {"risky": {"type": "noul", "instructions": "Would this destroy data?"},
                      "kind": {"type": "choice", "instructions": "What kind of request?", "criteria": ["command", "question"]}},
        "min_confidence": 0.3,
    }).json()
    assert raw["model"] == "laya-rl-agent" and raw["answers"]["kind"]["choice"] == "command" and 0 <= raw["answers"]["risky"]["noul"] <= 1
    assert raw["answers"]["kind"]["abstention"] in {"passed", "abstained"} and raw["latency_ms"] >= 0 and "usage" in raw
    bad = laya_api.post("/api/laya/decide", headers=AUTH, json={"state": "x", "questions": {"q": {"type": "number", "instructions": "?"}}})
    assert bad.status_code == 400 and bad.json()["error"]["code"] == "bad_question"
