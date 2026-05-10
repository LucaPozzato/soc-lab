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
REPLAYED="$PCAP_DIR/.replayed"

cleanup() {
  echo ""
  warn "Stopping live capture"
  [[ -n "${CAPTURE_PID:-}" ]] && kill "$CAPTURE_PID" 2>/dev/null || true
  wait "${CAPTURE_PID:-}" 2>/dev/null || true
  if [[ -n "${CURRENT_PCAP:-}" && -f "$CURRENT_PCAP" ]]; then
    name=$(basename "$CURRENT_PCAP")
    if ! grep -qxF "$name" "$REPLAYED" 2>/dev/null; then
      info "Finalizing last chunk: $name"
      process_pcap "$CURRENT_PCAP" || true
    fi
  fi
  ok "Capture stopped"
  exit 0
}
trap cleanup SIGINT SIGTERM

process_pcap() {
  local pcap="$1" name
  name=$(basename "$pcap")
  [[ -f "$pcap" ]] || return 0
  grep -qxF "$name" "$REPLAYED" 2>/dev/null && return 0
  info "Replay chunk: $name"
  docker exec suricata suricata -c /etc/suricata/suricata.yaml -r "/pcap/live/$name" --pidfile /var/run/suricata-replay.pid -l /var/log/suricata -k none 2>/dev/null
  echo "$name" >> "$REPLAYED"
  ok "Indexed: $name"
}

require_cmd tcpdump
docker exec suricata true >/dev/null 2>&1 || die "Suricata container not running (use: soc-lab stack start)"
curl -s "http://localhost:9200/_cluster/health" >/dev/null 2>&1 || die "Elasticsearch not reachable"

mkdir -p "$PCAP_DIR"
rm -f "$PCAP_DIR"/capture_*.pcap "$REPLAYED"

if [[ "$KEEP" == "false" ]]; then
  section "Resetting session data"
  curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | xargs -I{} curl -s -X DELETE "http://localhost:9200/{}" >/dev/null || true
  docker exec suricata sh -c ': > /var/log/suricata/eve.json; : > /var/log/suricata/suricata.log' 2>/dev/null || true
else
  section "Keep mode"
  info "Preserving previous indexed data"
fi

banner "Live Capture"
info "Interface: $INTERFACE"
info "Rotation: ${ROTATION_SECS}s"
info "Kibana: http://localhost:5601"

capture_loop() {
  while true; do
    sudo tcpdump -i "$INTERFACE" -U -G "$ROTATION_SECS" -w "$PCAP_DIR/capture_%Y%m%d_%H%M%S.pcap" 2>/dev/null || true
    sleep 0.2
  done
}

capture_loop &
CAPTURE_PID=$!

while kill -0 "$CAPTURE_PID" 2>/dev/null; do
  current=$(ls -t "$PCAP_DIR"/capture_*.pcap 2>/dev/null | head -n 1 || true)
  [[ -n "$current" ]] && CURRENT_PCAP="$current"
  pcaps=("$PCAP_DIR"/capture_*.pcap)
  if [[ -e "${pcaps[0]}" ]]; then
    for pcap in "${pcaps[@]}"; do
      [[ "$pcap" == "$CURRENT_PCAP" ]] && continue
      process_pcap "$pcap"
    done
  fi
  sleep 2
done
