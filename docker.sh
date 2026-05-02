#!/bin/bash
set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

usage() {
    echo -e "Usage: ${BOLD}./docker.sh <command>${NC}"
    echo ""
    echo "Commands:"
    echo "  start   Start the stack and wait for all services to be healthy"
    echo "  stop    Stop containers, keep volumes (ES data + rules)"
    echo "  reset   Stop containers and wipe all volumes (rules re-download on next start)"
    echo ""
}

# ── start ──────────────────────────────────────────────────────────────────────
cmd_start() {
    echo -e "${BOLD}======================================"
    echo -e " SOC Lab — Starting"
    echo -e "======================================${NC}"
    echo ""

    echo -e "${BOLD}[1/4] Checking prerequisites${NC}"
    command -v docker >/dev/null 2>&1 || die "Docker not found."
    docker info >/dev/null 2>&1      || die "Docker daemon not running."
    docker compose version >/dev/null 2>&1 || die "docker compose plugin not found."
    ok "Docker is running"

    echo ""
    echo -e "${BOLD}[2/4] Creating directories${NC}"
    mkdir -p logs/suricata pcap rules/suricata rules/sigma
    ok "logs/suricata, pcap, rules/suricata, rules/sigma — ready"

    echo ""
    echo -e "${BOLD}[3/4] Starting containers${NC}"
    docker compose up -d
    echo ""

    echo -e "${BOLD}[4/4] Waiting for services${NC}"

    echo -n "    Elasticsearch "
    for i in $(seq 1 40); do
        if curl -s http://localhost:9200/_cluster/health 2>/dev/null | grep -q '"status"'; then
            echo -e " ${GREEN}healthy${NC}"; break
        fi
        echo -n "."; sleep 5
        [ $i -eq 40 ] && { echo ""; die "Elasticsearch did not become healthy in time."; }
    done

    echo -n "    Suricata rules "
    for i in $(seq 1 60); do
        if docker logs suricata 2>&1 | grep -q "waiting for pcap"; then
            RULE_COUNT=$(docker exec suricata sh -c 'ls /var/lib/suricata/rules/*.rules 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
            echo -e " ${GREEN}ready (${RULE_COUNT} rule files)${NC}"; break
        fi
        echo -n "."; sleep 5
        [ $i -eq 60 ] && { echo ""; warn "Rules still downloading — check: docker logs suricata"; }
    done

    echo -n "    Kibana data view"
    for i in $(seq 1 24); do
        if curl -s http://localhost:5601/api/status 2>/dev/null | grep -q '"level":"available"'; then
            HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:5601/api/data_views/data_view" \
              -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
              -d '{"data_view":{"title":"suricata-*","timeFieldName":"@timestamp","name":"Suricata"}}')
            [ "$HTTP" = "200" ] && echo -e " ${GREEN}created${NC}" || echo -e " ${GREEN}already exists${NC}"; break
        fi
        echo -n "."; sleep 5
        [ $i -eq 24 ] && { echo ""; warn "Kibana not ready — data view not created"; }
    done

    echo -n "    Alerts data view"
    HTTP2=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:5601/api/data_views/data_view" \
      -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
      -d '{"data_view":{"title":"elastalert2_alerts*","timeFieldName":"@timestamp","name":"ElastAlert2 Alerts"}}')
    [ "$HTTP2" = "200" ] && echo -e " ${GREEN}created${NC}" || echo -e " ${GREEN}already exists${NC}"

    echo -n "    Filebeat        "
    if docker logs filebeat 2>&1 | grep -q "Connection to backoff.*established"; then
        echo -e " ${GREEN}connected to ES${NC}"
    else
        echo -e " ${YELLOW}starting${NC}"
    fi

    echo ""
    echo -e "${BOLD}======================================"
    echo -e " SOC Lab is up"
    echo -e "======================================${NC}"
    echo ""
    echo -e "  Kibana:          ${BOLD}http://localhost:5601${NC}"
    echo -e "  Elasticsearch:   ${BOLD}http://localhost:9200${NC}"
    echo ""
    echo -e "  Replay a PCAP:   ${BOLD}./replay-pcap.sh <file.pcap>${NC}"
    echo -e "  Health check:    ${BOLD}./check-health.sh${NC}"
    echo -e "  Update rules:    ${BOLD}./reload-rules.sh${NC}"
    echo ""
}

# ── stop ───────────────────────────────────────────────────────────────────────
cmd_stop() {
    echo -e "${BOLD}Stopping SOC Lab...${NC}"
    docker compose down
    ok "Stopped. Volumes preserved (ES data + rules)."
}

# ── reset ──────────────────────────────────────────────────────────────────────
cmd_reset() {
    echo -e "${YELLOW}[!]${NC} This will wipe all volumes (ES data, rules, Filebeat registry)."
    echo -n "    Are you sure? [y/N] "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    echo -e "${BOLD}Resetting SOC Lab...${NC}"
    docker compose down -v
    ok "Done. Rules will re-download on next start."
}

# ── dispatch ───────────────────────────────────────────────────────────────────
case "${1:-}" in
    start) cmd_start ;;
    stop)  cmd_stop  ;;
    reset) cmd_reset ;;
    *)     usage; exit 1 ;;
esac
