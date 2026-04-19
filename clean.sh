#!/bin/bash
set -e

echo "[*] Clearing ES indices..."
curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | \
    xargs -I{} curl -s -X DELETE "http://localhost:9200/{}" >/dev/null

echo "[*] Clearing Suricata logs..."
docker stop filebeat >/dev/null 2>&1 || true
docker exec suricata sh -c 'rm -f /var/log/suricata/eve.json /var/log/suricata/suricata.log' 2>/dev/null || true
docker start filebeat >/dev/null

echo "[+] Done."
