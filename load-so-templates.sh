#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
info() { echo -e "[*] $*"; }

ES_URL="${ES_URL:-http://localhost:9200}"
SO_RAW="https://raw.githubusercontent.com/Security-Onion-Solutions/securityonion/2.4/main"

REQUIRED_ECS_COMPONENTS=(
  ecs
  base
  agent
  client
  destination
  dns
  error
  event
  file
  hash
  http
  log
  network
  observer
  related
  rule
  server
  source
  suricata
  tls
  url
  user
  user_agent
)

wait_for_es() {
  for i in $(seq 1 30); do
    curl -sf "$ES_URL/_cluster/health" -o /dev/null 2>&1 && return 0
    sleep 2
  done
  die "Elasticsearch did not become ready in time"
}

put_component_template() {
  local name="$1" body="$2"
  local status
  status=$(echo "$body" | curl -s -o /dev/null -w "%{http_code}" -X PUT "$ES_URL/_component_template/$name" -H 'Content-Type: application/json' --data-binary @-)
  if [[ "$status" == "200" ]]; then
    return 0
  fi
  warn "Component template $name failed (HTTP $status)"
  return 1
}

main() {
  wait_for_es
  info "Loading SO ECS component templates..."

  local loaded=()
  local comp path name body
  for comp in "${REQUIRED_ECS_COMPONENTS[@]}"; do
    path="salt/elasticsearch/templates/component/ecs/${comp}.json"
    name="ecs.${comp}"
    body=$(curl -sf "$SO_RAW/$path") || { warn "Skip missing $path"; continue; }
    if put_component_template "$name" "$body"; then
      loaded+=("$name")
    fi
  done

  [[ ${#loaded[@]} -gt 0 ]] || die "No SO component templates were loaded"

  info "Creating suricata index template from loaded components..."
  python3 - "$ES_URL" "${loaded[@]}" << 'PY'
import json, sys, urllib.request
es = sys.argv[1]
components = sorted(sys.argv[2:])
payload = {
  "index_patterns": ["suricata-*"],
  "composed_of": components,
  "priority": 250,
  "template": {
    "settings": {
      "index.mapping.ignore_malformed": True,
      "index.mapping.total_fields.limit": 5000
    }
  }
}
req = urllib.request.Request(
  f"{es}/_index_template/suricata-so-ecs",
  data=json.dumps(payload).encode(),
  headers={"Content-Type":"application/json"},
  method="PUT",
)
with urllib.request.urlopen(req, timeout=30) as r:
  if r.status not in (200, 201):
    raise SystemExit(1)
PY

  ok "SO ECS templates loaded (${#loaded[@]} components)"
}

main "$@"
