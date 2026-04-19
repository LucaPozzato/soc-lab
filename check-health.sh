#!/bin/bash
set -e

echo "======================================"
echo " SOC Lab Health Check"
echo "======================================"

echo ""
echo "[*] Container status:"
docker compose ps

echo ""
echo "[*] Elasticsearch cluster:"
curl -s http://localhost:9200/_cluster/health?pretty | grep status

echo ""
echo "[*] Indices in Elasticsearch:"
curl -s http://localhost:9200/_cat/indices?v | grep suricata || echo "  No suricata indices yet"

echo ""
echo "[*] Filebeat errors (last 10 lines):"
docker logs filebeat 2>&1 | tail -10

echo ""
echo "[*] Suricata eve.json (last 3 events):"
tail -3 ./logs/suricata/eve.json 2>/dev/null || echo "  No events yet"

echo ""
echo "======================================"
echo " Kibana: http://localhost:5601"
echo " Elasticsearch: http://localhost:9200"
echo "======================================"
