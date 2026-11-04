"""OpenAI-compatible text model client: Ollama (default), LM Studio, OpenRouter, OpenAI or any compatible API.

This is the planning/reasoning model, not the browser-action model (that is Laya). It is used for: interpreting
the request, planning sub-goals, structured extraction and the final summary.

Two wire protocols are supported, selected by `LlmConfig.api`: the classic chat-completions API (`chat`, the default,
`POST {base_url}/chat/completions`) and OpenAI's Responses API (`responses`, `POST {base_url}/responses`, always
streamed, never stored). Friday's ChatGPT sign-in tokens are only valid for the latter.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlparse

import httpx

log = logging.getLogger("jarvis.llm")

PRESETS = {
    "ollama": "http://127.0.0.1:11434/v1",
    "lmstudio": "http://127.0.0.1:1234/v1",
    "openrouter": "https://openrouter.ai/api/v1",
    "openai": "https://api.openai.com/v1",
}
# Models that are not chat models, or too small to follow a planning schema.
NOT_CHAT = re.compile(r"(embed|nomic|bge-|minilm|rerank|whisper|tts|moderation|clip)", re.I)
PREFERRED = ("qwen3", "qwen2.5", "gpt-oss", "gemma4", "gemma3", "llama3.3", "llama3.2", "llama3.1", "mistral", "phi4", "deepseek-r1", "granite")


class LlmError(RuntimeError):
    """The text model is unreachable, misconfigured, or returned something unusable. `code` keeps the provider's
    error code (Responses API `response.failed` / `error` events, or the JSON error body of an HTTP failure)."""

    def __init__(self, message: str, code: str | None = None):
        super().__init__(message)
        self.code = code


def is_loopback(base_url: str) -> bool:
    return (urlparse(base_url).hostname or "") in {"localhost", "127.0.0.1", "::1"}


def disclosure_for(base_url: str) -> list[str]:
    if is_loopback(base_url):
        return ["Everything stays on this Mac: prompts and page text go only to the local model server."]
    host = urlparse(base_url).hostname or base_url
    return [
        f"Sent to {host}: your task text and follow-up messages.",
        f"Sent to {host}: text from the web pages the agent reads (titles, visible text, link text and URLs) when planning, extracting and summarising.",
        f"Sent to {host}: the page's visible form-field labels when planning a form interaction.",
        "Not sent: your Keychain, cookies, saved passwords, password and payment fields, screenshots, or files on disk.",
        "Browser actions and Laya decisions still run locally on this Mac.",
    ]


@dataclass
class LlmConfig:
    provider: str = "ollama"
    base_url: str = PRESETS["ollama"]
    model: str = ""
    api_key: str | None = None
    json_mode: str = "auto"  # auto | on | off
    reasoning: str = "off"  # default | off
    api: str = "chat"  # chat (chat/completions) | responses (OpenAI Responses API)

    @property
    def remote(self) -> bool:
        return not is_loopback(self.base_url)


@dataclass
class LlmResult:
    text: str
    latency_ms: int
    usage: dict[str, Any] = field(default_factory=dict)
    model: str = ""


def strip_thinking(text: str) -> str:
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S | re.I).strip()


def extract_json(text: str) -> Any:
    """Parse a JSON object from model output, tolerating fences, prose and trailing commas."""
    text = strip_thinking(text)
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, flags=re.S | re.I)
    candidates = [fenced.group(1)] if fenced else []
    candidates.append(text)
    for candidate in candidates:
        start = candidate.find("{")
        if start < 0:
            continue
        depth, in_string, escaped = 0, False, False
        for i in range(start, len(candidate)):
            ch = candidate[i]
            if in_string:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_string = False
            elif ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    blob = candidate[start : i + 1]
                    for attempt in (blob, re.sub(r",\s*([}\]])", r"\1", blob)):
                        try:
                            return json.loads(attempt)
                        except json.JSONDecodeError:
                            continue
                    break
    raise LlmError("The model did not return valid JSON.")


class LlmClient:
    def __init__(self, config: LlmConfig):
        self.config = config
        self._client = httpx.AsyncClient(timeout=httpx.Timeout(180, connect=5), limits=httpx.Limits(max_keepalive_connections=4))
        self.calls = 0
        self.total_ms = 0
        self._json_unsupported = False
        self._schema_unsupported = False

    async def aclose(self) -> None:
        await self._client.aclose()

    def configure(self, config: LlmConfig) -> None:
        self.config = config
        self._json_unsupported = False
        self._schema_unsupported = False

    # Plumbing ----------------------------------------------------------------------------------------------

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.config.api_key:
            headers["Authorization"] = f"Bearer {self.config.api_key}"
        if "openrouter.ai" in self.config.base_url:
            headers["X-Title"] = "Friday"
        return headers

    def _body(self, messages: list[dict[str, str]], *, max_tokens: int, temperature: float, json_object: bool, stream: bool,
              schema: dict[str, Any] | None = None) -> dict[str, Any]:
        cfg = self.config
        body: dict[str, Any] = {"model": cfg.model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature}
        if stream:
            body["stream"] = True
        if json_object and cfg.json_mode != "off" and not self._json_unsupported:
            if schema and not self._schema_unsupported:
                # Constrained decoding: the server can only emit text that matches the schema.
                body["response_format"] = {"type": "json_schema", "json_schema": {"name": "reply", "schema": schema}}
            else:
                body["response_format"] = {"type": "json_object"}
        if cfg.reasoning == "off":
            if cfg.remote and "openrouter.ai" in cfg.base_url:
                body["reasoning"] = {"enabled": False}
            elif cfg.remote and "api.openai.com" in cfg.base_url:
                pass  # non-reasoning models reject the parameter
            elif not cfg.remote:
                body["reasoning_effort"] = "none"  # Ollama / LM Studio turn thinking off with this
        return body

    async def _post(self, body: dict[str, Any]) -> dict[str, Any]:
        url = self.config.base_url.rstrip("/") + "/chat/completions"
        for attempt in range(3):
            try:
                response = await self._client.post(url, json=body, headers=self._headers())
            except httpx.ConnectError as error:
                raise LlmError(self._unreachable()) from error
            except httpx.HTTPError as error:
                raise LlmError(f"The text model request failed: {error}") from error
            if response.status_code in {429, 503, 529} and attempt < 2:
                await asyncio.sleep(0.6 * 2**attempt)
                continue
            if response.status_code == 400 and "response_format" in body and any(w in response.text.lower() for w in ("response_format", "json_schema", "schema")):
                if body["response_format"].get("type") == "json_schema":
                    self._schema_unsupported = True  # no schema support: ask for a plain JSON object instead
                    body = {**body, "response_format": {"type": "json_object"}}
                else:
                    self._json_unsupported = True  # the server has no JSON mode; fall back to prompt-only JSON
                    body = {k: v for k, v in body.items() if k != "response_format"}
                continue
            if response.status_code == 400 and "reasoning" in response.text.lower() and ("reasoning_effort" in body or "reasoning" in body):
                body = {k: v for k, v in body.items() if k not in {"reasoning_effort", "reasoning"}}
                continue
            if response.status_code == 404 and not self.config.model:
                raise LlmError("No text model is selected. Choose one in Settings.")
            if response.is_error:
                raise LlmError(self._http_error(response))
            return response.json()
        raise LlmError("The text model is unavailable.")

    def _unreachable(self) -> str:
        if self.config.provider == "ollama" or "11434" in self.config.base_url:
            return "Ollama is not running. Start it (Settings → AI model → Start Ollama) or choose another provider."
        return f"Could not reach the text model at {self.config.base_url}."

    @staticmethod
    def _http_error(response: httpx.Response) -> str:
        detail = ""
        try:
            data = response.json()
            err = data.get("error", data)
            detail = err.get("message") if isinstance(err, dict) else str(err)
        except ValueError:
            detail = response.text[:200]
        if response.status_code in {401, 403}:
            return "The text model provider rejected the API key. Check it in Settings."
        if response.status_code == 404:
            return f"The text model was not found ({detail or 'HTTP 404'}). Pull or select a model in Settings."
        return f"The text model returned HTTP {response.status_code}: {detail}"

    # Responses API ------------------------------------------------------------------------------------------

    def _responses_body(self, messages: list[dict[str, str]], *, json_object: bool, schema: dict[str, Any] | None = None) -> dict[str, Any]:
        """The system prompt becomes top-level `instructions` (a `system` input item is never sent); the rest become
        user/assistant input items. Always `store: false` and `stream: true`; no sampling or token parameters."""
        cfg = self.config
        instructions = [m.get("content") or "" for m in messages if m.get("role") == "system"]
        items = [{"role": "assistant" if m.get("role") == "assistant" else "user", "content": m.get("content") or ""}
                 for m in messages if m.get("role") != "system"]
        body: dict[str, Any] = {"model": cfg.model, "input": items, "store": False, "stream": True}
        if instructions:
            body["instructions"] = "\n\n".join(instructions)
        if json_object and cfg.json_mode != "off" and not self._json_unsupported:
            if schema and not self._schema_unsupported:
                body["text"] = {"format": {"type": "json_schema", "name": "plan", "schema": schema, "strict": False}}
            else:
                body["text"] = {"format": {"type": "json_object"}}
        return body

    @staticmethod
    async def _sse(response: httpx.Response) -> AsyncIterator[tuple[str, dict[str, Any]]]:
        """Server-sent events -> (event name, parsed JSON data). Multi-line `data:` blocks are joined; `[DONE]` is skipped."""
        event, data_lines = "", []

        def parsed() -> dict[str, Any] | None:
            payload = "\n".join(data_lines)
            if not payload.strip() or payload.strip() == "[DONE]":
                return None
            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                return None
            return data if isinstance(data, dict) else None

        async for raw in response.aiter_lines():
            line = raw.rstrip("\r\n")
            if not line:
                if data_lines and (data := parsed()) is not None:
                    yield event, data
                event, data_lines = "", []
            elif line.startswith("event:"):
                event = line[6:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
        if data_lines and (data := parsed()) is not None:
            yield event, data

    async def _responses_events(self, body: dict[str, Any], meta: dict[str, Any]) -> AsyncIterator[str]:
        """POST {base_url}/responses and yield the output text deltas. `meta` receives `usage`/`model` from
        `response.completed`. A stream that ends without `response.completed` is an error, as are `response.failed`,
        `response.incomplete` and `error` events (the provider's code is kept on the LlmError)."""
        url = self.config.base_url.rstrip("/") + "/responses"
        for attempt in range(3):
            try:
                async with self._client.stream("POST", url, json=body, headers=self._headers()) as response:
                    if response.status_code in {429, 503, 529} and attempt < 2:
                        await response.aread()
                        await asyncio.sleep(0.6 * 2**attempt)
                        continue
                    if response.status_code == 400 and "text" in body:
                        await response.aread()
                        if any(w in response.text.lower() for w in ("text.format", "json_schema", "schema", "format")):
                            if body["text"]["format"].get("type") == "json_schema":
                                self._schema_unsupported = True
                                body = {**body, "text": {"format": {"type": "json_object"}}}
                            else:
                                self._json_unsupported = True
                                body = {k: v for k, v in body.items() if k != "text"}
                            continue
                    if response.status_code == 404 and not self.config.model:
                        await response.aread()
                        raise LlmError("No text model is selected. Choose one in Settings.", code="no_model")
                    if response.is_error:
                        await response.aread()
                        raise LlmError(self._http_error(response), code=self._error_code(response))
                    completed = False
                    async for event, data in self._sse(response):
                        kind = data.get("type") or event
                        if kind == "response.output_text.delta":
                            delta = data.get("delta")
                            if delta:
                                yield str(delta)
                        elif kind == "response.completed":
                            completed = True
                            final = data.get("response") or {}
                            meta["usage"] = final.get("usage") or {}
                            meta["model"] = final.get("model") or self.config.model
                        elif kind == "response.failed":
                            err = (data.get("response") or {}).get("error") or {}
                            raise LlmError(f"The text model failed: {err.get('message') or 'unknown error'}", code=err.get("code") or "response_failed")
                        elif kind == "response.incomplete":
                            details = (data.get("response") or {}).get("incomplete_details") or {}
                            raise LlmError(f"The text model stopped early ({details.get('reason') or 'incomplete'}).", code=details.get("reason") or "incomplete")
                        elif kind == "error":
                            err = data.get("error") if isinstance(data.get("error"), dict) else data
                            raise LlmError(f"The text model reported an error: {err.get('message') or 'unknown error'}", code=err.get("code") or "error")
                    if not completed:
                        raise LlmError("The text model stream ended before the response completed.", code="incomplete_stream")
                    return
            except httpx.ConnectError as error:
                raise LlmError(self._unreachable(), code="unreachable") from error
            except httpx.HTTPError as error:
                raise LlmError(f"The text model request failed: {error}", code="transport") from error
        raise LlmError("The text model is unavailable.", code="unavailable")

    async def _responses_complete(self, body: dict[str, Any]) -> tuple[str, dict[str, Any], str]:
        meta: dict[str, Any] = {}
        parts = [chunk async for chunk in self._responses_events(body, meta)]
        return "".join(parts), meta.get("usage", {}), meta.get("model", self.config.model)

    @staticmethod
    def _error_code(response: httpx.Response) -> str:
        try:
            err = response.json().get("error")
            if isinstance(err, dict) and err.get("code"):
                return str(err["code"])
        except (ValueError, AttributeError):
            pass
        return f"http_{response.status_code}"

    # Calls --------------------------------------------------------------------------------------------------

    async def chat(
        self, messages: list[dict[str, str]], *, max_tokens: int = 1500, temperature: float = 0.1, json_object: bool = False,
        schema: dict[str, Any] | None = None,
    ) -> LlmResult:
        started = time.perf_counter()
        if self.config.api == "responses":
            text, usage, model = await self._responses_complete(self._responses_body(messages, json_object=json_object, schema=schema))
            data: dict[str, Any] = {"choices": [{"message": {"content": text}}], "usage": usage, "model": model}
        else:
            data = await self._post(self._body(messages, max_tokens=max_tokens, temperature=temperature, json_object=json_object, stream=False, schema=schema))
        try:
            text = data["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError) as error:
            raise LlmError("The text model returned an unexpected response.") from error
        ms = round((time.perf_counter() - started) * 1000)
        self.calls += 1
        self.total_ms += ms
        return LlmResult(strip_thinking(text), ms, data.get("usage", {}), data.get("model", self.config.model))

    async def chat_json(
        self, system: str, user: str, *, max_tokens: int = 1500, attempts: int = 2, validate: Callable[[Any], Any] | None = None,
        schema: dict[str, Any] | None = None,
    ) -> tuple[Any, LlmResult]:
        """One JSON object back. Retries with the parse error fed back, up to `attempts` times."""
        messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        last_error: Exception | None = None
        for _ in range(attempts):
            result = await self.chat(messages, max_tokens=max_tokens, json_object=True, schema=schema)
            try:
                data = extract_json(result.text)
                return (validate(data) if validate else data), result
            except (LlmError, ValueError, KeyError, TypeError) as error:
                last_error = error
                messages = [*messages, {"role": "assistant", "content": result.text[:1500]},
                            {"role": "user", "content": f"That was not usable ({error}). Reply again with ONLY the corrected JSON object."}]
        raise LlmError(f"The text model could not produce a valid plan: {last_error}")

    async def stream(self, messages: list[dict[str, str]], *, max_tokens: int = 2000, temperature: float = 0.2) -> AsyncIterator[str]:
        started = time.perf_counter()
        if self.config.api == "responses":
            try:
                async for chunk in self._responses_events(self._responses_body(messages, json_object=False), {}):
                    yield chunk
            finally:
                self.calls += 1
                self.total_ms += round((time.perf_counter() - started) * 1000)
            return
        body = self._body(messages, max_tokens=max_tokens, temperature=temperature, json_object=False, stream=True)
        url = self.config.base_url.rstrip("/") + "/chat/completions"
        in_think = False
        try:
            async with self._client.stream("POST", url, json=body, headers=self._headers()) as response:
                if response.is_error:
                    await response.aread()
                    raise LlmError(self._http_error(response))
                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        break
                    try:
                        delta = json.loads(payload)["choices"][0].get("delta", {}).get("content") or ""
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue
                    if "<think>" in delta:
                        in_think = True
                    if not in_think and delta:
                        yield delta
                    if "</think>" in delta:
                        in_think = False
        except httpx.ConnectError as error:
            raise LlmError(self._unreachable()) from error
        except httpx.HTTPError as error:
            raise LlmError(f"The text model request failed: {error}") from error
        finally:
            self.calls += 1
            self.total_ms += round((time.perf_counter() - started) * 1000)

    # Discovery ------------------------------------------------------------------------------------------------

    async def list_models(self) -> list[str]:
        base = self.config.base_url.rstrip("/")
        try:
            response = await self._client.get(base + "/models", headers=self._headers(), timeout=6)
            if response.is_success:
                return [n for n in model_names(response.json()) if not NOT_CHAT.search(n)]
        except (httpx.HTTPError, ValueError):
            pass
        if self.config.provider == "ollama" or "11434" in base:
            root = base[:-3] if base.endswith("/v1") else base
            try:
                response = await self._client.get(root + "/api/tags", timeout=4)
                return [m["name"] for m in response.json().get("models", []) if not NOT_CHAT.search(m["name"])]
            except (httpx.HTTPError, ValueError, KeyError):
                return []
        return []

    async def ping(self) -> dict[str, Any]:
        started = time.perf_counter()
        try:
            await self.chat([{"role": "user", "content": "Reply with the single word: ok"}], max_tokens=8, temperature=0)
        except LlmError as error:
            return {"ok": False, "latency_ms": round((time.perf_counter() - started) * 1000), "error": str(error)}
        return {"ok": True, "latency_ms": round((time.perf_counter() - started) * 1000)}


def model_names(data: Any) -> list[str]:
    """Model ids from a `GET /models` reply: the classic `{"data": [{"id"}]}` or the ChatGPT-style
    `{"models": [{"slug", "display_name", "visibility"}]}` (only `visibility == "list"` entries, by slug)."""
    if not isinstance(data, dict):
        return []
    if isinstance(data.get("models"), list):
        return [str(m["slug"]) for m in data["models"] if isinstance(m, dict) and m.get("slug") and m.get("visibility") == "list"]
    return [str(m["id"]) for m in data.get("data", []) if isinstance(m, dict) and "id" in m]


def pick_default_model(models: list[str]) -> str | None:
    """Best available chat model by family preference, favouring mid-size tags."""
    if not models:
        return None

    def rank(name: str) -> tuple[int, int]:
        lowered = name.lower()
        family = next((i for i, key in enumerate(PREFERRED) if key in lowered), len(PREFERRED))
        tiny = bool(re.search(r"(:|-)(0\.?\d*b|1b|1\.5b|2b|270m|135m)\b", lowered))
        return (family + (20 if tiny else 0), len(name))

    return sorted(models, key=rank)[0]


async def detect_local_servers() -> list[dict[str, Any]]:
    found = []
    async with httpx.AsyncClient(timeout=1.5) as client:
        for provider, base in (("ollama", PRESETS["ollama"]), ("lmstudio", PRESETS["lmstudio"])):
            try:
                r = await client.get(base + "/models")
                if r.is_success:
                    models = [m["id"] for m in r.json().get("data", []) if not NOT_CHAT.search(m["id"])]
                    found.append({"provider": provider, "base_url": base, "models": models, "reachable": True})
            except (httpx.HTTPError, ValueError):
                continue
    return found


async def ollama_pull(model: str, on_progress: Callable[[dict[str, Any]], Any], base: str = "http://127.0.0.1:11434") -> None:
    async with httpx.AsyncClient(timeout=httpx.Timeout(None, connect=5)) as client:
        try:
            async with client.stream("POST", f"{base}/api/pull", json={"model": model, "stream": True}) as response:
                if response.is_error:
                    await response.aread()
                    raise LlmError(f"Ollama could not pull {model}: HTTP {response.status_code} {response.text[:160]}")
                async for line in response.aiter_lines():
                    if not line.strip():
                        continue
                    data = json.loads(line)
                    if "error" in data:
                        raise LlmError(f"Ollama could not pull {model}: {data['error']}")
                    result = on_progress({"status": data.get("status", ""), "completed": data.get("completed", 0),
                                          "total": data.get("total", 0), "done": data.get("status") == "success"})
                    if asyncio.iscoroutine(result):
                        await result
        except httpx.ConnectError as error:
            raise LlmError("Ollama is not running.") from error
