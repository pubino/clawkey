FROM python:3.12-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Python test dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project files
COPY PROMPT.md run.sh ralph-run.sh portkey-backend.sh clawkey test.sh litellm_config.yaml ralph.yml ./
COPY tests/ tests/

# Create setup-env.sh placeholder for config tests
RUN echo '#!/usr/bin/env bash' > setup-env.sh && \
    echo 'export AI_SANDBOX_KEY="${AI_SANDBOX_KEY:-test-key}"' >> setup-env.sh && \
    echo 'export PORTKEY_MODEL="${PORTKEY_MODEL:-gemini-3.1-pro-preview}"' >> setup-env.sh && \
    chmod +x setup-env.sh

RUN chmod +x run.sh ralph-run.sh portkey-backend.sh clawkey test.sh

# Default: run the test suite
CMD ["python", "-m", "pytest", "tests/", "-v"]
