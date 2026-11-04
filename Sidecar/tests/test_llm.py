"""The OpenAI-compatible client: provider quirks, structured output fallback, streaming, discovery."""

import json

import httpx
import pytest

from jarvis.llm import LlmClient, LlmConfig, LlmError, disclosure_for, is_loopback, model_names, pick_default_model


def client_with(handler, **config) -> LlmClient:
    c = LlmClient(LlmConfig(model="m", **config))
    c._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return c


def ok(content='{"a": 1}', status=200):
    return httpx.Response(status, json={"choices": [{"message": {"content": content}}], "usage": {"total_tokens": 5}, "model": "m"})


async def test_json_schema_is_requested_and_the_reply_is_parsed():
    seen = []

    def handler(request):
        seen.append(json.loads(request.content))
        return ok()

    data, result = await client_with(handler).chat_json("sys", "user", schema={"type": "object"})
    assert data == {"a": 1} and result.usage["total_tokens"] == 5
    assert seen[0]["response_format"]["type"] == "json_schema" and seen[0]["reasoning_effort"] == "none" and seen[0]["messages"][0]["role"] == "system"


async def test_a_server_without_schema_support_is_downgraded_once_then_remembered():
    calls = []

    def handler(request):
        body = json.loads(request.content)
        calls.append(body.get("response_format", {}).get("type"))
        if body.get("response_format", {}).get("type") == "json_schema":
            return httpx.Response(400, json={"error": {"message": "response_format json_schema is not supported"}})
        return ok()

    c = client_with(handler)
    await c.chat_json("s", "u", schema={"type": "object"})
    await c.chat_json("s", "u", schema={"type": "object"})
    assert calls == ["json_schema", "json_object", "json_object"]


async def test_a_server_without_any_json_mode_falls_back_to_prompt_only():
    calls = []

    def handler(request):
        body = json.loads(request.content)
        calls.append("response_format" in body)
        return httpx.Response(400, json={"error": {"message": "unknown field response_format"}}) if "response_format" in body else ok()

    await client_with(handler).chat_json("s", "u")
    assert calls == [True, False]


async def test_unparseable_output_is_retried_with_feedback_then_reported():
    prompts = []

    def handler(request):
        prompts.append(json.loads(request.content)["messages"])
        return ok("I think the answer is blue")

    with pytest.raises(LlmError, match="valid plan"):
        await client_with(handler).chat_json("s", "u", attempts=2)
    assert len(prompts) == 2 and "not usable" in prompts[1][-1]["content"]


async def test_errors_are_translated_into_actionable_messages():
    unauthorized = client_with(lambda r: httpx.Response(401, json={"error": {"message": "bad key"}}), provider="openrouter", base_url="https://openrouter.ai/api/v1")
    with pytest.raises(LlmError, match="API key"):
        await unauthorized.chat([{"role": "user", "content": "x"}])
    missing = client_with(lambda r: httpx.Response(404, json={"error": {"message": "model 'm' not found"}}))
    with pytest.raises(LlmError, match="not found"):
        await missing.chat([{"role": "user", "content": "x"}])

    def refuse(request):
        raise httpx.ConnectError("refused")

    with pytest.raises(LlmError, match="Ollama is not running"):
        await client_with(refuse).chat([{"role": "user", "content": "x"}])


async def test_rate_limits_are_retried():
    attempts = []

    def handler(request):
        attempts.append(1)
        return httpx.Response(429, json={}) if len(attempts) < 3 else ok("fine")

    result = await client_with(handler).chat([{"role": "user", "content": "x"}])
    assert result.text == "fine" and len(attempts) == 3


async def test_streaming_yields_deltas_and_hides_thinking():
    lines = ['data: {"choices":[{"delta":{"content":"<think>pl"}}]}', 'data: {"choices":[{"delta":{"content":"an</think>"}}]}',
             'data: {"choices":[{"delta":{"content":"Hello "}}]}', 'data: {"choices":[{"delta":{"content":"world"}}]}', "data: [DONE]"]
    c = client_with(lambda r: httpx.Response(200, content=("\n\n".join(lines) + "\n\n").encode(), headers={"content-type": "text/event-stream"}))
    assert "".join([chunk async for chunk in c.stream([{"role": "user", "content": "x"}])]) == "Hello world"


