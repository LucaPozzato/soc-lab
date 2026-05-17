#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/common.sh"

RULES_LOG_DIR="$REPO_ROOT/docker-logs/rules"
STATUS_FILE="$RULES_LOG_DIR/status.json"
SURICATA_LOG="$RULES_LOG_DIR/suricata-compile.log"
SIGMA_LOG="$RULES_LOG_DIR/sigma-compile.log"
WATCHER_LOG="$RULES_LOG_DIR/watcher.log"
WATCHER_PID_FILE="$REPO_ROOT/.soc-lab/rules-watcher.pid"

ensure_runtime_dirs() {
  mkdir -p "$RULES_LOG_DIR" "$REPO_ROOT/.soc-lab"
  if ! touch "$RULES_LOG_DIR/.write-test" 2>/dev/null; then
    die "Rules log directory is not writable: $RULES_LOG_DIR (fix: sudo chown -R $(id -u):$(id -g) \"$RULES_LOG_DIR\")"
  fi
  rm -f "$RULES_LOG_DIR/.write-test"
}

is_systemd_available() {
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]]
}

write_status() {
  local suricata_status="$1"
  local sigma_status="$2"
  local sigma_ok="$3"
  local sigma_fail="$4"
  local et_rules="$5"
  local custom_rules="$6"
  local sigma_total="$7"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$STATUS_FILE" <<EOF
{
  "updated_at": "$now",
  "suricata": {
    "status": "$suricata_status",
    "last_check": "$now",
    "et_rules": $et_rules,
    "custom_rules": $custom_rules,
    "error_log": "docker-logs/rules/suricata-compile.log"
  },
  "sigma": {
    "status": "$sigma_status",
    "last_check": "$now",
    "loaded_rules": $sigma_total,
    "ok_count": $sigma_ok,
    "fail_count": $sigma_fail,
    "error_log": "docker-logs/rules/sigma-compile.log"
  }
}
EOF
}

