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

# ensure_kibana_data_view <title> [time_field] [display_name]
# Creates a Kibana data view only if one with this title does not already exist.
# Silently returns 0 if Kibana is unreachable.
ensure_kibana_data_view() {
  local title="$1" time_field="${2:-@timestamp}" name="${3:-$1}"
  local kb="http://localhost:5601"
  curl -sf "$kb/api/status" -o /dev/null 2>/dev/null || return 0
  local exists
  exists=$(curl -s "$kb/api/data_views" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    dvs = json.load(sys.stdin)
    print('yes' if any(d.get('title') == sys.argv[1] for d in dvs.get('data_view', [])) else 'no')
except Exception:
    print('no')
" "$title" 2>/dev/null || echo "no")
  [[ "$exists" == "yes" ]] && return 0
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({'data_view':{'title':sys.argv[1],'timeFieldName':sys.argv[2],'name':sys.argv[3]}}))
" "$title" "$time_field" "$name")
  curl -s -o /dev/null \
    -X POST "$kb/api/data_views/data_view" \
    -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    -d "$payload"
}
