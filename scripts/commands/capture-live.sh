#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/common.sh"

INTERFACE="en0"
ROTATION_SECS=10
KEEP=false
POSITIONAL=()

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=true ;;
    -h|--help)
      echo "Usage: soc-lab capture live [interface] [rotation_seconds] [--keep]"
      exit 0
      ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

[[ "${#POSITIONAL[@]}" -ge 1 ]] && INTERFACE="${POSITIONAL[0]}"
[[ "${#POSITIONAL[@]}" -ge 2 ]] && ROTATION_SECS="${POSITIONAL[1]}"

PCAP_DIR="$REPO_ROOT/pcap/live"
QUEUE_FILE="$PCAP_DIR/.queue"
PLAYED_FILE="$PCAP_DIR/.played"
PCAP_DIR_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PCAP_DIR")"

[[ "$PCAP_DIR_REAL" == "$REPO_ROOT/pcap/live" ]] || die "Unsafe capture path resolved outside repo: $PCAP_DIR_REAL"

cleanup() {
  echo ""
  warn "Stopping live capture"
  [[ -n "${CAPTURE_PID:-}" ]] && kill "$CAPTURE_PID" 2>/dev/null || true
  wait "${CAPTURE_PID:-}" 2>/dev/null || true
  if [[ -n "${CURRENT_PCAP:-}" && -f "$CURRENT_PCAP" ]]; then
    name=$(basename "$CURRENT_PCAP")
    if ! grep -qxF "$name" "$PLAYED_FILE" 2>/dev/null; then
      info "Queueing last chunk: $name"
      enqueue_pcap "$CURRENT_PCAP"
      process_queue_once || true
    fi
  fi
  ok "Capture stopped"
  exit 0
}
trap cleanup SIGINT SIGTERM

enqueue_pcap() {
  local pcap="$1" name
  [[ -f "$pcap" ]] || return 0
  name=$(basename "$pcap")
  grep -qxF "$name" "$PLAYED_FILE" 2>/dev/null && return 0
  grep -qxF "$name" "$QUEUE_FILE" 2>/dev/null && return 0
  printf "%s\n" "$name" >> "$QUEUE_FILE"
}

dequeue_head() {
  local tmp
  tmp=$(mktemp)
  tail -n +2 "$QUEUE_FILE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$QUEUE_FILE"
}

process_queue_once() {
  local name pcap
  name=$(head -n 1 "$QUEUE_FILE" 2>/dev/null || true)
  [[ -n "$name" ]] || return 1
  pcap="$PCAP_DIR/$name"
  if [[ ! -f "$pcap" ]]; then
    dequeue_head
    return 0
  fi

  info "Replay chunk: $name"
  if docker exec suricata suricata -c /etc/suricata/suricata.yaml -r "/pcap/live/$name" --pidfile /var/run/suricata-replay.pid -l /var/log/suricata -k none 2>/dev/null; then
    printf "%s\n" "$name" >> "$PLAYED_FILE"
    dequeue_head
    ok "Indexed: $name"
    return 0
  fi
  return 1
}

ensure_alert_aliases() {
  curl -s -X PUT "http://localhost:9200/_index_template/suricata-soc-alerts" -H 'Content-Type: application/json' -d '{"index_patterns":["suricata-*"],"template":{"aliases":{"soc-alerts":{"filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}}}}' >/dev/null 2>&1 || true
  for _ in $(seq 1 5); do
    curl -s -X POST "http://localhost:9200/_aliases" -H 'Content-Type: application/json' -d '{"actions":[{"remove":{"index":"suricata-*","alias":"soc-alerts","must_exist":false}},{"add":{"index":"suricata-*","alias":"soc-alerts","filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}]}' >/dev/null 2>&1 || true
    curl -s "http://localhost:9200/_cat/aliases/soc-alerts?h=index" 2>/dev/null | grep -q '^suricata-' && break
    sleep 1
  done
  if curl -s "http://localhost:9200/_cat/indices/elastalert2_alerts?h=index" | grep -q '^elastalert2_alerts$'; then
    curl -s -X POST "http://localhost:9200/_aliases" -H 'Content-Type: application/json' -d '{"actions":[{"add":{"index":"elastalert2_alerts","alias":"soc-alerts"}}]}' >/dev/null 2>&1 || true
  fi
}

