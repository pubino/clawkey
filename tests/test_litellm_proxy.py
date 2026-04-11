"""Test LiteLLM proxy integration — Anthropic ↔ OpenAI translation for agent mode."""

import requests
import pytest


@pytest.fixture
def litellm_auth_headers(litellm_master_key):
    """Auth headers for LiteLLM proxy requests."""
    return {"Authorization": f"Bearer {litellm_master_key}"}


@pytest.fixture
def litellm_available(litellm_base_url, litellm_auth_headers):
    """Skip tests if LiteLLM proxy is not running."""
    try:
        resp = requests.get(
            f"{litellm_base_url}/health",
            headers=litellm_auth_headers,
            timeout=5,
        )
        if resp.status_code != 200:
            pytest.skip(f"LiteLLM proxy not healthy (status {resp.status_code})")
    except requests.ConnectionError:
        pytest.skip("LiteLLM proxy not running")


def test_litellm_health(litellm_base_url, litellm_auth_headers, litellm_available):
    """Verify the LiteLLM proxy health endpoint responds."""
    resp = requests.get(
        f"{litellm_base_url}/health",
        headers=litellm_auth_headers,
        timeout=10,
    )
    assert resp.status_code == 200, (
        f"LiteLLM health check failed ({resp.status_code}): {resp.text}"
    )


def test_litellm_messages_api(litellm_base_url, litellm_master_key, litellm_available, portkey_model):
    """Send an Anthropic Messages API request through LiteLLM proxy.

    LiteLLM translates this to OpenAI format, forwards to Portkey,
    and returns an Anthropic-format response.
    """
    url = f"{litellm_base_url}/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
        "x-api-key": litellm_master_key,
    }
    payload = {
        "model": portkey_model,
        "max_tokens": 64,
        "messages": [
            {"role": "user", "content": "Reply with exactly: PONG"}
        ],
    }

    resp = requests.post(url, json=payload, headers=headers, timeout=30)
    assert resp.status_code == 200, (
        f"LiteLLM Messages API failed ({resp.status_code}): {resp.text}"
    )

    data = resp.json()
    assert "content" in data, f"Unexpected response structure: {data}"
    assert len(data["content"]) > 0, "No content blocks in response"
    text = data["content"][0].get("text", "")
    assert len(text) > 0, f"Empty response text: {data}"


def test_litellm_tool_use(litellm_base_url, litellm_master_key, litellm_available, portkey_model):
    """Send a request with tool definitions through LiteLLM proxy.

    Verifies that the model returns tool calls in Anthropic format,
    which is required for Claude Code's interactive agent mode.
    """
    url = f"{litellm_base_url}/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
        "x-api-key": litellm_master_key,
    }
    payload = {
        "model": portkey_model,
        "max_tokens": 256,
        "tools": [
            {
                "name": "get_weather",
                "description": "Get the current weather in a given location.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "location": {
                            "type": "string",
                            "description": "City and state, e.g. San Francisco, CA",
                        }
                    },
                    "required": ["location"],
                },
            }
        ],
        "messages": [
            {"role": "user", "content": "What's the weather in San Francisco?"}
        ],
    }

    resp = requests.post(url, json=payload, headers=headers, timeout=30)
    assert resp.status_code == 200, (
        f"LiteLLM tool use failed ({resp.status_code}): {resp.text}"
    )

    data = resp.json()
    assert "content" in data, f"Unexpected response structure: {data}"
    assert len(data["content"]) > 0, "No content blocks in response"

    # The model should return a tool_use block (or at minimum a text response)
    content_types = [block.get("type") for block in data["content"]]
    assert "tool_use" in content_types, (
        f"Expected tool_use block in response, got types: {content_types}. "
        f"Full response: {data}"
    )

    # Verify tool_use block structure
    tool_block = next(b for b in data["content"] if b["type"] == "tool_use")
    assert tool_block["name"] == "get_weather", (
        f"Expected get_weather tool call, got: {tool_block['name']}"
    )
    assert "input" in tool_block, f"Missing input in tool_use block: {tool_block}"
    assert "location" in tool_block["input"], (
        f"Missing location in tool input: {tool_block['input']}"
    )
