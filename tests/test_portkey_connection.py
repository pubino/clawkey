"""Test Portkey AI Gateway connectivity and Anthropic Messages API translation."""

import os
import requests
import pytest
import yaml


def test_portkey_endpoint_reachable(portkey_base_url):
    """Verify the Portkey API endpoint is reachable."""
    resp = requests.get(portkey_base_url, timeout=10)
    assert resp.status_code < 500, f"Portkey endpoint returned server error: {resp.status_code}"


def test_portkey_chat_completion(portkey_api_key, portkey_base_url, portkey_model):
    """Send an OpenAI-format chat completion through Portkey (known working)."""
    url = f"{portkey_base_url}/chat/completions"
    headers = {
        "Authorization": f"Bearer {portkey_api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": portkey_model,
        "messages": [
            {"role": "user", "content": "Reply with exactly: PONG"}
        ],
    }

    resp = requests.post(url, json=payload, headers=headers, timeout=30)
    assert resp.status_code == 200, f"Chat completion failed ({resp.status_code}): {resp.text}"

    data = resp.json()
    assert "choices" in data, f"Unexpected response structure: {data}"
    assert len(data["choices"]) > 0, "No choices in response"
    message = data["choices"][0]["message"]
    content = message.get("content") or message.get("parts", [{}])[0].get("text", "")
    assert len(content) > 0, f"Empty response content in message: {message}"


def test_portkey_messages_api(portkey_api_key, portkey_model):
    """Send an Anthropic Messages API request through Portkey.

    This is the format Claude Code uses. Portkey should translate it
    to the target provider's format and return an Anthropic-format response.
    """
    url = "https://api.portkey.ai/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
        "x-portkey-api-key": portkey_api_key,
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
        f"Messages API failed ({resp.status_code}): {resp.text}\n"
        "If this fails, the Portkey gateway may not support Anthropic Messages API format. "
        "Claude Code requires this endpoint."
    )

    data = resp.json()
    assert "content" in data, f"Unexpected response structure: {data}"
    assert len(data["content"]) > 0, "No content blocks in response"
    text = data["content"][0].get("text", "")
    assert len(text) > 0, f"Empty response text: {data}"


def _load_available_models():
    """Read model names from the active user litellm_config.yaml.

    The in-tree file is a template (`model_list: []`); the active config lives
    under XDG_CONFIG_HOME/clawkey/. Falls back to the in-tree template if the
    user copy doesn't exist (e.g., CI / Docker).
    """
    config_home = os.environ.get(
        "CLAWKEY_CONFIG_DIR",
        os.path.join(
            os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
            "clawkey",
        ),
    )
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidates = [
        os.path.join(config_home, "litellm_config.yaml"),
        os.path.join(project_root, "litellm_config.yaml"),
    ]
    for path in candidates:
        try:
            with open(path) as f:
                config = yaml.safe_load(f)
            models = [m["model_name"] for m in config.get("model_list") or []]
            if models:
                return models
        except (FileNotFoundError, KeyError, TypeError):
            continue
    return []


AVAILABLE_MODELS = _load_available_models()


@pytest.mark.parametrize("model_name", AVAILABLE_MODELS if AVAILABLE_MODELS else [pytest.param("none", marks=pytest.mark.skip(reason="No models in litellm_config.yaml"))])
def test_model_responds(portkey_api_key, portkey_base_url, model_name):
    """Verify each configured model responds through Portkey."""
    url = f"{portkey_base_url}/chat/completions"
    headers = {
        "Authorization": f"Bearer {portkey_api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model_name,
        "messages": [
            {"role": "user", "content": "Reply with exactly one word: hello"}
        ],
    }

    resp = requests.post(url, json=payload, headers=headers, timeout=30)
    assert resp.status_code == 200, (
        f"Model {model_name} failed ({resp.status_code}): {resp.text}"
    )
