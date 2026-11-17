"""Online neural voices (Microsoft Edge "Read aloud") for Friday's spoken replies.

The `edge-tts` package knows the service's protocol (endpoint, the Sec-MS-GEC token, headers). Unlike its `Communicate`
class, which opens a new WebSocket for every text, this keeps a small pool of connections open: the TLS + WebSocket
handshake is ~0.4-0.5 s, which was most of the time to first audio. A warm connection answers a short sentence in
~0.25-0.4 s. Connections that the service closed are reopened once, transparently.

Only the text of the reply is sent (no audio, no identifiers of the user). The audio comes back as 24 kHz mono MP3;
the app decodes it. The service does not accept raw PCM on this endpoint.
"""

from __future__ import annotations

import asyncio
import logging
import ssl
import time
import uuid
from xml.sax.saxutils import escape

import aiohttp
import certifi
from edge_tts.communicate import date_to_string, ssml_headers_plus_data
from edge_tts.constants import SEC_MS_GEC_VERSION, WSS_HEADERS, WSS_URL
from edge_tts.drm import DRM

log = logging.getLogger("jarvis.neural_tts")

OUTPUT_FORMAT = "audio-24khz-48kbitrate-mono-mp3"
# Voices Friday offers (the service has many more; any valid name works).
VOICES = [
    {"id": "es-ES-AlvaroNeural", "name": "Álvaro (es-ES)", "language": "es-ES"},
    {"id": "es-ES-ElviraNeural", "name": "Elvira (es-ES)", "language": "es-ES"},
    {"id": "es-ES-XimenaNeural", "name": "Ximena (es-ES)", "language": "es-ES"},
    {"id": "es-MX-JorgeNeural", "name": "Jorge (es-MX)", "language": "es-MX"},
    {"id": "es-MX-DaliaNeural", "name": "Dalia (es-MX)", "language": "es-MX"},
    {"id": "en-GB-RyanNeural", "name": "Ryan (en-GB)", "language": "en-GB"},
    {"id": "en-GB-SoniaNeural", "name": "Sonia (en-GB)", "language": "en-GB"},
    {"id": "en-US-AndrewNeural", "name": "Andrew (en-US)", "language": "en-US"},
    {"id": "en-US-AvaNeural", "name": "Ava (en-US)", "language": "en-US"},
    {"id": "en-US-EmmaMultilingualNeural", "name": "Emma multilingual (en-US)", "language": "en-US"},
]
# A connection unused for longer than this is replaced before use (the service drops idle sockets).
IDLE_SECONDS = 25.0
REQUEST_TIMEOUT = 8.0


class NeuralTTSError(Exception):
    pass


def _ssml(text: str, voice: str, rate: int, pitch: int) -> str:
    lang = "-".join(voice.split("-")[:2]) or "en-US"
    return (
        f"<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='{lang}'>"
        f"<voice name='{escape(voice)}'><prosody pitch='{pitch:+d}Hz' rate='{rate:+d}%' volume='+0%'>"
        f"{escape(text)}</prosody></voice></speak>"
    )


