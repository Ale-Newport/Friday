"""Optional speech-to-text: PCM decoding, the 501/409 contract when mlx-whisper or its model is absent, and the request
mapping onto mlx_whisper.transcribe (through a fake module, so no checkpoint is needed)."""

from __future__ import annotations

import sys
import threading
import types

import numpy as np
import pytest
from fastapi.testclient import TestClient

from jarvis import stt
from jarvis.app import App
from jarvis.server import create_app
from jarvis.settings import Secrets

TOKEN = "t" * 64
PORT = 8767
AUTH = {"Authorization": f"Bearer {TOKEN}"}
OCTETS = {**AUTH, "Content-Type": "application/octet-stream"}


@pytest.fixture
def core(tmp_path):
    secrets = Secrets()
    secrets._keyring = None
    secrets.backend = "memory"
    app = App(tmp_path / "data", downloads_dir=tmp_path / "downloads", secrets=secrets)
    yield app
    app.store.close()


@pytest.fixture
def api(core):
    return TestClient(create_app(core, TOKEN, lambda: PORT, lambda: None), base_url=f"http://127.0.0.1:{PORT}")


def pcm_bytes(seconds: float = 0.5) -> bytes:
    t = np.arange(int(seconds * stt.SAMPLE_RATE), dtype=np.float32) / stt.SAMPLE_RATE
    return (0.1 * np.sin(2 * np.pi * 440 * t)).astype("<f4").tobytes()


def test_pcm_decoding_validates_the_body():
    samples = stt.decode_pcm(pcm_bytes(0.25))
    assert samples.dtype == np.float32 and len(samples) == 4000
    for bad in (b"", b"\x00\x00\x00", b"\x00\x00\xc0\x7f", b"\x00" * (stt.MAX_SECONDS * stt.SAMPLE_RATE * 4 + 4)):
        with pytest.raises(ValueError):
            stt.decode_pcm(bad)


def test_without_mlx_whisper_everything_answers_501(api, monkeypatch):
    monkeypatch.setattr(stt, "available", lambda: False)
    status = api.get("/api/stt/status", headers=AUTH).json()
    assert status["available"] is False and status["state"] == "unavailable" and status["model"] == stt.DEFAULT_STT_MODEL
    r = api.post("/api/stt/transcribe?language=en", headers=OCTETS, content=pcm_bytes())
    assert r.status_code == 501 and r.json()["error"]["code"] == "stt_unavailable"
    r = api.post("/api/stt/download", headers=AUTH, json={})
    assert r.status_code == 501 and r.json()["error"]["code"] == "stt_unavailable"


def test_a_missing_model_is_a_409_until_downloaded(api, monkeypatch):
    monkeypatch.setattr(stt, "available", lambda: True)
    monkeypatch.setattr(stt, "cached_path", lambda repo: None)
    assert api.get("/api/stt/status", headers=AUTH).json()["state"] == "missing"
    r = api.post("/api/stt/transcribe", headers=OCTETS, content=pcm_bytes())
    assert r.status_code == 409 and r.json()["error"]["code"] == "stt_model_missing"


def test_request_validation(api, monkeypatch):
    monkeypatch.setattr(stt, "available", lambda: True)
    assert api.post("/api/stt/transcribe?language=fr", headers=OCTETS, content=pcm_bytes()).json()["error"]["code"] == "bad_language"
    assert api.post("/api/stt/transcribe", headers=AUTH, json={"audio": "x"}).status_code == 415
    assert api.post("/api/stt/transcribe", headers=OCTETS, content=b"\x00\x00\x00").json()["error"]["code"] == "bad_audio"
    assert api.post("/api/stt/transcribe", headers=OCTETS, content=b"").json()["error"]["code"] == "bad_audio"


def test_transcription_runs_on_the_mlx_thread_and_maps_the_result(api, core, monkeypatch, tmp_path):
    calls = []

    def fake_transcribe(audio, *, path_or_hf_repo, **options):
        calls.append({"n": len(audio), "dtype": str(audio.dtype), "path": path_or_hf_repo, "options": options, "thread": threading.current_thread().name})
        return {"text": "  Hello   world. ", "language": options.get("language") or "en",
                "segments": [{"id": 0, "seek": 0, "start": 0.0, "end": 0.48, "text": " Hello world. ", "tokens": [1]}]}

    monkeypatch.setitem(sys.modules, "mlx_whisper", types.SimpleNamespace(transcribe=fake_transcribe))
    monkeypatch.setattr(stt, "available", lambda: True)
    snapshot = tmp_path / "snapshot"
    snapshot.mkdir()
    (snapshot / "weights.safetensors").write_bytes(b"0" * 10)
    monkeypatch.setattr(stt, "cached_path", lambda repo: snapshot)

    assert api.get("/api/stt/status", headers=AUTH).json()["state"] == "idle"
    r = api.post("/api/stt/transcribe", headers=OCTETS, content=pcm_bytes(0.5))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["text"] == "Hello world." and body["language"] == "en" and body["segments"] == [{"start": 0.0, "end": 0.48, "text": "Hello world."}]
    assert body["latency_ms"] >= 0 and body["model"] == stt.DEFAULT_STT_MODEL
    assert calls[0]["n"] == 8000 and calls[0]["dtype"] == "float32" and calls[0]["path"] == str(snapshot)
    assert "language" not in calls[0]["options"] and calls[0]["options"]["task"] == "transcribe"  # auto-detect by default
    assert calls[0]["thread"].startswith("laya")  # the one MLX thread in the process

    es = api.post("/api/stt/transcribe?language=es&model=mlx-community/whisper-small", headers=OCTETS, content=pcm_bytes(0.1)).json()
    assert es["language"] == "es" and es["model"] == "mlx-community/whisper-small" and calls[1]["options"]["language"] == "es"
    status = api.get("/api/stt/status", headers=AUTH).json()
    assert status["loaded"] == "mlx-community/whisper-small" and status["last_latency_ms"] >= 0 and status["size_bytes"] == 10
