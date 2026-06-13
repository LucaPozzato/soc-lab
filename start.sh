#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
STATE_DIR="$ROOT_DIR/.soc-lab"
API_PID="$STATE_DIR/web-api.pid"
DASH_PID="$STATE_DIR/web-dash.pid"
WATCHER_PID="$STATE_DIR/rules-watcher.pid"
API_LOG="$STATE_DIR/web-api.log"
DASH_LOG="$STATE_DIR/web-dash.log"
WATCHER_LOG="$STATE_DIR/rules-watcher.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
err()   { printf "  ${RED}✗${NC} %s\n" "$*" >&2; }
step()  { printf "\n${BOLD}%s${NC}\n" "$*"; }
die()   { err "$*"; exit 1; }

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  owner="${SUDO_USER:-$USER}"
  die "Do not run start.sh with sudo. Fix root-owned state with: sudo chown -R \"$owner:$owner\" runtime .soc-lab data/pcap .venv"
fi

ensure_writable_dir() {
  local d="$1"
  mkdir -p "$d"
  [[ -w "$d" ]] || die "Directory is not writable: $d. Fix ownership with: sudo chown -R \"$USER:$USER\" \"$d\""
}

mkdir -p "$STATE_DIR"
export PYTHONDONTWRITEBYTECODE=1

# ── sanity checks ─────────────────────────────────────────────────────────────

step "Checking prerequisites"

command -v docker >/dev/null 2>&1 || die "docker not found — install Docker first"
docker info >/dev/null 2>&1      || die "Docker daemon not running — start Docker first"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
info "Docker is running"

step "Preparing writable runtime directories"
ensure_writable_dir "$STATE_DIR"
ensure_writable_dir "$ROOT_DIR/runtime/logs/suricata"
ensure_writable_dir "$ROOT_DIR/runtime/logs/rules"
ensure_writable_dir "$ROOT_DIR/data/pcap"
ensure_writable_dir "$ROOT_DIR/data/pcap/live"
info "Runtime directories are writable"

# ── python venv ───────────────────────────────────────────────────────────────

step "Python environment"

if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
  warn "No venv found — creating one"
  python3 -m venv "$VENV_DIR"
  info "venv created at $VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

PYTHON="$VENV_DIR/bin/python"
export PYTHONWARNINGS="ignore::UserWarning"
PIP="$VENV_DIR/bin/pip"

"$PIP" install --upgrade pip -q
"$PIP" install -r "$ROOT_DIR/requirements.txt" -q
info "Dependencies installed"

# ── stop any stale web processes ───────────────────────────────────────────────

_kill_pid_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local pid; pid=$(cat "$f" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.3
  fi
  rm -f "$f"
}

_kill_port() {
  local port="$1"
  local pids; pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  [[ -z "$pids" ]] && return 0
  echo "$pids" | xargs -r kill 2>/dev/null || true
}

_kill_pid_file "$API_PID"
_kill_pid_file "$DASH_PID"
_kill_pid_file "$WATCHER_PID"
_kill_port 8000
_kill_port 8050
sleep 0.5

# ── docker stack ───────────────────────────────────────────────────────────────

step "Starting Docker stack"
cd "$ROOT_DIR"
docker compose up -d
info "Containers started"

# wait for Elasticsearch
step "Waiting for Elasticsearch"
ES_URL="http://localhost:9200"
TIMEOUT=120
elapsed=0
until curl -sf "$ES_URL/_cluster/health" >/dev/null 2>&1; do
  if (( elapsed >= TIMEOUT )); then
    die "Elasticsearch did not become healthy within ${TIMEOUT}s — check: docker compose logs elasticsearch"
  fi
  printf "    waiting… (%ds)\r" "$elapsed"
  sleep 3
  (( elapsed += 3 ))
done
info "Elasticsearch is healthy"

# wait for Kibana
step "Waiting for Kibana"
KB_URL="http://localhost:5601"
TIMEOUT=120
elapsed=0
until curl -sf "$KB_URL/api/status" 2>/dev/null | grep -q '"level":"available"' 2>/dev/null; do
  if (( elapsed >= TIMEOUT )); then
    warn "Kibana did not become healthy within ${TIMEOUT}s — data views may not be created"
    break
  fi
  printf "    waiting… (%ds)\r" "$elapsed"
  sleep 3
  (( elapsed += 3 ))
done
info "Kibana is healthy"

# load SO ECS templates + ingest pipelines
step "Loading SO templates and pipelines"
if "$PYTHON" -c "
from core.elastic.loader import sync_all
r = sync_all()
failed = r['pipelines']['failed']
if failed:
    print('  pipelines failed:', failed)
" 2>&1; then
  info "SO templates and pipelines loaded"
else
  warn "SO sync had errors — replay may not work correctly"
fi

# ensure built-in aliases/data views
step "Ensuring system aliases"
if "$PYTHON" -c "from core.elastic.aliases import ensure_system_aliases; ensure_system_aliases()" 2>&1; then
  info "System aliases ensured"
else
  warn "Failed to ensure system aliases — check Kibana/Elasticsearch connectivity"
fi

# ── start web processes ────────────────────────────────────────────────────────

step "Starting web services"

"$PYTHON" -m uvicorn api.main:app --host 127.0.0.1 --port 8000 --reload \
  > "$API_LOG" 2>&1 &
echo $! > "$API_PID"

"$PYTHON" -m ui.app \
  > "$DASH_LOG" 2>&1 &
echo $! > "$DASH_PID"

# brief wait to catch immediate crashes
sleep 2
api_pid=$(cat "$API_PID" 2>/dev/null || true)
dash_pid=$(cat "$DASH_PID" 2>/dev/null || true)

if [[ -n "$api_pid" ]] && kill -0 "$api_pid" 2>/dev/null; then
  info "FastAPI started (pid $api_pid)"
else
  err "FastAPI failed to start — check $API_LOG"
  exit 1
fi

if [[ -n "$dash_pid" ]] && kill -0 "$dash_pid" 2>/dev/null; then
  info "Dash started (pid $dash_pid)"
else
  err "Dash failed to start — check $DASH_LOG"
  exit 1
fi

# ── rules watcher ──────────────────────────────────────────────────────────────

"$PYTHON" -c "from core.rules.compile import watch_start; watch_start()" \
  > "$WATCHER_LOG" 2>&1 || warn "Rules watcher could not start (check $WATCHER_LOG)"
watcher_pid=$(cat "$WATCHER_PID" 2>/dev/null || true)
if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
  info "Rules watcher started (pid $watcher_pid)"
else
  warn "Rules watcher not running (WSL without systemd, or check $WATCHER_LOG)"
fi

# ── done ───────────────────────────────────────────────────────────────────────

printf "\n${BOLD}SOC Lab is running${NC}\n"
printf "  FastAPI  →  http://127.0.0.1:8000\n"
printf "  Dash UI  →  http://127.0.0.1:8050\n"
printf "\n  Logs: %s/\n" "$STATE_DIR"
printf "  Stop:  ./stop.sh\n\n"
