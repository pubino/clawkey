import os
import pytest


@pytest.fixture
def portkey_api_key():
    key = os.environ.get("AI_SANDBOX_KEY") or os.environ.get("OPENAI_API_KEY")
    if not key:
        pytest.skip("AI_SANDBOX_KEY or OPENAI_API_KEY not set")
    return key


@pytest.fixture
def portkey_base_url():
    return os.environ.get("OPENAI_BASE_URL", "https://api.portkey.ai/v1")


@pytest.fixture
def portkey_model():
    return os.environ.get("PORTKEY_MODEL", "gemini-3.1-pro-preview")


@pytest.fixture
def litellm_base_url():
    return os.environ.get("LITELLM_BASE_URL", "http://localhost:4040")


@pytest.fixture
def litellm_master_key():
    key = os.environ.get("LITELLM_MASTER_KEY")
    if not key:
        pytest.skip("LITELLM_MASTER_KEY not set")
    return key
