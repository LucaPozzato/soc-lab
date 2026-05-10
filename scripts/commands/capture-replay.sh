#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/common.sh"

ensure_soc_alerts_alias() {
  curl -s -X PUT "http://localhost:9200/_index_template/suricata-soc-alerts" -H 'Content-Type: application/json' -d '{"index_patterns":["suricata-*"],"template":{"aliases":{"soc-alerts":{"filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}}}}' >/dev/null 2>&1

  for _ in $(seq 1 60); do
    curl -s -X POST "http://localhost:9200/_aliases" -H 'Content-Type: application/json' -d '{"actions":[{"add":{"index":"suricata-*","alias":"soc-alerts","filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}]}' >/dev/null 2>&1 || true
    curl -s "http://localhost:9200/_cat/aliases/soc-alerts?h=index" 2>/dev/null | grep -q '^suricata-' && break
    sleep 1
  done

  if curl -s "http://localhost:9200/_cat/indices/elastalert2_alerts?h=index" | grep -q '^elastalert2_alerts$'; then
    curl -s -X POST "http://localhost:9200/_aliases" -H 'Content-Type: application/json' -d '{"actions":[{"add":{"index":"elastalert2_alerts","alias":"soc-alerts"}}]}' >/dev/null 2>&1 || true
  fi
}

NOW_MODE=false
KEEP=false
PCAP_FILE=""
for arg in "$@"; do
  case "$arg" in
    --now) NOW_MODE=true ;;
    --keep) KEEP=true ;;
    *) PCAP_FILE="$arg" ;;
  esac
done

[[ -n "$PCAP_FILE" ]] || die "Usage: soc-lab capture replay <pcap-file> [--now] [--keep]"

PCAP_DIR="$REPO_ROOT/pcap"
if [[ "$PCAP_FILE" == /* ]]; then
  PCAP_ABS="$PCAP_FILE"
elif [[ "$PCAP_FILE" == pcap/* ]]; then
  PCAP_ABS="$REPO_ROOT/$PCAP_FILE"
elif [[ "$PCAP_FILE" == ./pcap/* ]]; then
  PCAP_ABS="$REPO_ROOT/${PCAP_FILE#./}"
else
  PCAP_ABS="$PCAP_DIR/$PCAP_FILE"
fi

[[ -f "$PCAP_ABS" ]] || die "PCAP not found: $PCAP_ABS"
PCAP_ABS="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PCAP_ABS")"
PCAP_DIR_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PCAP_DIR")"
[[ "$PCAP_ABS" == "$PCAP_DIR_REAL"/* ]] || die "PCAP must be inside ./pcap"
PCAP_REL="${PCAP_ABS#$PCAP_DIR_REAL/}"
PCAP_NAME="$(basename "$PCAP_ABS")"

banner "Replay Capture"
info "PCAP: $PCAP_NAME"
[[ "$NOW_MODE" == "true" ]] && info "Timestamp mode: now-shift"

if [[ "$KEEP" == "false" ]]; then
  section "Resetting Replay State"
  curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | xargs -I{} curl -s -X DELETE "http://localhost:9200/{}" >/dev/null || true
  dq='{"query":{"match_all":{}}}'
  for idx in elastalert2_alerts elastalert2_alerts_status elastalert2_alerts_silence; do
    curl -s -X POST "http://localhost:9200/${idx}/_delete_by_query" -H 'Content-Type: application/json' -d "$dq" >/dev/null 2>&1 || true
  done
  docker stop elastalert2 >/dev/null || true
  docker exec suricata sh -c ': > /var/log/suricata/eve.json; : > /var/log/suricata/suricata.log'
else
  section "Keep Mode"
  info "Preserving existing indexed data and existing alerts"
fi

section "Running Suricata Replay"
ensure_soc_alerts_alias
docker exec suricata suricata -c /etc/suricata/suricata.yaml -r /pcap/$PCAP_REL --pidfile /var/run/suricata-replay.pid -l /var/log/suricata -k none

if [[ "$NOW_MODE" == "true" ]]; then
  section "Shifting Timestamps"
  python3 - <<'PY'
import json
from datetime import datetime, timezone
eve = "docker-logs/suricata/eve.json"
fmt = "%Y-%m-%dT%H:%M:%S.%f+0000"
events=[]
with open(eve) as f:
  for ln in f:
    ln=ln.strip()
    if not ln: continue
    try: events.append(json.loads(ln))
    except Exception: events.append(ln)
earliest=None
for e in events:
  if not isinstance(e,dict): continue
  try:
    ts=datetime.fromisoformat(e.get("timestamp","").replace("+0000","+00:00"))
    earliest = ts if earliest is None or ts<earliest else earliest
  except Exception:
    pass
if earliest is not None:
  offset=datetime.now(timezone.utc)-earliest
  for e in events:
    if not isinstance(e,dict): continue
    try:
      ts=datetime.fromisoformat(e.get("timestamp","").replace("+0000","+00:00"))
      e["timestamp"]=(ts+offset).strftime(fmt)
    except Exception:
      pass
with open(eve,"w") as f:
  for e in events: f.write((json.dumps(e) if isinstance(e,dict) else e)+"\n")
PY
  ok "Timestamp shift complete"
fi

section "Ensuring Alerts Alias"
ensure_soc_alerts_alias

if [[ "$KEEP" == "false" ]]; then
  section "Restarting ElastAlert2"
  docker start elastalert2 >/dev/null
  ok "ElastAlert2 restarted for clean replay scan"
fi

section "Replay Complete"
ok "Replay processed successfully"
info "Events shipping via Filebeat"
info "Kibana: http://localhost:5601"

for _ in $(seq 1 30); do
  if curl -s "http://localhost:9200/_cat/aliases/soc-alerts?h=index" 2>/dev/null | grep -q '^suricata-'; then
    break
  fi
  sleep 1
done

section "Replay Index Status"
for _ in $(seq 1 60); do
  suri_count="$(curl -s "http://localhost:9200/suricata-*/_count" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)"
  alert_count="$(curl -s "http://localhost:9200/suricata-*/_count?q=event.dataset:suricata.alert" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)"
  merged_count="$(curl -s "http://localhost:9200/soc-alerts/_count" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)"

  if [[ "$suri_count" -gt 0 || "$alert_count" -gt 0 || "$merged_count" -gt 0 ]]; then
    ok "suricata-* docs: $suri_count"
    ok "suricata alerts: $alert_count"
    ok "soc-alerts docs: $merged_count"
    exit 0
  fi
  sleep 1
done

warn "No docs visible yet in suricata-* or soc-alerts (Filebeat may still be shipping)"
