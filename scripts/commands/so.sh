#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADERS_DIR="$(cd "$BASE_DIR/.." && pwd)/loaders"

case "${1:-}" in
  pipelines)
    exec bash "$LOADERS_DIR/so-pipelines.sh"
    ;;
  templates)
    exec bash "$LOADERS_DIR/so-templates.sh"
    ;;
  sync)
    bash "$LOADERS_DIR/so-templates.sh"
    bash "$LOADERS_DIR/so-pipelines.sh"
    ;;
  *)
    echo "Usage: soc-lab so <sync|pipelines|templates>"
    exit 1
    ;;
esac