require_cmd dumpcap
docker exec suricata true >/dev/null 2>&1 || die "Suricata container not running (use: soc-lab stack start)"
curl -s "http://localhost:9200/_cluster/health" >/dev/null 2>&1 || die "Elasticsearch not reachable"

platform=$(detect_platform)
if ! dumpcap -D >/dev/null 2>&1; then
  if [[ "$platform" == "wsl" ]]; then
    die "dumpcap permission denied on WSL. Fix with: sudo usermod -aG wireshark \"$USER\" && newgrp wireshark. If it still fails, run: sudo setcap -r /usr/bin/dumpcap and use sudo capture mode."
  fi
  die "dumpcap is not usable by current user. Run 'dumpcap -D' to verify permissions."
fi

mkdir -p "$PCAP_DIR"
[[ -w "$PCAP_DIR" ]] || die "Capture directory is not writable: $PCAP_DIR"
rm -f "$PCAP_DIR"/capture_*.pcap "$PCAP_DIR"/capture_*.pcapng "$PCAP_DIR"/capture.pcapng "$QUEUE_FILE" "$PLAYED_FILE"
touch "$QUEUE_FILE" "$PLAYED_FILE"

if [[ "$KEEP" == "false" ]]; then
  section "Resetting session data"
  info "Deleting suricata indices"
  curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | xargs -I{} curl -s -X DELETE "http://localhost:9200/{}" >/dev/null || true
  info "Clearing ElastAlert2 alert indices"
  dq='{"query":{"match_all":{}}}'
  for idx in elastalert2_alerts elastalert2_alerts_status elastalert2_alerts_silence; do
    curl -s -X POST "http://localhost:9200/${idx}/_delete_by_query" -H 'Content-Type: application/json' -d "$dq" >/dev/null 2>&1 || true
  done
  info "Restarting ElastAlert2"
  docker restart elastalert2 >/dev/null 2>&1 || true
  info "Clearing Suricata logs"
  docker exec suricata sh -c ': > /var/log/suricata/eve.json; : > /var/log/suricata/suricata.log' 2>/dev/null || true
  ok "Session reset complete"
else
  section "Keep mode"
  info "Preserving previous indexed data"
fi

ensure_alert_aliases

banner "Live Capture"
info "Interface: $INTERFACE"
info "Rotation: ${ROTATION_SECS}s"
info "Kibana: http://localhost:5601"

capture_loop() {
  dumpcap -q -i "$INTERFACE" -b "duration:$ROTATION_SECS" -b files:50 -w "$PCAP_DIR/capture.pcapng"
}

capture_loop &
CAPTURE_PID=$!

backoff=1
while kill -0 "$CAPTURE_PID" 2>/dev/null; do
  current=$(ls -t "$PCAP_DIR"/capture_*.pcapng 2>/dev/null | head -n 1 || true)
  [[ -n "$current" ]] && CURRENT_PCAP="$current"
  pcaps=("$PCAP_DIR"/capture_*.pcapng)
  if [[ -e "${pcaps[0]}" ]]; then
    while IFS= read -r pcap; do
      [[ -n "$pcap" ]] || continue
      [[ "$pcap" == "$CURRENT_PCAP" ]] && continue
      enqueue_pcap "$pcap"
    done < <(ls -1tr "$PCAP_DIR"/capture_*.pcapng 2>/dev/null || true)
  fi

  while process_queue_once; do
    backoff=1
  done

  if [[ -s "$QUEUE_FILE" ]]; then
    warn "Replay failed; retrying in ${backoff}s"
    sleep "$backoff"
    if [[ "$backoff" -lt 10 ]]; then
      backoff=$((backoff * 2))
      [[ "$backoff" -gt 10 ]] && backoff=10
    fi
    continue
  fi

  sleep 2
done
