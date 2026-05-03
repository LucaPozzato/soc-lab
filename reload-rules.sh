#!/bin/bash
set -e

echo "======================================"
echo " Reloading Rules"
echo "======================================"

echo "[*] Running suricata-update to fetch latest community rules..."
docker exec suricata suricata-update \
  --suricata-conf /etc/suricata/suricata.yaml \
  --output /var/lib/suricata/rules \
  --no-merge \
  --no-test \
  --no-reload
docker exec suricata rm -f \
  /var/lib/suricata/rules/dnp3-events.rules \
  /var/lib/suricata/rules/modbus-events.rules

echo "[*] Custom Suricata rules in ./rules/suricata/:"
ls ./rules/suricata/*.rules 2>/dev/null && echo "" || echo "  (none)"

echo "[*] Restarting ElastAlert2 to re-convert Sigma rules..."
echo "[*] Sigma rules in ./rules/sigma/:"
ls ./rules/sigma/*.yml 2>/dev/null && echo "" || echo "  (none)"
docker restart elastalert2 >/dev/null
echo "[+] ElastAlert2 restarted — sigma rules reloaded."

echo ""
echo "[+] All rules reloaded."
echo "======================================"
