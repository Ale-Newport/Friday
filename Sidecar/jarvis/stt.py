"""Optional on-device speech-to-text with mlx-whisper (`uv sync --extra whisper`).

Nothing here imports mlx_whisper at module load: when the package is absent every endpoint answers 501 `stt_unavailable`
and the rest of the sidecar is untouched. Transcription runs on the Laya worker thread (the one MLX thread in the
process), and mlx_whisper keeps the last loaded model in memory, so only the first request pays the load.
"""

from __future__ import annotations

import asyncio
import importlib.util
import logging
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .laya_engine import LayaEngine, cached_path, check_support, folder_size

log = logging.getLogger("jarvis.stt")

DEFAULT_STT_MODEL = "mlx-community/whisper-large-v3-turbo"
SAMPLE_RATE = 16_000
MAX_SECONDS = 600
LANGUAGES = {"auto", "en", "es"}


class SttUnavailable(RuntimeError):
    """mlx-whisper is not installed (or MLX cannot run here)."""


class SttModelMissing(RuntimeError):
    """The Whisper checkpoint is not in the Hugging Face cache."""


def available() -> bool:
    try:
        return importlib.util.find_spec("mlx_whisper") is not None
    except (ImportError, ValueError):
        return False


class SttEngine:
    def __init__(self, laya: LayaEngine, model: str = DEFAULT_STT_MODEL, emit: Callable[[str, dict], Any] | None = None):
        self.laya = laya  # owns the single MLX worker thread
        self.model = model
        self.emit = emit
        self.loaded_model: str | None = None
        self.load_ms: int | None = None
        self.last_latency_ms: int | None = None
        self.error: str | None = None
        self._download_task: asyncio.Task | None = None
        self._busy = asyncio.Lock()

    # Status -----------------------------------------------------------------------------------------------------------

    def state(self) -> str:
        if not available():
            return "unavailable"
        if not check_support()[0]:
            return "unsupported"
        if self._download_task and not self._download_task.done():
            return "downloading"
        if self.error:
            return "error"
        if cached_path(self.model) is None:
            return "missing"
        if self._busy.locked():
            return "busy"
        return "ready" if self.loaded_model == self.model else "idle"

    def status(self) -> dict[str, Any]:
        path = cached_path(self.model) if available() else None
        return {
            "available": available(),
            "model": self.model,
            "downloaded": path is not None,
            "size_bytes": folder_size(path),
            "state": self.state(),
            "loaded": self.loaded_model,
            "load_ms": self.load_ms,
            "last_latency_ms": self.last_latency_ms,
            "error": self.error,
        }

    async def _publish(self) -> None:
        if self.emit:
            result = self.emit("stt.status", self.status())
            if asyncio.iscoroutine(result):
                await result

    # Download ---------------------------------------------------------------------------------------------------------

    async def download(self, model: str | None = None) -> dict[str, Any]:
        if not available():
            raise SttUnavailable("mlx-whisper is not installed in the sidecar environment.")
        if model and model != self.model:
            self.model, self.loaded_model = model, None
        if self._download_task and not self._download_task.done():
            return self.status()
        self.error = None
        self._download_task = asyncio.create_task(self._download(), name="stt-download")
        await self._publish()
        return self.status()

    async def _download(self) -> None:
        loop = asyncio.get_running_loop()
        bars: dict[int, list[float]] = {}
        last_emit = 0.0
        emit = self.emit
        repo = self.model

        def report(done: bool = False, file: str = "") -> None:
            nonlocal last_emit
            now = time.monotonic()
            if not done and now - last_emit < 0.25:
                return
            last_emit = now
            got = sum(b[0] for b in bars.values())
            total = sum(b[1] for b in bars.values())
            if emit:
                loop.call_soon_threadsafe(
                    lambda: asyncio.ensure_future(_maybe(emit("stt.download", {"model": repo, "bytes": int(got), "total": int(total), "file": file, "done": done})))
                )

        from tqdm.auto import tqdm

        class Progress(tqdm):  # type: ignore[misc]
            def __init__(self, *args: Any, **kwargs: Any):
                kwargs.pop("name", None)
                super().__init__(*args, **kwargs)
                if getattr(self, "unit", "") == "B":
                    bars[id(self)] = [0, self.total or 0]

            def update(self, n: float | None = 1) -> bool | None:
                result = super().update(n)
                if id(self) in bars:
                    bars[id(self)] = [self.n, self.total or 0]
                    report(file=str(self.desc or ""))
                return result

        def work() -> str:
            from huggingface_hub import snapshot_download

            return snapshot_download(repo, tqdm_class=Progress)

        try:
            await asyncio.to_thread(work)
            report(done=True)
        except Exception as error:
            log.warning("Whisper download failed: %s", error)
            self.error = f"Download failed: {error}"
            report(done=True)
        await self._publish()

    # Transcription ----------------------------------------------------------------------------------------------------

    async def transcribe(self, pcm: Any, *, language: str = "auto", model: str | None = None) -> dict[str, Any]:
        """`pcm`: float32 mono samples at 16 kHz (a numpy array). Runs on the Laya thread; one request at a time."""
        if not available():
            raise SttUnavailable("mlx-whisper is not installed in the sidecar environment.")
        supported, reason = check_support()
        if not supported:
            raise SttUnavailable(reason)
        repo = model or self.model
        path = cached_path(repo)
        if path is None:
            raise SttModelMissing(f"The speech model {repo} is not downloaded yet. POST /api/stt/download first.")
        lang = None if language in {"", "auto"} else language
        async with self._busy:
            started = time.perf_counter()
            first_load = self.loaded_model != repo
            result = await self.laya.run(self._transcribe, path, pcm, lang)
            ms = round((time.perf_counter() - started) * 1000)
            if first_load:
                self.loaded_model, self.load_ms = repo, ms
            self.last_latency_ms = ms
        segments = [{"start": round(float(s.get("start", 0.0)), 2), "end": round(float(s.get("end", 0.0)), 2), "text": str(s.get("text", "")).strip()}
                    for s in result.get("segments", [])]
        text = " ".join(str(result.get("text", "")).split())
        detected = str(result.get("language") or lang or "")
        log.info("stt: %.1fs of audio -> %d chars in %d ms (%s, %s)", len(pcm) / SAMPLE_RATE, len(text), ms, repo, detected or "language unknown")
        return {"text": text, "language": detected, "segments": segments, "latency_ms": ms, "model": repo}

    @staticmethod
    def _transcribe(path: Path, pcm: Any, language: str | None) -> dict[str, Any]:
        """Synchronous; call only from the Laya thread (`laya.run`)."""
        import numpy as np

        audio = np.ascontiguousarray(pcm, dtype=np.float32)
        options: dict[str, Any] = {"task": "transcribe", "fp16": True, "verbose": None}
        if language:
            options["language"] = language
        import mlx_whisper

        return mlx_whisper.transcribe(audio, path_or_hf_repo=str(path), **options)


def decode_pcm(body: bytes) -> Any:
    """Raw little-endian float32 mono PCM at 16 kHz -> numpy array. Raises ValueError for unusable input."""
    import numpy as np

    if not body:
        raise ValueError("The request body is empty; send raw float32 PCM samples.")
    if len(body) % 4:
        raise ValueError("The body length is not a multiple of 4 bytes; expected little-endian float32 samples.")
    if len(body) > MAX_SECONDS * SAMPLE_RATE * 4:
        raise ValueError(f"Audio longer than {MAX_SECONDS} seconds is not accepted.")
    samples = np.frombuffer(body, dtype="<f4")
    if not np.all(np.isfinite(samples)):
        raise ValueError("The samples contain NaN or infinite values.")
    return samples


async def _maybe(value: Any) -> None:
    if asyncio.iscoroutine(value):
        await value
