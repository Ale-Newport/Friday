"""Voice-command routing for Friday: a deterministic bilingual keyword pre-pass, then one Laya `system_one` call.

The Laya call asks four questions at once (one `choice` over at most ten categories plus three `noul`s) so the whole
route costs a single forward pass on the Laya thread. Ten options keep the choice in the checkpoint's calibrated
`choice:6-10` temperature bucket; the `choice:11+` bucket is clamped and sharpened, so never ask more.
"""

from __future__ import annotations

import logging
import re
import time
import unicodedata
from typing import Any

from .laya_engine import LayaEngine, LayaUnavailable

log = logging.getLogger("jarvis.route")

MAX_CATEGORIES = 10
RULE_CONFIDENCE = 0.9

# Each description is rendered into the Laya prompt ("label: description"), so keep them short (well under 48 tokens).
DEFAULT_CATEGORIES: list[dict[str, str]] = [
    {"id": "music", "description": "play, pause, skip, volume of music, songs, playlists, artists"},
    {"id": "reminders", "description": "to-do items, reminders, lists, tasks, groceries"},
    {"id": "notes", "description": "Apple Notes: create, find, read, edit, append notes"},
    {"id": "calendar", "description": "events, meetings, appointments, schedule, availability"},
    {"id": "browser", "description": "web browsing, search the internet, websites, online shopping, flights, YouTube, downloads from the web"},
    {"id": "files", "description": "local files and folders, documents, Finder, Downloads, rename, move, convert"},
    {"id": "system", "description": "Mac controls: open/close apps, windows, volume, brightness, screen, clipboard, settings, screenshots"},
    {"id": "communication", "description": "email, mail, messages, contacts, send or read messages"},
    {"id": "information", "description": "questions, facts, weather, calculations, conversions, translations, definitions, time, general conversation"},
    {"id": "clock", "description": "timers, alarms, stopwatch, countdowns"},
]

QUESTIONS = {
    "multistep": "Does the request require more than one distinct action or a conditional/sequence?",
    "dangerous": "Would carrying this out delete data, send a message/email, spend money, or change security settings?",
    "question": "Is this a question to answer rather than a command to perform?",
}

# Bilingual keywords (English + Spanish). Matching is case- and accent-insensitive on word boundaries, so "Recuérdame"
# and "recuerdame" both hit. When the words of a request name exactly one category, that category wins without Laya.
KEYWORDS: dict[str, tuple[str, ...]] = {
    "music": ("play", "pon", "musica", "cancion", "canciones", "playlist", "playlists", "song", "songs", "spotify", "pause", "pausa", "skip"),
    "reminders": ("reminder", "reminders", "remind", "recuerdame", "recordatorio", "recordatorios", "recuerda"),
    "notes": ("note", "notes", "nota", "notas", "apunta"),
    "clock": ("timer", "timers", "temporizador", "alarma", "alarmas", "alarm", "alarms", "stopwatch", "cronometro"),
    "communication": ("email", "emails", "correo", "correos", "mail", "mensaje", "mensajes", "whatsapp", "imessage", "sms"),
    "browser": ("search", "busca", "google", "website", "websites", "web", "chrome", "safari", "youtube", "flight", "flights", "vuelo", "vuelos",
                "internet", "online", "url", "link", "page", "pagina", "dot com", "http", "https"),
    "files": ("file", "files", "archivo", "archivos", "carpeta", "carpetas", "folder", "folders", "download", "downloads", "descarga", "descargas",
              "rename", "renombra"),
    "system": ("volume", "volumen", "brightness", "brillo", "open", "abre", "close", "cierra", "window", "ventana", "screenshot", "captura"),
    "information": ("weather", "tiempo", "clima", "calculate", "calcula", "cuanto", "cuanta", "cuantos", "cuantas", "what is", "what's", "whats",
                    "que es", "traduce", "translate", "define"),
    "calendar": ("event", "events", "evento", "eventos", "meeting", "meetings", "reunion", "calendar", "calendario", "cita", "citas", "agenda"),
}