async def test_remote_providers_get_their_own_reasoning_switches_and_local_ones_none_of_that():
    bodies = []

    def handler(request):
        bodies.append((str(request.url), json.loads(request.content), request.headers.get("authorization")))
        return ok("x")

    await client_with(handler, provider="openrouter", base_url="https://openrouter.ai/api/v1", api_key="k").chat([{"role": "user", "content": "x"}])
    url, body, auth = bodies[0]
    assert url.startswith("https://openrouter.ai/api/v1/chat/completions") and body["reasoning"] == {"enabled": False} and auth == "Bearer k"
    assert "reasoning_effort" not in body


async def test_model_listing_filters_embedding_models():
    c = client_with(lambda r: httpx.Response(200, json={"data": [{"id": "qwen3:8b"}, {"id": "nomic-embed-text"}, {"id": "llama3.1:8b"}]}))
    assert await c.list_models() == ["qwen3:8b", "llama3.1:8b"]


def test_default_model_prefers_capable_families_over_tiny_ones():
    assert pick_default_model(["gemma3:270m", "llama3.1:8b", "qwen3:8b"]) == "qwen3:8b"
    assert pick_default_model(["tinyllama:1b"]) == "tinyllama:1b" and pick_default_model([]) is None


def test_disclosure_distinguishes_local_from_remote():
    assert is_loopback("http://127.0.0.1:11434/v1") and not is_loopback("https://openrouter.ai/api/v1")
    assert len(disclosure_for("http://localhost:1234/v1")) == 1 and "stays on this Mac" in disclosure_for("http://localhost:1234/v1")[0]
    remote = " ".join(disclosure_for("https://openrouter.ai/api/v1"))
    assert "openrouter.ai" in remote and "Not sent" in remote and "cookies" in remote


# Responses API -----------------------------------------------------------------------------------------------------------


def sse(*events: dict) -> bytes:
    return "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()


def completed(text_parts=("Hello ", "world"), usage=None):
    return sse(
        {"type": "response.created", "response": {"id": "resp_1"}},
        *({"type": "response.output_text.delta", "delta": part} for part in text_parts),
        {"type": "response.output_text.done", "text": "".join(text_parts)},
        {"type": "response.completed", "response": {"id": "resp_1", "model": "gpt-5", "status": "completed", "usage": usage or {"input_tokens": 3, "output_tokens": 2}}},
    )


def responses_client(handler, **config) -> LlmClient:
    return client_with(handler, api="responses", base_url="https://chatgpt.example/backend-api/codex", api_key="tok", **config)


async def test_responses_requests_put_the_system_prompt_in_instructions_and_never_sample():
    seen = []

    def handler(request):
        seen.append((str(request.url), request.headers.get("authorization"), json.loads(request.content)))
        return httpx.Response(200, content=completed(('{"a": ', "1}")), headers={"content-type": "text/event-stream"})

    c = responses_client(handler)
    data, result = await c.chat_json("You plan.", "Find flights", schema={"type": "object", "properties": {"a": {"type": "integer"}}})
    assert data == {"a": 1}
    url, auth, body = seen[0]
    assert url == "https://chatgpt.example/backend-api/codex/responses" and auth == "Bearer tok"
    assert body["instructions"] == "You plan." and body["input"] == [{"role": "user", "content": "Find flights"}]
    assert all(item["role"] != "system" for item in body["input"])
    assert body["store"] is False and body["stream"] is True and body["model"] == "m"
    assert body["text"] == {"format": {"type": "json_schema", "name": "plan", "schema": {"type": "object", "properties": {"a": {"type": "integer"}}}, "strict": False}}
    assert not {"temperature", "max_output_tokens", "max_tokens", "reasoning_effort", "reasoning", "user", "messages"} & set(body)
    assert result.text == '{"a": 1}' and result.usage == {"input_tokens": 3, "output_tokens": 2} and result.model == "gpt-5"


async def test_responses_json_object_mode_and_conversation_roles():
    seen = []

    def handler(request):
        seen.append(json.loads(request.content))
        return httpx.Response(200, content=completed(('{"ok": true}',)), headers={"content-type": "text/event-stream"})

    c = responses_client(handler)
    messages = [{"role": "system", "content": "A"}, {"role": "user", "content": "u1"}, {"role": "assistant", "content": "a1"}, {"role": "user", "content": "u2"}]
    result = await c.chat(messages, json_object=True)
    assert result.text == '{"ok": true}'
    assert seen[0]["text"] == {"format": {"type": "json_object"}}
    assert seen[0]["input"] == [{"role": "user", "content": "u1"}, {"role": "assistant", "content": "a1"}, {"role": "user", "content": "u2"}]
    plain = await c.chat([{"role": "user", "content": "hi"}])
    assert "text" not in seen[1] and "instructions" not in seen[1] and plain.text == '{"ok": true}'


