#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/lib/log.sh"

banner "SOC Lab Health"
section "Containers"
docker compose ps

section "Elasticsearch"
curl -s http://localhost:9200/_cluster/health?pretty | grep status || true
curl -s http://localhost:9200/_cat/indices?v | grep suricata || echo "No suricata indices yet"

section "Filebeat"
docker logs filebeat 2>&1 | tail -10

section "Suricata"
tail -3 ./docker-logs/suricata/eve.json 2>/dev/null || echo "No events yet"

section "ElastAlert2"
curl -s "http://localhost:9200/elastalert2_alerts/_count" 2>/dev/null | grep -o '"count":[0-9]*' || echo "No alerts index yet"
docker logs elastalert2 2>&1 | tail -5

section "Endpoints"
info "Kibana: http://localhost:5601"
info "Elasticsearch: http://localhost:9200"