# Patterns that are not plain words: a domain name such as github.com names the browser.
EXTRA_PATTERNS: dict[str, str] = {"browser": r"\b[a-z0-9-]+\.(?:com|org|net|es|io|dev|app|co\.uk)\b"}


class RouteError(ValueError):
    """The request body is not usable (bad text or category list)."""


def normalize(text: str) -> str:
    """Lower-case, accent-stripped, apostrophes unified, whitespace collapsed."""
    decomposed = unicodedata.normalize("NFKD", text.replace("’", "'"))
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    return " ".join(stripped.casefold().split())


def _pattern(category: str, words: tuple[str, ...]) -> re.Pattern[str]:
    alternatives = [re.escape(normalize(w)) for w in sorted(words, key=len, reverse=True)]
    word_pattern = rf"(?<!\w)(?:{'|'.join(alternatives)})(?!\w)"
    extra = EXTRA_PATTERNS.get(category)
    return re.compile(f"(?:{word_pattern})|(?:{extra})" if extra else word_pattern)


PATTERNS: dict[str, re.Pattern[str]] = {category: _pattern(category, words) for category, words in KEYWORDS.items()}


def keyword_matches(text: str, allowed: set[str] | None = None) -> dict[str, list[str]]:
    """Category -> matched keywords, for the categories whose keywords appear in `text`."""
    normalized = normalize(text)
    found: dict[str, list[str]] = {}
    for category, pattern in PATTERNS.items():
        if allowed is not None and category not in allowed:
            continue
        hits = pattern.findall(normalized)
        if hits:
            found[category] = sorted(set(hits))
    return found


def route_by_rules(text: str, allowed: set[str] | None = None) -> tuple[str, list[str]] | None:
    """The single category named by the request's keywords, or None when zero or several categories match."""
    found = keyword_matches(text, allowed)
    if len(found) == 1:
        return next(iter(found.items()))
    return None


def check_categories(categories: Any) -> list[dict[str, str]]:
    if categories is None:
        return DEFAULT_CATEGORIES
    if not isinstance(categories, list) or not 2 <= len(categories) <= MAX_CATEGORIES:
        raise RouteError(f"categories must be a list of 2 to {MAX_CATEGORIES} entries.")
    out: list[dict[str, str]] = []
    seen: set[str] = set()
    for entry in categories:
        if not isinstance(entry, dict):
            raise RouteError("Each category must be an object with id and description.")
        id_ = str(entry.get("id", "")).strip()
        description = str(entry.get("description", "")).strip()
        if not id_ or len(id_) > 40 or not description or len(description) > 200:
            raise RouteError("Each category needs a short id (up to 40 characters) and a description (up to 200 characters).")
        if id_ in seen:
            raise RouteError(f"Duplicate category id {id_!r}.")
        seen.add(id_)
        out.append({"id": id_, "description": description})
    return out


def check_context(context: Any) -> dict[str, Any]:
    if context is None:
        return {}
    if not isinstance(context, dict):
        raise RouteError("context must be an object.")
    out: dict[str, Any] = {}
    for key in ("frontmost_app", "browser_tab"):
        if context.get(key):
            out[key] = " ".join(str(context[key]).split())[:200]
    if "has_selection" in context and context["has_selection"] is not None:
        out["has_selection"] = bool(context["has_selection"])
    conversation = context.get("conversation")
    if conversation:
        if not isinstance(conversation, list):
            raise RouteError("context.conversation must be a list of strings.")
        out["conversation"] = [" ".join(str(turn).split())[:300] for turn in conversation[-4:] if str(turn).strip()]
    return out


