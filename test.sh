#!/usr/bin/env bash
# Run the test suite locally or in Docker.
# Usage:
#   ./test.sh              # Run locally (requires Python venv)
#   ./test.sh --docker     # Run in Docker container
#   ./test.sh --config     # Run only config validation (no API calls)

set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-local}"

run_local() {
    # Create venv if needed
    if [ ! -d .venv ]; then
        python3 -m venv .venv
    fi
    source .venv/bin/activate
    pip install -q -r requirements.txt

    # Load Portkey environment if available
    if [ -f ./setup-env.sh ]; then
        source ./setup-env.sh
    fi

    echo ""
    echo "Running tests..."
    python -m pytest tests/ -v "$@"
}

run_config_only() {
    if [ ! -d .venv ]; then
        python3 -m venv .venv
    fi
    source .venv/bin/activate
    pip install -q -r requirements.txt

    echo ""
    echo "Running config validation tests..."
    python -m pytest tests/test_claude_config.py tests/test_ralph_config.py -v
}

run_docker() {
    echo "Building and running tests in Docker..."
    docker-compose run --rm test
}

case "$MODE" in
    --docker)
        run_docker
        ;;
    --config)
        shift
        run_config_only "$@"
        ;;
    *)
        shift 2>/dev/null || true
        run_local "$@"
        ;;
esac