count_suricata_loaded_rules() {
  local et_count=0
  local custom_count=0
  et_count=$(docker exec suricata sh -c 'grep -hE "sid:[[:space:]]*[0-9]+" /var/lib/suricata/rules/*.rules 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
  custom_count=$(docker exec suricata sh -c 'grep -hE "sid:[[:space:]]*[0-9]+" /etc/suricata/rules/custom/*.rules 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
  SURICATA_ET_COUNT=${et_count:-0}
  SURICATA_CUSTOM_COUNT=${custom_count:-0}
}

compile_suricata() {
  local rc=0
  {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Running Suricata rule compile check"
    docker exec suricata suricata -T -c /etc/suricata/suricata.yaml
  } >"$SURICATA_LOG" 2>&1 || rc=$?
  return "$rc"
}

compile_sigma() {
  local ok_count=0
  local fail_count=0
  local total_count=0
  local f out rc

  : > "$SIGMA_LOG"
  while IFS= read -r -d '' f; do
    total_count=$((total_count + 1))
    out="/tmp/$(basename "$f" .yml).yaml"
    if docker exec elastalert2 sigma convert -t elastalert --without-pipeline "/opt/sigma/rules/$(basename "$f")" >"$out" 2>>"$SIGMA_LOG"; then
      ok_count=$((ok_count + 1))
      rm -f "$out"
    else
      fail_count=$((fail_count + 1))
      printf "[%s] sigma conversion failed: %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$(basename "$f")" >> "$SIGMA_LOG"
    fi
  done < <(find "$REPO_ROOT/rules/sigma" -maxdepth 1 -type f -name '*.yml' -print0)

  printf "[%s] sigma compile summary: ok=%d fail=%d\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$ok_count" "$fail_count" >> "$SIGMA_LOG"

  SIGMA_OK_COUNT="$ok_count"
  SIGMA_FAIL_COUNT="$fail_count"
  SIGMA_TOTAL_COUNT="$total_count"
  rc=0
  [[ "$fail_count" -gt 0 ]] && rc=1
  return "$rc"
}

cmd_compile() {
  ensure_runtime_dirs

  docker exec suricata true >/dev/null 2>&1 || die "Suricata container not running (use: soc-lab stack start)"
  docker exec elastalert2 true >/dev/null 2>&1 || die "ElastAlert2 container not running (use: soc-lab stack start)"

  local suricata_status="ok"
  local sigma_status="ok"

  section "Rules Compile"
  info "Checking Suricata rules"
  if compile_suricata; then
    count_suricata_loaded_rules
    ok "Suricata rules compile check passed"
  else
    suricata_status="fail"
    SURICATA_ET_COUNT=0
    SURICATA_CUSTOM_COUNT=0
    warn "Suricata rules compile check failed (see $SURICATA_LOG)"
  fi

  info "Checking Sigma rules"
  SIGMA_OK_COUNT=0
  SIGMA_FAIL_COUNT=0
  SIGMA_TOTAL_COUNT=0
  if compile_sigma; then
    ok "Sigma conversion check passed ($SIGMA_OK_COUNT/$SIGMA_TOTAL_COUNT files)"
  else
    sigma_status="fail"
    warn "Sigma conversion check failed (ok=$SIGMA_OK_COUNT fail=$SIGMA_FAIL_COUNT total=$SIGMA_TOTAL_COUNT; see $SIGMA_LOG)"
  fi

  write_status "$suricata_status" "$sigma_status" "$SIGMA_OK_COUNT" "$SIGMA_FAIL_COUNT" "$SURICATA_ET_COUNT" "$SURICATA_CUSTOM_COUNT" "$SIGMA_TOTAL_COUNT"
  if [[ "$suricata_status" == "fail" || "$sigma_status" == "fail" ]]; then
    return 1
  fi
  ok "Rules status saved to $STATUS_FILE"
}

watch_loop() {
  ensure_runtime_dirs
  local prev_suricata=""
  local prev_sigma=""
  while true; do
    local cur_suricata cur_sigma
    cur_suricata=$(find "$REPO_ROOT/rules/suricata" -maxdepth 1 -type f -name '*.rules' -printf '%p %T@\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
    cur_sigma=$(find "$REPO_ROOT/rules/sigma" -maxdepth 1 -type f -name '*.yml' -printf '%p %T@\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
    if [[ "$cur_suricata" != "$prev_suricata" || "$cur_sigma" != "$prev_sigma" || ! -f "$STATUS_FILE" ]]; then
      {
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Rule change detected. Running compile checks."
        "$REPO_ROOT/soc-lab" --cli rules compile || true
      } >> "$WATCHER_LOG" 2>&1
      prev_suricata="$cur_suricata"
      prev_sigma="$cur_sigma"
    fi
    sleep 2
  done
}

cmd_watch() {
  ensure_runtime_dirs
  watch_loop
}

cmd_watch_start() {
  ensure_runtime_dirs
  local pid_file="$WATCHER_PID_FILE"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      info "Rules watcher already running (pid: $pid)"
      return 0
    fi
    rm -f "$pid_file" 2>/dev/null || true
  fi

  if [[ "$(detect_platform)" == "wsl" ]] && ! is_systemd_available; then
    warn "WSL detected without systemd: rules watcher not started"
    info "Run manual compile checks with: soc-lab rules compile"
    info "To enable systemd in WSL:"
    info "  1) Add to /etc/wsl.conf:"
    info "     [boot]"
    info "     systemd=true"
    info "  2) From Windows PowerShell: wsl --shutdown"
    info "  3) Re-open WSL distro and retry: soc-lab stack start"
    return 0
  fi

  nohup "$REPO_ROOT/soc-lab" --cli rules watch >> "$WATCHER_LOG" 2>&1 &
  if ! printf "%s" "$!" > "$pid_file"; then
    die "Unable to write watcher pid file: $pid_file"
  fi
  ok "Rules watcher started (pid: $(cat "$pid_file"))"
}

cmd_watch_stop() {
  local pid_file="$WATCHER_PID_FILE"
  if [[ ! -f "$pid_file" ]]; then
    info "Rules watcher not running"
    return 0
  fi
  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    ok "Rules watcher stopped"
  else
    info "Rules watcher not running"
  fi
  rm -f "$pid_file" 2>/dev/null || true
}

case "${1:-}" in
  compile) cmd_compile ;;
  watch) cmd_watch ;;
  watch-start) cmd_watch_start ;;
  watch-stop) cmd_watch_stop ;;
  *) die "Usage: soc-lab rules <compile|watch|watch-start|watch-stop>" ;;
esac
