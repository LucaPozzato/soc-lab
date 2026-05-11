#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/common.sh"

setup_venv() {
  section "Python Environment"
  local venv="$REPO_ROOT/.venv"
  if [[ -f "$venv/bin/activate" ]]; then
    ok "venv already present"
    return 0
  fi
  bash "$REPO_ROOT/scripts/tools/setup-venv.sh"
  ok "venv initialized"
}

verify_so_assets() {
  local missing=0
  local pipelines=(suricata.common suricata.alert common.nids)
  local p code
  for p in "${pipelines[@]}"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:9200/_ingest/pipeline/$p")
    if [[ "$code" != "200" ]]; then
      warn "Missing SO pipeline: $p"
      missing=1
    fi
  done

  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:9200/_index_template/suricata-so-ecs")
  if [[ "$code" != "200" ]]; then
    warn "Missing SO index template: suricata-so-ecs"
    missing=1
  fi

  if [[ "$missing" -eq 1 ]]; then
    die "SO assets verification failed"
  fi
  ok "SO assets verified"
}

cmd_install() {
  banner "SOC Lab Installer"
  section "Platform"
  local platform
  platform=$(detect_platform)
  info "Detected platform: $platform"

  setup_venv

  banner "Install Complete"
  info "Next: ./soc-lab stack start"
}

