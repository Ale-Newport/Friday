"""A second opinion on doubtful transcripts with faster-whisper (CTranslate2, int8 on the CPU).

Apple's on-device recogniser streams and finishes ~0.13 s after the user stops talking, and is right almost always;
when it is not, it says so (its confidence drops below ~0.8: "de asiciete, por venti cuatro", "But..." for "¡Para!").
The app sends only those utterances here. Whisper small (int8) transcribes a 2-3 s command in ~0.65 s on an M2 Max
and got every one of the test commands right, numbers included.

The model (Systran/faster-whisper-small, ~480 MB) is downloaded from Hugging Face on first use and kept in the HF
cache; `warm()` does that in the background at start-up so no command waits for it. It runs on the CPU on its own
thread, so it never competes with Laya (MLX) or a local LLM (Metal). When faster-whisper is not installed every call
raises `FastSttUnavailable` and the app keeps Apple's transcript.
"""

from __future__ import annotations

import asyncio
import importlib.util
import logging
import threading
import time
from typing import Any

log = logging.getLogger("jarvis.fast_stt")

MODEL = "small"
LANGUAGES = {"auto", "en", "es"}


class FastSttUnavailable(RuntimeError):
    pass


def available() -> bool:
    try:
        return importlib.util.find_spec("faster_whisper") is not None
    except (ImportError, ValueError):
        return False


class FastStt:
    def __init__(self, model: str = MODEL, threads: int = 4) -> None:
        self._model_name = model
        self._threads = threads
        self._model: Any = None
        self._lock = threading.Lock()
        self._loading: asyncio.Task | None = None
        self.error: str | None = None

    def _load(self) -> Any:
        with self._lock:
            if self._model is None:
                from faster_whisper import WhisperModel

                started = time.perf_counter()
                self._model = WhisperModel(self._model_name, device="cpu", compute_type="int8", cpu_threads=self._threads)
                log.info("faster-whisper %s ready in %.1f s", self._model_name, time.perf_counter() - started)
            return self._model

    def status(self) -> dict[str, Any]:
        return {"available": available(), "model": self._model_name, "loaded": self._model is not None, "error": self.error}

    async def warm(self) -> None:
        """Downloads (first time) and loads the model in the background."""
        if not available() or self._model is not None:
            return
        try:
            await asyncio.to_thread(self._load)
            self.error = None
        except Exception as error:  # noqa: BLE001 - offline on first use, disk full…: reported in status
            self.error = f"{type(error).__name__}: {error}"
            log.warning("faster-whisper could not load: %s", self.error)

    async def transcribe(self, pcm: Any, language: str = "auto") -> dict[str, Any]:
        if not available():
            raise FastSttUnavailable("faster-whisper is not installed in the sidecar environment.")
        started = time.perf_counter()

        def work() -> dict[str, Any]:
            model = self._load()
            options = {"beam_size": 1, "vad_filter": False, "condition_on_previous_text": False, "without_timestamps": True}
            segments, info = model.transcribe(pcm, language=None if language == "auto" else language, **options)
            parts = list(segments)
            if language == "auto" and info.language not in ("en", "es"):
                # The user speaks Spanish or English: a short command "detected" as Portuguese or Galician is the
                # nearer of the two, transcribed again in it.
                probs = dict(info.all_language_probs or [])
                nearer = "es" if probs.get("es", 0) >= probs.get("en", 0) else "en"
                segments, info = model.transcribe(pcm, language=nearer, **options)
                parts = list(segments)
            text = " ".join(segment.text.strip() for segment in parts).strip()
            logprob = sum(segment.avg_logprob for segment in parts) / len(parts) if parts else None
            no_speech = max((segment.no_speech_prob for segment in parts), default=1.0)
            return {"text": text, "language": info.language, "avg_logprob": logprob, "no_speech_prob": no_speech}

        try:
            result = await asyncio.to_thread(work)
        except FastSttUnavailable:
            raise
        except Exception as error:  # noqa: BLE001 - the app falls back to Apple's transcript
            raise FastSttUnavailable(f"{type(error).__name__}: {error}") from error
        result["latency_ms"] = int((time.perf_counter() - started) * 1000)
        return result
