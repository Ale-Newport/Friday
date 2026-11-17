"""Online neural voice endpoints: validation, the app-facing contract, and the SSML that reaches the service."""

import base64

import pytest
from fastapi.testclient import TestClient

from jarvis import neural_tts
from jarvis.app import App
from jarvis.server import create_app
from jarvis.settings import Secrets

TOKEN = "t" * 64
PORT = 8765
BASE = f"http://127.0.0.1:{PORT}"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


@pytest.fixture
def api(tmp_path, monkeypatch):
    calls = []

    async def fake_synthesize(self, text, voice, rate=0, pitch=0):
        calls.append((text, voice, rate, pitch))
        if voice == "broken":
            raise neural_tts.NeuralTTSError("unknown voice")
        return b"ID3fake-mp3"

    async def fake_warm(self):
        return 2

    monkeypatch.setattr(neural_tts.NeuralVoice, "synthesize", fake_synthesize)
    monkeypatch.setattr(neural_tts.NeuralVoice, "warm", fake_warm)
    secrets = Secrets()
    secrets._keyring = None
    secrets.backend = "memory"
    core = App(tmp_path / "data", downloads_dir=tmp_path / "downloads", secrets=secrets)
    client = TestClient(create_app(core, TOKEN, lambda: PORT), base_url=BASE)
    client.calls = calls
    return client


def test_synthesize_returns_base64_audio(api):
    response = api.post("/api/tts/synthesize", json={"text": "Hola, soy Jarvis.", "voice": "es-ES-AlvaroNeural", "rate": 10}, headers=AUTH)
    assert response.status_code == 200
    body = response.json()
    assert body["format"] == "mp3" and base64.b64decode(body["audio"]) == b"ID3fake-mp3"
    assert api.calls == [("Hola, soy Jarvis.", "es-ES-AlvaroNeural", 10, 0)]


def test_synthesize_validates_and_reports_service_failures(api):
    assert api.post("/api/tts/synthesize", json={"text": "", "voice": "x"}, headers=AUTH).status_code == 400
    assert api.post("/api/tts/synthesize", json={"text": "hola"}, headers=AUTH).status_code == 400
    assert api.post("/api/tts/synthesize", json={"text": "hola", "voice": "x", "rate": "fast"}, headers=AUTH).status_code == 400
    failed = api.post("/api/tts/synthesize", json={"text": "hola", "voice": "broken"}, headers=AUTH)
    assert failed.status_code == 503 and failed.json()["error"]["code"] == "tts_unavailable"
    assert api.post("/api/tts/synthesize", json={"text": "hola", "voice": "x"}).status_code == 401


def test_warm_and_voices(api):
    assert api.post("/api/tts/warm", headers=AUTH).json() == {"ready": 2}
    voices = api.get("/api/tts/voices", headers=AUTH).json()["voices"]
    assert any(v["id"] == "es-ES-AlvaroNeural" for v in voices)


def test_ssml_escapes_text_and_sets_language():
    ssml = neural_tts._ssml("Tom & Jerry <3", "es-ES-AlvaroNeural", 10, -5)
    assert "xml:lang='es-ES'" in ssml and "Tom &amp; Jerry &lt;3" in ssml
    assert "rate='+10%'" in ssml and "pitch='-5Hz'" in ssml
