#!/bin/bash
set -euo pipefail

INTERFACE="en0"
ROTATION_SECS=10
KEEP=false
POSITIONAL=()

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: ./live-capture.sh [interface] [rotation_seconds] [--keep]"
      echo ""
      echo "Arguments:"
      echo "  interface          Network interface to capture on (default: en0)"
      echo "  rotation_seconds   How often to rotate the PCAP file (default: 10)"
      echo "  --keep             Preserve existing Suricata data in ES instead of wiping"
      echo ""
      echo "Examples:"
      echo "  ./live-capture.sh                  # capture on en0, rotate every 10s"
      echo "  ./live-capture.sh en0 30           # rotate every 30s"
      echo "  ./live-capture.sh en1 120 --keep   # keep previous session data"
      echo ""
      echo "Notes:"
      echo "  - Requires the stack to be running: ./docker.sh start"
      echo "  - Captured PCAPs are saved to pcap/live/"
      echo "  - Events appear in Kibana at http://localhost:5601 with a ~rotation_seconds delay"
      echo "  - Ctrl+C stops capture; indexed events remain in Kibana"
      exit 0
      ;;
    --keep) KEEP=true ;;
    *)      POSITIONAL+=("$arg") ;;
  esac
done

[ "${#POSITIONAL[@]}" -ge 1 ] && INTERFACE="${POSITIONAL[0]}"
[ "${#POSITIONAL[@]}" -ge 2 ] && ROTATION_SECS="${POSITIONAL[1]}"
PCAP_DIR="./pcap/live"
REPLAYED="$PCAP_DIR/.replayed"

log() { echo "[$(date +%H:%M:%S)] $*"; }

cleanup() {
    echo ""
    log "Stopping capture..."
    [ -n "${CAPTURE_PID:-}" ] && kill "$CAPTURE_PID" 2>/dev/null || true
    wait "${CAPTURE_PID:-}" 2>/dev/null || true
    log "Stopped. Events from this session remain in Kibana."
    exit 0
}
trap cleanup SIGINT SIGTERM

# ---- prereqs ----
command -v tcpdump >/dev/null 2>&1 || { echo "ERROR: tcpdump not found"; exit 1; }
docker exec suricata true 2>/dev/null || { echo "ERROR: Suricata container not running — run ./docker.sh start first"; exit 1; }
curl -s "http://localhost:9200/_cluster/health" >/dev/null 2>&1 || { echo "ERROR: Elasticsearch not reachable — run ./docker.sh start first"; exit 1; }

# ---- clean slate ----
mkdir -p "$PCAP_DIR"
rm -f "$PCAP_DIR"/capture_*.pcap "$REPLAYED"

if [ "$KEEP" = "false" ]; then
    log "Clearing previous session..."
    curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | \
        xargs -I{} curl -s -X DELETE "http://localhost:9200/{}" >/dev/null
    docker stop filebeat >/dev/null 2>&1 || true
    docker exec suricata sh -c 'rm -f /var/log/suricata/eve.json /var/log/suricata/suricata.log' 2>/dev/null || true
else
    log "Keeping existing data (--keep)..."
    docker stop filebeat >/dev/null 2>&1 || true
fi
docker start filebeat >/dev/null

echo ""
log "Capturing on $INTERFACE, rotating every ${ROTATION_SECS}s."
log "Kibana: http://localhost:5601  |  Ctrl+C to stop"
echo ""

# ---- capture loop (background) ----
# -G exits after one rotation on WSL — restart immediately to minimise gap.
capture_loop() {
    while true; do
        sudo tcpdump -i "$INTERFACE" \
            -G "$ROTATION_SECS" \
            -w "$PCAP_DIR/capture_%Y%m%d_%H%M%S.pcap" \
            2>/dev/null || true
    done
}
capture_loop &
CAPTURE_PID=$!

# ---- watch loop ----
while kill -0 "$CAPTURE_PID" 2>/dev/null; do
    pcaps=()
    while IFS= read -r f; do pcaps+=("$f"); done < <(ls -t "$PCAP_DIR"/capture_*.pcap 2>/dev/null || true)

    # Skip index 0 — tcpdump is still writing it
    for ((i=${#pcaps[@]}-1; i>=1; i--)); do
        pcap="${pcaps[$i]}"
        name=$(basename "$pcap")
        if ! grep -qxF "$name" "$REPLAYED" 2>/dev/null; then
            log "New rotation: $name — running through Suricata..."
            docker exec suricata suricata \
                -c /etc/suricata/suricata.yaml \
                -r "/pcap/live/$name" \
                --pidfile /var/run/suricata-replay.pid \
                -l /var/log/suricata \
                -k none \
                2>/dev/null
            echo "$name" >> "$REPLAYED"
            log "Done: $name → events shipping to Kibana"
        fi
    done

    sleep 2
done

log "Capture process exited."