def build_state(text: str, language: str | None, context: dict[str, Any]) -> str:
    lines = [f"Request: {text}", f"Language: {language or 'unknown'}"]
    if context.get("frontmost_app"):
        lines.append(f"Frontmost app: {context['frontmost_app']}")
    if "has_selection" in context:
        lines.append(f"Text selected: {'yes' if context['has_selection'] else 'no'}")
    if context.get("browser_tab"):
        lines.append(f"Browser tab: {context['browser_tab']}")
    if context.get("conversation"):
        lines.append("Recent conversation:")
        lines.extend(f"- {turn}" for turn in context["conversation"])
    return "\n".join(lines)


def build_questions(categories: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "category": {
            "type": "choice",
            "instructions": "Which category should handle the user's voice request?",
            "criteria": {c["id"]: c["description"] for c in categories},
        },
        **{qid: {"type": "noul", "instructions": instructions} for qid, instructions in QUESTIONS.items()},
    }


def answer_summary(result: dict[str, Any]) -> dict[str, Any]:
    """Flatten a `system_one` result for the route questions into the /api/route shape."""
    answers = result["answers"]
    category = answers["category"]
    return {
        "category": category["choice"],
        "confidence": float(category.get("answer_confidence", max(category["probabilities"].values()))),
        "probabilities": {k: float(v) for k, v in category["probabilities"].items()},
        "multistep": float(answers["multistep"]["noul"]),
        "dangerous": float(answers["dangerous"]["noul"]),
        "question": float(answers["question"]["noul"]),
    }


class Router:
    def __init__(self, engine: LayaEngine):
        self.engine = engine
        self.warmed = False

    async def decide(self, state: Any, questions: dict[str, Any], *, min_confidence: Any = None) -> dict[str, Any]:
        """Generic typed decision: `system_one` on the Laya thread, plus the wall-clock latency."""
        await self.engine.ensure_loaded()
        started = time.perf_counter()
        result = await self.engine.run(self.engine.system_one, state, questions, min_confidence=min_confidence)
        result["latency_ms"] = round((time.perf_counter() - started) * 1000)
        return result

    async def warm(self) -> None:
        """One call with the production question shape so the first real route does not pay for kernel compilation."""
        if self.warmed:
            return
        try:
            result = await self.decide(build_state("warm up", "en", {}), build_questions(DEFAULT_CATEGORIES))
        except LayaUnavailable:
            return
        self.warmed = True
        log.info("route warm-up: %d ms", result["latency_ms"])

    async def route(self, text: str, *, language: str | None = None, context: dict[str, Any] | None = None,
                    categories: list[dict[str, str]] | None = None) -> dict[str, Any]:
        started = time.perf_counter()
        categories = categories or DEFAULT_CATEGORIES
        allowed = {c["id"] for c in categories}
        ruled = route_by_rules(text, allowed)
        if ruled:
            category, words = ruled
            ms = round((time.perf_counter() - started) * 1000)
            log.info("route %r -> %s (rules: %s) in %d ms", text[:80], category, ", ".join(words), ms)
            return {"category": category, "confidence": RULE_CONFIDENCE, "probabilities": {category: RULE_CONFIDENCE},
                    "multistep": None, "dangerous": None, "question": None, "latency_ms": ms, "model": "rules", "source": "rules"}
        state = build_state(text, language, context or {})
        try:
            result = await self.decide(state, build_questions(categories))
        except LayaUnavailable as error:
            ms = round((time.perf_counter() - started) * 1000)
            log.warning("route %r: Laya unavailable (%s); no rule matched", text[:80], error)
            return {"category": "unknown", "confidence": 0.0, "probabilities": {}, "multistep": None, "dangerous": None, "question": None,
                    "latency_ms": ms, "model": None, "source": "none", "error": str(error)}
        summary = answer_summary(result)
        ms = round((time.perf_counter() - started) * 1000)
        log.info("route %r -> %s p=%.2f (laya %d ms, total %d ms; multistep %.2f dangerous %.2f question %.2f)", text[:80], summary["category"],
                 summary["confidence"], result["latency_ms"], ms, summary["multistep"], summary["dangerous"], summary["question"])
        return {**summary, "latency_ms": ms, "model": self.engine.model_name, "source": "laya"}