async def test_responses_streaming_yields_deltas_in_order():
    c = responses_client(lambda r: httpx.Response(200, content=completed(("a", "b", "c")), headers={"content-type": "text/event-stream"}))
    assert [chunk async for chunk in c.stream([{"role": "user", "content": "x"}])] == ["a", "b", "c"] and c.calls == 1


async def test_responses_failures_keep_the_provider_error_code():
    failed = sse({"type": "response.created", "response": {}}, {"type": "response.output_text.delta", "delta": "par"},
                 {"type": "response.failed", "response": {"status": "failed", "error": {"code": "rate_limit_exceeded", "message": "slow down"}}})
    with pytest.raises(LlmError, match="slow down") as info:
        await responses_client(lambda r: httpx.Response(200, content=failed, headers={"content-type": "text/event-stream"})).chat([{"role": "user", "content": "x"}])
    assert info.value.code == "rate_limit_exceeded"

    errored = sse({"type": "error", "code": "invalid_prompt", "message": "nope", "param": None})
    with pytest.raises(LlmError, match="nope") as info:
        await responses_client(lambda r: httpx.Response(200, content=errored, headers={"content-type": "text/event-stream"})).chat([{"role": "user", "content": "x"}])
    assert info.value.code == "invalid_prompt"

    truncated = sse({"type": "response.created", "response": {}}, {"type": "response.output_text.delta", "delta": "half"})
    with pytest.raises(LlmError, match="before the response completed") as info:
        await responses_client(lambda r: httpx.Response(200, content=truncated, headers={"content-type": "text/event-stream"})).chat([{"role": "user", "content": "x"}])
    assert info.value.code == "incomplete_stream"

    incomplete = sse({"type": "response.incomplete", "response": {"status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}}})
    with pytest.raises(LlmError, match="stopped early") as info:
        await responses_client(lambda r: httpx.Response(200, content=incomplete, headers={"content-type": "text/event-stream"})).chat([{"role": "user", "content": "x"}])
    assert info.value.code == "max_output_tokens"

    with pytest.raises(LlmError, match="API key") as info:
        await responses_client(lambda r: httpx.Response(401, json={"error": {"code": "invalid_token", "message": "expired"}})).chat([{"role": "user", "content": "x"}])
    assert info.value.code == "invalid_token"


async def test_responses_schema_rejection_is_downgraded_like_chat_completions():
    formats = []

    def handler(request):
        body = json.loads(request.content)
        formats.append(body.get("text", {}).get("format", {}).get("type"))
        if formats[-1] == "json_schema":
            return httpx.Response(400, json={"error": {"message": "Invalid schema for text.format"}})
        return httpx.Response(200, content=completed(('{"a": 1}',)), headers={"content-type": "text/event-stream"})

    c = responses_client(handler)
    await c.chat_json("s", "u", schema={"type": "object"})
    await c.chat_json("s", "u", schema={"type": "object"})
    assert formats == ["json_schema", "json_object", "json_object"]


async def test_responses_rate_limits_are_retried_before_streaming():
    attempts = []

    def handler(request):
        attempts.append(1)
        return httpx.Response(429, json={}) if len(attempts) < 2 else httpx.Response(200, content=completed(("ok",)), headers={"content-type": "text/event-stream"})

    assert (await responses_client(handler).chat([{"role": "user", "content": "x"}])).text == "ok" and len(attempts) == 2


async def test_sse_parser_handles_multiline_data_and_missing_event_names():
    raw = b'data: {"type":"response.output_text.delta",\ndata: "delta":"x"}\n\ndata: [DONE]\n\n: comment\n\ndata: {"type":"response.completed","response":{}}\n'
    c = responses_client(lambda r: httpx.Response(200, content=raw, headers={"content-type": "text/event-stream"}))
    assert (await c.chat([{"role": "user", "content": "x"}])).text == "x"


async def test_model_listing_understands_both_reply_shapes():
    chatgpt = {"models": [{"slug": "gpt-5", "display_name": "GPT-5", "visibility": "list"}, {"slug": "gpt-5-hidden", "visibility": "hidden"},
                          {"slug": "text-embedding-3", "visibility": "list"}, {"display_name": "no slug", "visibility": "list"}]}
    assert await responses_client(lambda r: httpx.Response(200, json=chatgpt)).list_models() == ["gpt-5"]
    classic = {"data": [{"id": "gpt-4.1"}, {"id": "whisper-1"}]}
    assert await responses_client(lambda r: httpx.Response(200, json=classic)).list_models() == ["gpt-4.1"]
    assert model_names({"models": "nope"}) == [] and model_names([1]) == []
