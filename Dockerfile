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
COPY PROMPT.md portkey-backend.sh clawkey test.sh litellm_config.yaml ralph.yml ./
COPY lib/ lib/
COPY tests/ tests/

# Create .env placeholder and load-env.sh for config tests
RUN printf 'AI_SANDBOX_KEY=test-key\nLITELLM_MASTER_KEY=sk-clawkey-local\n' > .env
COPY load-env.sh .
RUN chmod +x load-env.sh

RUN chmod +x portkey-backend.sh clawkey test.sh lib/launchd/run-proxy.sh

# Default: run the test suite
CMD ["python", "-m", "pytest", "tests/", "-v"]
