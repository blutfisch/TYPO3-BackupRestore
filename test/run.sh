#!/usr/bin/env bash
# Runs the end-to-end test (backup -> S3 -> restore) in Docker and cleans up afterwards.
set -euo pipefail
cd "$(dirname "$0")"
trap 'docker compose down -v --remove-orphans >/dev/null 2>&1' EXIT
docker compose run --rm --build runner
