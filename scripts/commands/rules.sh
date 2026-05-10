#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/common.sh"

cmd_reload() {
  banner "Rules Reload"
  info "Updating Suricata community rules"
  docker exec suricata suricata-update --suricata-conf /etc/suricata/suricata.yaml --output /var/lib/suricata/rules --no-merge --no-test --no-reload
  docker exec suricata rm -f /var/lib/suricata/rules/dnp3-events.rules /var/lib/suricata/rules/modbus-events.rules
  ok "Suricata community rules updated"

  info "Restarting ElastAlert2 for Sigma reconversion"
  docker restart elastalert2 >/dev/null
  ok "ElastAlert2 restarted"
}

case "${1:-}" in
  reload) cmd_reload ;;
  *) die "Usage: soc-lab rules <reload>" ;;
esac
