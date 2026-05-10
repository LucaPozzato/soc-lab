#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_STATE_DIR="$REPO_ROOT/.soc-lab"
INSTALL_STATE_FILE="$INSTALL_STATE_DIR/install-state.json"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

confirm() {
  if [[ "${SOC_LAB_ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  local prompt="$1"
  local answer
  printf "%s [y/N] " "$prompt"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

detect_platform() {
  local uname_s
  uname_s=$(uname -s 2>/dev/null || echo unknown)
  if [[ "$uname_s" == "Darwin" ]]; then
    echo "macos"
    return
  fi
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "wsl"
    return
  fi
  echo "linux"
}

run_with_sudo_if_needed() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}
