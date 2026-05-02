#!/bin/bash
set -e

echo "======================================"
echo " Reloading Suricata Rules"
echo "======================================"

echo "[*] Running suricata-update to fetch latest community rules..."
docker exec suricata suricata-update \
  --suricata-conf /etc/suricata/suricata.yaml \
  --output /var/lib/suricata/rules \
  --no-merge \
  --no-test
docker exec suricata rm -f \
  /var/lib/suricata/rules/dnp3-events.rules \
  /var/lib/suricata/rules/modbus-events.rules

echo "[*] Custom rules in ./rules/suricata/:"
ls ./rules/suricata/*.rules 2>/dev/null && echo "" || echo "  (none found — add .rules files to ./rules/suricata/)"

echo "[+] Rules updated. Next replay will use the latest ruleset."
echo "======================================"
