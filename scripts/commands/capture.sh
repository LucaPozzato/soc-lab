#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  replay)
    shift
    exec "$BASE_DIR/capture-replay.sh" "$@"
    ;;
  live)
    shift
    exec "$BASE_DIR/capture-live.sh" "$@"
    ;;
  upload)
    shift
    exec "$BASE_DIR/capture-upload.sh" "$@"
    ;;
  *)
    echo "Usage: soc-lab capture <replay|live|upload> ..."
    exit 1
    ;;
esac
