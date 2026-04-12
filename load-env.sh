#!/usr/bin/env bash
# Source this file to load variables from .env into the environment.
# Requires CLAWKEY_DIR to be set before sourcing.
# Variables already set in the environment take precedence over file values.

if [ -z "${CLAWKEY_DIR:-}" ]; then
    echo "Error: CLAWKEY_DIR must be set before sourcing load-env.sh"
    return 1 2>/dev/null || exit 1
fi

_env_file="${CLAWKEY_DIR}/.env"

if [ ! -f "$_env_file" ]; then
    echo "Error: ${_env_file} not found. Run: ./clawkey config"
    return 1 2>/dev/null || exit 1
fi

while IFS= read -r _line || [ -n "$_line" ]; do
    # Skip comments and blank lines
    [[ -z "$_line" || "$_line" == \#* ]] && continue
    _key="${_line%%=*}"
    _val="${_line#*=}"
    # Only export if not already set in the environment
    if [ -z "${!_key+x}" ]; then
        export "$_key=$_val"
    fi
done < "$_env_file"

unset _env_file _line _key _val
