#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$BASE_DIR/.." && pwd)"

exec "$REPO_ROOT/scripts/tools/upload-logs.sh" "$@"
