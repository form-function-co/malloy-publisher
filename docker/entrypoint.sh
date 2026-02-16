#!/bin/bash
set -e

# Cloud Run injects PORT env var (typically 8080).
# Map it to PUBLISHER_PORT so the server binds to the right port.
if [ -n "$PORT" ]; then
  export PUBLISHER_PORT="$PORT"
fi

# Ensure PUBLISHER_HOST binds to all interfaces (required for Cloud Run)
export PUBLISHER_HOST="${PUBLISHER_HOST:-0.0.0.0}"

exec "$@"