class _Connection:
    def __init__(self, session: aiohttp.ClientSession, ssl_context: ssl.SSLContext) -> None:
        self._session = session
        self._ssl = ssl_context
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._used = 0.0
        self.lock = asyncio.Lock()

    @property
    def is_open(self) -> bool:
        return self._ws is not None and not self._ws.closed and time.monotonic() - self._used < IDLE_SECONDS

    async def open(self) -> None:
        await self.close()
        url = (
            f"{WSS_URL}&ConnectionId={uuid.uuid4().hex}"
            f"&Sec-MS-GEC={DRM.generate_sec_ms_gec()}&Sec-MS-GEC-Version={SEC_MS_GEC_VERSION}"
        )
        self._ws = await self._session.ws_connect(
            url, compress=15, headers=DRM.headers_with_muid(WSS_HEADERS), ssl=self._ssl, heartbeat=None
        )
        await self._ws.send_str(
            f"X-Timestamp:{date_to_string()}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
            '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false",'
            f'"wordBoundaryEnabled":"false"}},"outputFormat":"{OUTPUT_FORMAT}"}}}}}}}}\r\n'
        )
        self._used = time.monotonic()

    async def close(self) -> None:
        if self._ws is not None and not self._ws.closed:
            try:
                await self._ws.close()
            except Exception:  # noqa: BLE001 - closing a dead socket
                pass
        self._ws = None

    async def synthesize(self, text: str, voice: str, rate: int, pitch: int) -> bytes:
        if not self.is_open:
            await self.open()
        assert self._ws is not None
        request_id = uuid.uuid4().hex
        await self._ws.send_str(ssml_headers_plus_data(request_id, date_to_string(), _ssml(text, voice, rate, pitch)))
        audio = bytearray()
        async with asyncio.timeout(REQUEST_TIMEOUT):
            async for message in self._ws:
                if message.type == aiohttp.WSMsgType.TEXT:
                    if "Path:turn.end" in message.data:
                        break
                elif message.type == aiohttp.WSMsgType.BINARY:
                    if len(message.data) < 2:
                        continue
                    header_length = int.from_bytes(message.data[:2], "big")
                    audio += message.data[2 + header_length:]
                else:
                    raise NeuralTTSError(f"the voice service closed the connection ({message.type.name})")
            else:
                raise NeuralTTSError("the voice service closed the connection")
        self._used = time.monotonic()
        if not audio:
            raise NeuralTTSError("the voice service returned no audio (unknown voice?)")
        return bytes(audio)


class NeuralVoice:
    """A pool of warm connections; `synthesize` takes a free one (two requests can overlap: sentence prefetch)."""

    def __init__(self, size: int = 2) -> None:
        self._size = size
        self._session: aiohttp.ClientSession | None = None
        self._connections: list[_Connection] = []
        self._ssl = ssl.create_default_context(cafile=certifi.where())

    def _ensure(self) -> None:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(trust_env=True)
            self._connections = [_Connection(self._session, self._ssl) for _ in range(self._size)]

    async def warm(self) -> int:
        """Opens the connections that are not open; returns how many are ready."""
        self._ensure()
        ready = 0
        for connection in self._connections:
            if connection.lock.locked():
                continue
            async with connection.lock:
                if not connection.is_open:
                    try:
                        await connection.open()
                    except Exception as error:  # noqa: BLE001 - reported as a count
                        log.info("neural voice warm-up failed: %s", error)
                        continue
                ready += 1
        return ready

    async def synthesize(self, text: str, voice: str, rate: int = 0, pitch: int = 0) -> bytes:
        text = " ".join(text.split())
        if not text:
            raise NeuralTTSError("empty text")
        self._ensure()
        connection = next((c for c in self._connections if not c.lock.locked() and c.is_open), None)
        connection = connection or next((c for c in self._connections if not c.lock.locked()), self._connections[0])
        async with connection.lock:
            try:
                return await connection.synthesize(text, voice, rate, pitch)
            except (aiohttp.ClientError, NeuralTTSError, TimeoutError, ConnectionError) as error:
                # A socket the service closed while idle: reopen once and retry.
                log.info("neural voice retry after: %s", error)
                await connection.close()
                try:
                    return await connection.synthesize(text, voice, rate, pitch)
                except aiohttp.ClientResponseError as again:
                    DRM.handle_client_response_error(again)
                    raise NeuralTTSError(str(again)) from again
                except (aiohttp.ClientError, TimeoutError, ConnectionError) as again:
                    await connection.close()
                    raise NeuralTTSError(str(again) or type(again).__name__) from again

    async def close(self) -> None:
        for connection in self._connections:
            await connection.close()
        if self._session is not None:
            await self._session.close()