cmd_start() {
  banner "SOC Lab Stack Start"
  section "Prerequisites"
  require_cmd docker
  docker info >/dev/null 2>&1 || die "Docker daemon not running"
  docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
  ok "Docker runtime ready"

  section "Preparing Folders"
  mkdir -p "$REPO_ROOT/docker-logs/suricata" "$REPO_ROOT/logs" "$REPO_ROOT/pcap" "$REPO_ROOT/rules/suricata" "$REPO_ROOT/rules/sigma"
  ok "Runtime folders ready"

  section "Runtime Scripts"
  chmod +x "$REPO_ROOT/scripts/runtime/suricata-start.sh" "$REPO_ROOT/scripts/runtime/elastalert-start.sh"
  ok "Runtime entrypoints are executable"

  section "Containers"
  run_step "Launching containers" docker compose up -d
  ok "Compose stack started"

  section "Elasticsearch"
  for i in $(seq 1 40); do
    if curl -s http://localhost:9200/_cluster/health 2>/dev/null | grep -q '"status"'; then
      ok "Elasticsearch is healthy"
      break
    fi
    printf "."
    sleep 5
    [[ "$i" -eq 40 ]] && { echo ""; die "Elasticsearch did not become healthy in time"; }
  done
  echo ""

  section "SO Assets"
  if run_step "Syncing SO templates" bash "$BASE_DIR/loaders/so-templates.sh" >/dev/null 2>&1; then ok "SO templates loaded"; else warn "SO templates load failed"; fi
  if run_step "Syncing SO pipelines" bash "$BASE_DIR/loaders/so-pipelines.sh" >/dev/null 2>&1; then ok "SO pipelines loaded"; else warn "SO pipelines load failed"; fi
  verify_so_assets

  section "Custom Pipelines"
  local pipe_count=0
  for pf in "$REPO_ROOT"/pipelines/known/*.json "$REPO_ROOT"/pipelines/generated/*.json; do
    [[ -f "$pf" ]] || continue
    name=$(basename "$pf" .json)
    curl -s -o /dev/null -X PUT "http://localhost:9200/_ingest/pipeline/$name" -H 'Content-Type: application/json' --data-binary @"$pf" && pipe_count=$((pipe_count + 1))
  done
  ok "Custom JSON pipelines loaded: $pipe_count"

  section "Suricata Rules"
  local suricata_waited=0
  if ! docker compose ps suricata --status running --quiet | grep -q .; then
    warn "Suricata service is not running"
    docker logs suricata --tail 20 2>/dev/null || true
    die "Suricata container is not running"
  fi
  for i in $(seq 1 60); do
    count=$(docker exec suricata sh -c 'ls /var/lib/suricata/rules/*.rules 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
    if [[ "$count" -gt 0 ]]; then
      ok "Rules uploaded successfully ($count files)"
      break
    fi

    logs=$(docker logs suricata 2>&1 || true)
    if ! docker compose ps suricata --status running --quiet | grep -q .; then
      warn "Suricata container exited unexpectedly"
      echo "$logs" | tail -20
      die "Suricata failed to initialize"
    fi

    printf "."
    suricata_waited=1
    sleep 5
    [[ "$i" -eq 60 ]] && { echo ""; warn "Rules still downloading (check: docker logs suricata)"; }
  done
  if [[ "$suricata_waited" -eq 1 ]]; then
    echo ""
  fi

  section "Aliases and Data Views"
  curl -s -X PUT "http://localhost:9200/_index_template/soc-lab-single-node" -H 'Content-Type: application/json' -d '{"index_patterns":["suricata-*","elastalert2_*","logs-*"],"priority":300,"template":{"settings":{"index.number_of_replicas":0}}}' >/dev/null 2>&1
  curl -s -X PUT "http://localhost:9200/_index_template/suricata-soc-alerts" -H 'Content-Type: application/json' -d '{"index_patterns":["suricata-*"],"template":{"aliases":{"soc-alerts":{"filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}}}}' >/dev/null 2>&1
  curl -s -X POST "http://localhost:9200/_aliases" -H 'Content-Type: application/json' -d '{"actions":[{"remove":{"index":"suricata-*","alias":"soc-alerts"}},{"add":{"index":"suricata-*","alias":"soc-alerts","filter":{"bool":{"should":[{"term":{"event.dataset":"alert"}},{"term":{"event.dataset":"suricata.alert"}},{"term":{"tags":"alert"}}],"minimum_should_match":1}}}}]}' >/dev/null 2>&1 || true
  if curl -s "http://localhost:9200/_cat/indices/elastalert2_alerts?h=index" | grep -q '^elastalert2_alerts$'; then
    curl -s -X POST "http://localhost:9200/_aliases" -H 'Content-Type: application/json' -d '{"actions":[{"add":{"index":"elastalert2_alerts","alias":"soc-alerts"}}]}' >/dev/null 2>&1
  fi

  for i in $(seq 1 24); do
    if curl -s http://localhost:5601/api/status 2>/dev/null | grep -q '"level":"available"'; then
      for dv in \
        '{"title":"*","timeFieldName":"@timestamp","name":"All Logs"}' \
        '{"title":"suricata-*","timeFieldName":"@timestamp","name":"Suricata"}' \
        '{"title":"elastalert2_alerts","timeFieldName":"@timestamp","name":"ElastAlert2 Alerts"}' \
        '{"title":"soc-alerts","timeFieldName":"@timestamp","name":"Alerts"}'; do
        curl -s -o /dev/null -X POST "http://localhost:5601/api/data_views/data_view" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -d "{\"data_view\":$dv}"
      done
      ok "Kibana data views ensured"
      break
    fi
    sleep 5
    [[ "$i" -eq 24 ]] && warn "Kibana not ready: data views not created"
  done

  banner "SOC Lab Ready"
  info "Kibana: http://localhost:5601"
  info "Elasticsearch: http://localhost:9200"
  info "Next: soc-lab capture replay <pcap-file>"
}

cmd_stop() {
  banner "SOC Lab Stack Stop"
  docker compose down
  ok "Stack stopped; volumes preserved"
}

cmd_reset() {
  banner "SOC Lab Stack Reset"
  warn "This wipes ES data, Suricata rules volume, and Filebeat registry"
  confirm "Proceed with destructive reset?" || { info "Reset aborted"; exit 0; }
  docker compose down -v
  ok "Stack reset complete"
}

cmd_uninstall() {
  banner "SOC Lab Stack Uninstall"
  warn "This will stop stack and remove volumes and runtime artifacts"
  confirm "Proceed with uninstall?" || { info "Uninstall aborted"; exit 0; }

  section "Containers and Volumes"
  docker compose down -v || true

  section "Runtime Artifacts"
  rm -rf "$REPO_ROOT/.venv" "$REPO_ROOT/docker-logs/suricata" "$REPO_ROOT/pcap/live"
  ok "Runtime artifacts removed"

  info "No owned system dependencies to remove"

  ok "Uninstall complete"
}

cmd_status() {
  banner "SOC Lab Stack Status"
  docker compose ps
}

case "${1:-}" in
  install) cmd_install ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  reset) cmd_reset ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  *) die "Usage: soc-lab stack <install|start|stop|reset|uninstall|status>" ;;
esac
