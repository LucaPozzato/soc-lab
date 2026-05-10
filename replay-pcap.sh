#!/bin/bash
set -e

# Parse args — accept pcap path and optional flags in any order
NOW_MODE=false
KEEP=false
PCAP_FILE=""
for arg in "$@"; do
  case "$arg" in
    --now)  NOW_MODE=true ;;
    --keep) KEEP=true ;;
    *)      PCAP_FILE="$arg" ;;
  esac
done

if [ -z "$PCAP_FILE" ]; then
  echo "Usage: ./replay-pcap.sh <pcap-file> [--now] [--keep]"
  echo ""
  echo "  --now    Shift all event timestamps to now (optional)."
  echo "           Without --now, original packet timestamps are preserved."
  echo "  --keep   Preserve existing Suricata/ElastAlert2 data in ES."
  echo "           Without --keep, previous replay data is wiped first."
  echo ""
  echo "Files available:"
  ls ./pcap/*.pcap 2>/dev/null || echo "  (none found)"
  exit 1
fi

PCAP_DIR="$(cd "$(dirname "$0")/pcap" && pwd)"

if [[ "$PCAP_FILE" == /* ]]; then
  PCAP_ABS="$PCAP_FILE"
elif [[ "$PCAP_FILE" == pcap/* ]]; then
  PCAP_ABS="$(cd "$(dirname "$0")" && pwd)/$PCAP_FILE"
elif [[ "$PCAP_FILE" == ./pcap/* ]]; then
  PCAP_ABS="$(cd "$(dirname "$0")" && pwd)/${PCAP_FILE#./}"
else
  PCAP_ABS="$PCAP_DIR/$PCAP_FILE"
fi

if [ ! -f "$PCAP_ABS" ]; then
  echo "ERROR: $PCAP_ABS not found"
  exit 1
fi

PCAP_ABS="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PCAP_ABS")"
PCAP_DIR_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PCAP_DIR")"
if [[ "$PCAP_ABS" != "$PCAP_DIR_REAL"/* ]]; then
  echo "ERROR: PCAP must be inside ./pcap (subdirectories are allowed)"
  exit 1
fi

PCAP_REL="${PCAP_ABS#$PCAP_DIR_REAL/}"
PCAP_NAME="$(basename "$PCAP_ABS")"

echo "======================================"
echo " Replaying: $PCAP_NAME"
[ "$NOW_MODE" = "true" ] && echo " Timestamps: shifted to now"
echo "======================================"

if [ "$KEEP" = "false" ]; then
  echo "[*] Clearing previous logs and indices..."
  curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | \
    xargs -I{} curl -s -X DELETE "http://localhost:9200/{}" >/dev/null
  # Delete documents but keep indices — dropping them causes ElastAlert2 to
  # error on missing mappings. Silence must also be cleared so the rule can
  # re-fire after a replay. ElastAlert2 is restarted so its in-memory scan
  # window resets; clearing the status index alone doesn't work while it runs.
  DQ='{"query":{"match_all":{}}}'
  for idx in elastalert2_alerts elastalert2_alerts_status elastalert2_alerts_silence; do
    curl -s -X POST "http://localhost:9200/${idx}/_delete_by_query" \
        -H 'Content-Type: application/json' -d "$DQ" >/dev/null 2>&1 || true
  done
  # Restart ElastAlert2 only for clean replays so its in-memory scan window
  # resets and it rescans from scratch.
  docker stop elastalert2 >/dev/null
  docker exec suricata sh -c ': > /var/log/suricata/eve.json; : > /var/log/suricata/suricata.log'
else
  echo "[*] Keeping existing data (--keep)..."
  # Keep ElastAlert2 running so existing alerts in elastalert2_alerts remain.
fi

echo "[*] Sending pcap to Suricata..."
docker exec suricata suricata \
  -c /etc/suricata/suricata.yaml \
  -r /pcap/$PCAP_REL \
  --pidfile /var/run/suricata-replay.pid \
  -l /var/log/suricata \
  -k none

if [ "$NOW_MODE" = "true" ]; then
  echo "[*] Shifting timestamps to now..."
  python3 - <<'EOF'
import json
from datetime import datetime, timezone, timedelta

eve = "docker-logs/suricata/eve.json"
TS_FMT = "%Y-%m-%dT%H:%M:%S.%f+0000"

events = []
with open(eve) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                events.append(json.loads(line))
            except Exception:
                events.append(line)

# Find the earliest timestamp so we can anchor the whole trace to now
# while preserving relative timing between events.
earliest = None
for e in events:
    if not isinstance(e, dict):
        continue
    raw = e.get("timestamp", "")
    try:
        ts = datetime.fromisoformat(raw.replace("+0000", "+00:00"))
        if earliest is None or ts < earliest:
            earliest = ts
    except Exception:
        pass

if earliest is None:
    print("  No timestamps found — nothing to shift.")
else:
    now = datetime.now(timezone.utc)
    offset = now - earliest
    count = 0
    for e in events:
        if not isinstance(e, dict):
            continue
        raw = e.get("timestamp", "")
        try:
            ts = datetime.fromisoformat(raw.replace("+0000", "+00:00"))
            e["timestamp"] = (ts + offset).strftime(TS_FMT)
            count += 1
        except Exception:
            pass
    print(f"  Shifted {count} events by {int(offset.total_seconds())}s")

with open(eve, "w") as f:
    for e in events:
        f.write((json.dumps(e) if isinstance(e, dict) else e) + "\n")
EOF
fi

if [ "$KEEP" = "false" ]; then
  echo "[+] Suricata done. Starting elastalert2..."
else
  echo "[+] Suricata done. ElastAlert2 kept running (--keep)."
fi

# Ensure template + alias survive volume wipes and are in place before Filebeat
# creates the new suricata-* index (template applies at index-creation time).
curl -s -X PUT "http://localhost:9200/_index_template/suricata-soc-alerts" \
  -H 'Content-Type: application/json' \
  -d '{"index_patterns":["suricata-*"],"template":{"aliases":{"soc-alerts":{"filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}}}}' \
  >/dev/null 2>&1

curl -s -X POST "http://localhost:9200/_aliases" \
  -H 'Content-Type: application/json' \
  -d '{"actions":[{"remove":{"index":"suricata-*","alias":"soc-alerts"}}]}' >/dev/null 2>&1 || true
curl -s -X POST "http://localhost:9200/_aliases" \
  -H 'Content-Type: application/json' \
  -d '{"actions":[{"add":{"index":"suricata-*","alias":"soc-alerts","filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}]}' >/dev/null 2>&1 || true
curl -s -X POST "http://localhost:9200/_aliases" \
  -H 'Content-Type: application/json' \
  -d '{"actions":[{"add":{"index":"elastalert2_alerts","alias":"soc-alerts"}}]}' >/dev/null 2>&1 || true

if [ "$KEEP" = "false" ]; then
  docker start elastalert2 >/dev/null
fi

# Re-attach Suricata side of soc-alerts after suricata-* index exists.
for i in $(seq 1 30); do
  if curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | grep -q '^suricata-'; then
    curl -s -X POST "http://localhost:9200/_aliases" \
      -H 'Content-Type: application/json' \
      -d '{"actions":[{"remove":{"index":"suricata-*","alias":"soc-alerts"}}]}' >/dev/null 2>&1 || true
    curl -s -X POST "http://localhost:9200/_aliases" \
      -H 'Content-Type: application/json' \
      -d '{"actions":[{"add":{"index":"suricata-*","alias":"soc-alerts","filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}]}' >/dev/null 2>&1 || true
    break
  fi
  sleep 1
done

echo ""
echo "======================================"
echo " Replay complete."
echo " Events shipping to Elasticsearch via Filebeat."
echo " ElastAlert2 will fire within ~30s."
echo " Open Kibana at http://localhost:5601"
echo "======================================"
