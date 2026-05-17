#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$BASE_DIR/.." && pwd)"

if ! command -v go >/dev/null 2>&1; then
  echo "[x] Go is required for Bubble Tea TUI (install Go 1.22+)" >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  echo "[*] Running Bubble Tea TUI as $SUDO_USER (root not required)"
  exec sudo -u "$SUDO_USER" -E go -C "$REPO_ROOT/tui" run ./cmd/soclabtui
fi

exec go -C "$REPO_ROOT/tui" run ./cmd/soclabtui
