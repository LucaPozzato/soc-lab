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
echo "[*] ElastAlert2 alerts in ES:"
curl -s "http://localhost:9200/elastalert2_alerts/_count" 2>/dev/null | grep -o '"count":[0-9]*' || echo "  No alerts index yet"

echo ""
echo "[*] ElastAlert2 logs (last 5 lines):"
docker logs elastalert2 2>&1 | tail -5

echo ""
echo "======================================"
echo " Kibana: http://localhost:5601"
echo " Elasticsearch: http://localhost:9200"
echo "======================================"
