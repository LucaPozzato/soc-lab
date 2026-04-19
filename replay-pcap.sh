#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: ./replay-pcap.sh pcap/<filename.pcap>"
  echo "Files available:"
  ls ./pcap/*.pcap 2>/dev/null || echo "  (none found)"
  exit 1
fi

PCAP_FILE="$1"
PCAP_NAME=$(basename "$1")

if [ ! -f "$PCAP_FILE" ]; then
  echo "ERROR: $PCAP_FILE not found"
  exit 1
fi

echo "======================================"
echo " Replaying: $PCAP_NAME"
echo "======================================"

echo "[*] Clearing previous logs and index..."
curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | \
  xargs -I{} curl -s -X DELETE "http://localhost:9200/{}" >/dev/null
docker stop filebeat >/dev/null
docker exec suricata sh -c 'rm -f /var/log/suricata/eve.json /var/log/suricata/suricata.log'

echo "[*] Sending pcap to Suricata..."
docker exec suricata suricata \
  -c /etc/suricata/suricata.yaml \
  -r /pcap/$PCAP_NAME \
  --pidfile /var/run/suricata-replay.pid \
  -l /var/log/suricata \
  -k none
echo "[+] Suricata done. Starting filebeat to ship events..."
docker start filebeat >/dev/null

echo ""
echo "======================================"
echo " Replay complete. Logs shipping to Elasticsearch via Filebeat."
echo " Open Kibana at http://localhost:5601"
echo "======================================"
