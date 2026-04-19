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

echo -e "${BOLD}======================================"
echo -e " SOC Lab — Starting"
echo -e "======================================${NC}"
echo ""

# ── Prerequisites ──────────────────────────────────────────────
echo -e "${BOLD}[1/4] Checking prerequisites${NC}"

command -v docker >/dev/null 2>&1 || die "Docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop"
docker info >/dev/null 2>&1      || die "Docker daemon not running. Start Docker Desktop first."
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found."

ok "Docker is running"

# ── Directories ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/4] Creating directories${NC}"

mkdir -p logs/suricata pcap rules
ok "logs/suricata, pcap, rules — ready"

# ── Start stack ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/4] Starting containers${NC}"

docker compose up -d
echo ""

# ── Wait for healthy ───────────────────────────────────────────
echo -e "${BOLD}[4/4] Waiting for services${NC}"

# Elasticsearch
echo -n "    Elasticsearch "
for i in $(seq 1 40); do
    if curl -s http://localhost:9200/_cluster/health 2>/dev/null | grep -q '"status"'; then
        echo -e " ${GREEN}healthy${NC}"
        break
    fi
    echo -n "."
    sleep 5
    [ $i -eq 40 ] && { echo ""; die "Elasticsearch did not become healthy in time."; }
done

# Suricata rules (suricata-start.sh downloads them on first run)
echo -n "    Suricata rules "
for i in $(seq 1 60); do
    if docker logs suricata 2>&1 | grep -q "waiting for pcap"; then
        RULE_COUNT=$(docker exec suricata sh -c 'ls /var/lib/suricata/rules/*.rules 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
        echo -e " ${GREEN}ready (${RULE_COUNT} rule files)${NC}"
        break
    fi
    echo -n "."
    sleep 5
    [ $i -eq 60 ] && { echo ""; warn "Rules still downloading — check: docker logs suricata"; }
done

# Kibana data view
echo -n "    Kibana data view"
for i in $(seq 1 24); do
    if curl -s http://localhost:5601/api/status 2>/dev/null | grep -q '"level":"available"'; then
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:5601/api/data_views/data_view" \
          -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
          -d '{"data_view":{"title":"suricata-*","timeFieldName":"@timestamp","name":"Suricata"}}')
        [ "$HTTP" = "200" ] && echo -e " ${GREEN}created${NC}" || echo -e " ${GREEN}already exists${NC}"
        break
    fi
    echo -n "."
    sleep 5
    [ $i -eq 24 ] && { echo ""; warn "Kibana not ready — data view not created"; }
done

# Filebeat
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
echo -e "  Stop:            ${BOLD}docker compose down${NC}"
echo -e "  Stop + wipe:     ${BOLD}docker compose down -v${NC}"
echo ""
