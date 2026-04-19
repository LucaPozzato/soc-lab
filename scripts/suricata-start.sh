#!/bin/bash
set -e

if ! ls /var/lib/suricata/rules/*.rules 2>/dev/null | grep -q .; then
    echo "[*] No rules found — downloading Suricata community rules (first run)..."
    suricata-update \
        --suricata-conf /etc/suricata/suricata.yaml \
        --output /var/lib/suricata/rules \
        --no-merge \
        --no-test
    # Remove rule files for protocols disabled in this build
    rm -f /var/lib/suricata/rules/dnp3-events.rules \
           /var/lib/suricata/rules/modbus-events.rules
    echo "[+] Rules downloaded."
fi

echo "[*] Suricata ready — waiting for pcap replay requests."
exec sleep infinity
