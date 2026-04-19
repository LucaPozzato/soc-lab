#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ./live-capture.sh [interface] [rotation_seconds]"
    echo ""
    echo "Arguments:"
    echo "  interface          Network interface to capture on (default: en0)"
    echo "  rotation_seconds   How often to rotate the PCAP file (default: 10)"
    echo ""
    echo "Examples:"
    echo "  ./live-capture.sh                  # capture on en0, rotate every 10s"
    echo "  ./live-capture.sh en0 30           # rotate every 30s"
    echo "  ./live-capture.sh en1 120          # different interface, 2-minute rotations"
    echo ""
    echo "Notes:"
    echo "  - Requires the stack to be running: ./start.sh"
    echo "  - Captured PCAPs are saved to pcap/live/"
    echo "  - Events appear in Kibana at http://localhost:5601 with a ~rotation_seconds delay"
    echo "  - Ctrl+C stops capture; indexed events remain in Kibana"
    exit 0
fi

INTERFACE="${1:-en0}"
ROTATION_SECS="${2:-10}"
PCAP_DIR="./pcap/live"
REPLAYED="$PCAP_DIR/.replayed"

log() { echo "[$(date +%H:%M:%S)] $*"; }

cleanup() {
    echo ""
    log "Stopping live capture..."
    [ -n "${TCPDUMP_PID:-}" ] && sudo kill "$TCPDUMP_PID" 2>/dev/null || true
    wait "${TCPDUMP_PID:-}" 2>/dev/null || true
    log "Stopped. Events from this session remain in Kibana."
    exit 0
}
trap cleanup SIGINT SIGTERM

# ---- prereqs ----
command -v tcpdump >/dev/null 2>&1 || { echo "ERROR: tcpdump not found"; exit 1; }
docker exec suricata true 2>/dev/null || { echo "ERROR: Suricata container not running — run ./start.sh first"; exit 1; }
curl -s "http://localhost:9200/_cluster/health" >/dev/null 2>&1 || { echo "ERROR: Elasticsearch not reachable — run ./start.sh first"; exit 1; }

# ---- clean slate ----
log "Clearing previous session..."
mkdir -p "$PCAP_DIR"
rm -f "$PCAP_DIR"/capture_*.pcap "$REPLAYED"

curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | \
    xargs -I{} curl -s -X DELETE "http://localhost:9200/{}" >/dev/null

docker stop filebeat >/dev/null 2>&1 || true
docker exec suricata sh -c 'rm -f /var/log/suricata/eve.json /var/log/suricata/suricata.log' 2>/dev/null || true
docker start filebeat >/dev/null

# ---- start tcpdump ----
log "Starting tcpdump (may prompt for sudo password)..."
sudo tcpdump -i "$INTERFACE" \
    -G "$ROTATION_SECS" \
    -w "$PCAP_DIR/capture_%Y%m%d_%H%M%S.pcap" \
    2>/dev/null &
TCPDUMP_PID=$!

echo ""
log "Capturing on $INTERFACE, rotating every ${ROTATION_SECS}s."
log "Kibana: http://localhost:5601  |  Ctrl+C to stop"
echo ""

# ---- watch loop ----
while kill -0 "$TCPDUMP_PID" 2>/dev/null; do
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

log "tcpdump exited."
