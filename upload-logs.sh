#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "[*] $*"; }

ES_URL="http://localhost:9200"
OLLAMA_URL="http://localhost:11434"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PIPELINES_DIR="$SCRIPT_DIR/pipelines/elasticsearch"
PIPELINES_GEN="$SCRIPT_DIR/pipelines/generated"
BULK_SIZE=500
LLM_PAUSE_CONTAINERS=${LLM_PAUSE_CONTAINERS:-true}

# Venv (pyyaml + python-evtx)
VENV="$SCRIPT_DIR/.venv"
[ -f "$VENV/bin/activate" ] || bash "$SCRIPT_DIR/scripts/setup-venv.sh"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

# ── Args ──────────────────────────────────────────────────────────────────────
WATCH=false; KEEP=false; NOW=false; BATCH=false; INDEX_OVERRIDE=""; TYPE_OVERRIDE=""
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) WATCH=true;  shift ;;
        --keep)  KEEP=true;   shift ;;
        --now)   NOW=true;    shift ;;
        --batch) BATCH=true;  shift ;;
        --index) INDEX_OVERRIDE="$2"; shift 2 ;;
        --type)  TYPE_OVERRIDE="$2"; shift 2 ;;
        *)       TARGET="$1"; shift ;;
    esac
done
[ -z "$TARGET" ] && { echo "Usage: $0 <file|dir> [--type <pipeline>] [--index <name>] [--keep] [--now] [--watch]"; exit 1; }

# ── Pipeline type resolver (fuzzy match + suggestions) ────────────────────────
resolve_type() {
    local query="$1"
    local norm
    local max_menu=10
    norm=$(echo "$query" | tr '[:upper:]' '[:lower:]' | tr ' _.' '---')

    # Exact match
    [[ -f "$PIPELINES_DIR/${query}.yml" ]] && { echo "$query"; return 0; }

    # Family match (e.g. zeek -> zeek-*) with optional autodiscover
    local family_candidates=""
    family_candidates=$(python3 - "$norm" "$PIPELINES_DIR" << 'PY'
import sys, os

norm = sys.argv[1].strip().lower()
dirp = sys.argv[2]

if not norm:
    sys.exit(0)

names = [f[:-4] for f in os.listdir(dirp) if f.endswith('.yml')]
starts = [n for n in names if n.lower().startswith(norm + '-') or n.lower().startswith(norm + '_')]

for n in sorted(starts):
    print(n)
PY
)

    if [[ -n "$family_candidates" ]]; then
        local family_count
        family_count=$(echo "$family_candidates" | wc -l | tr -d ' ')
        local shown_count="$family_count"
        (( shown_count > max_menu )) && shown_count=$max_menu

    if [[ "$family_count" == "1" ]]; then
        echo "$family_candidates"
        return 0
    fi

    echo -e "${YELLOW}[!]${NC} Type family '${query}' matched ${family_count} pipelines." >&2
    echo "" >&2
    echo "   1) autodiscover from this family" >&2
    local i=2
    while IFS= read -r s; do
        (( i > shown_count + 1 )) && break
        printf "  %2d) %s\n" "$i" "$s" >&2
        (( i++ ))
    done <<< "$family_candidates"
    if (( family_count > shown_count )); then
        echo "      ... and $((family_count - shown_count)) more (narrow --type to be more specific)" >&2
    fi
    echo "" >&2
    echo -n "  Select [1-$((shown_count + 1))] or Enter to abort: " >&2
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= shown_count + 1 )); then
        if (( choice == 1 )); then
            echo "__AUTO_FAMILY__:${norm}"
            return 0
        fi
        local selected
        selected=$(echo "$family_candidates" | sed -n "$((choice - 1))p")
        echo "$selected"
        return 0
    fi

    die "Aborted."
fi

    # Fuzzy match via Python difflib — returns closest names
    local suggestions
    suggestions=$(python3 - "$query" "$PIPELINES_DIR" << 'PY'
import sys, os, difflib

query = sys.argv[1].lower().replace(' ', '-').replace('_', '-').replace('.', '-')
names = [f[:-4] for f in os.listdir(sys.argv[2]) if f.endswith('.yml')]

# 1. Substring matches
subs = [n for n in names if query in n.lower() or n.lower() in query]
subs.sort(key=lambda n: abs(len(n) - len(query)))

# 2. Difflib close matches (handles typos)
close = difflib.get_close_matches(query, names, n=10, cutoff=0.45)

# Merge: subs first, then close, dedup, cap at 8
seen = set()
merged = []
for n in subs + close:
    if n not in seen:
        seen.add(n)
        merged.append(n)

for n in merged[:8]:
    print(n)
PY
)

    if [[ -z "$suggestions" ]]; then
        die "--type '$query' not found and no similar pipelines. Run: ls $PIPELINES_DIR | grep -i <keyword>"
    fi

    local count
    count=$(echo "$suggestions" | wc -l | tr -d ' ')
    local shown_count="$count"
    (( shown_count > max_menu )) && shown_count=$max_menu

    # Exact match inside suggestions (case-insensitive)
    local exact
    exact=$(echo "$suggestions" | grep -i "^${query}$" | head -1)
    if [[ -n "$exact" ]]; then
        echo "$exact"; return 0
    fi

    echo -e "${YELLOW}[!]${NC} Pipeline '${query}' not found. Did you mean one of these?" >&2
    echo "" >&2
    local i=1
    while IFS= read -r s; do
        (( i > shown_count )) && break
        printf "  %2d) %s\n" "$i" "$s" >&2
        (( i++ ))
    done <<< "$suggestions"
    if (( count > shown_count )); then
        echo "      ... and $((count - shown_count)) more (narrow --type to be more specific)" >&2
    fi
    echo "" >&2
    echo -n "  Select [1-${shown_count}] or Enter to abort: " >&2
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= shown_count )); then
        local selected
        selected=$(echo "$suggestions" | sed -n "${choice}p")
        echo "$selected"; return 0
    fi
    die "Aborted."
}

# ── Pre-processing ────────────────────────────────────────────────────────────
preprocess() {
    local file="$1" ext tmp
    ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        gz)
            tmp=$(mktemp /tmp/upload-XXXXXX)
            gunzip -c "$file" > "$tmp"; echo "$tmp" ;;
        zip)
            tmp=$(mktemp /tmp/upload-XXXXXX)
            unzip -p "$file" > "$tmp"; echo "$tmp" ;;
        evtx)
            tmp=$(mktemp /tmp/upload-XXXXXX)
            python3 -c "import evtx" 2>/dev/null || { warn "python-evtx not installed"; echo ""; return; }
            python3 - "$file" "$tmp" << 'PY'
import sys, json
from evtx import PyEvtxParser
with open(sys.argv[2], 'w') as out:
    for r in PyEvtxParser(sys.argv[1]).records_json():
        out.write(r['data'] + '\n')
PY
            echo "$tmp" ;;
        log)
            # Zeek TSV: promote #fields line to header, strip other # lines
            if grep -qm1 '^#fields' "$file" 2>/dev/null; then
                tmp=$(mktemp /tmp/upload-XXXXXX)
                python3 - "$file" "$tmp" << 'PY'
import sys
with open(sys.argv[1]) as i, open(sys.argv[2], 'w') as o:
    for l in i:
        if l.startswith('#fields'):
            o.write('\t'.join(l.rstrip().split('\t')[1:]) + '\n')
        elif not l.startswith('#'):
            o.write(l)
PY
                echo "$tmp"
            # IIS W3C logs: drop metadata header lines (#Software/#Version/#Date/#Fields)
            # so ingest pipelines receive only event rows.
            elif grep -qm1 '^#Fields:' "$file" 2>/dev/null; then
                tmp=$(mktemp /tmp/upload-XXXXXX)
                python3 - "$file" "$tmp" << 'PY'
import sys
with open(sys.argv[1]) as i, open(sys.argv[2], 'w') as o:
    for l in i:
        if l.startswith('#'):
            continue
        o.write(l)
PY
                echo "$tmp"
            else
                echo "$file"
            fi ;;
        *) echo "$file" ;;
    esac
}

# ── Format detection ──────────────────────────────────────────────────────────
detect_format() {
    local file="$1" first_line
    first_line=$(grep -v '^[[:space:]]*$' "$file" 2>/dev/null | head -1)
    if echo "$first_line" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
        echo "json"; return
    fi
    if grep -m5 -v '^[[:space:]]*$' "$file" | \
       python3 -c "import sys,re; sys.exit(0 if re.search(r'CEF:[0-9]+\|',sys.stdin.read()) else 1)" 2>/dev/null; then
        echo "cef"; return
    fi
    echo "other"
}

# ── Bulk ingest ───────────────────────────────────────────────────────────────
_bulk_flush() {
    local batch="$1" index="$2" pipeline_param="${3:-}"
    echo "$batch" | curl -s -X POST "$ES_URL/_bulk${pipeline_param}" \
        -H 'Content-Type: application/x-ndjson' --data-binary @- | \
        python3 -c "
import sys,json
r=json.load(sys.stdin)
print(sum(1 for i in r.get('items',[]) if not i.get('create',i.get('index',{})).get('error')))
" 2>/dev/null || echo 0
}

bulk_ingest_json() {
    local file="$1" index="$2" pipeline="${3:-}" total=0 batch="" n=0
    local pp=""
    [[ -n "$pipeline" ]] && pp="?pipeline=$pipeline"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        batch+='{"create":{"_index":"'"$index"'"}}'$'\n'"$line"$'\n'
        (( ++n >= BULK_SIZE )) && { total=$(( total + $(_bulk_flush "$batch" "$index" "$pp") )); batch=""; n=0; }
    done < "$file"
    [[ -n "$batch" ]] && total=$(( total + $(_bulk_flush "$batch" "$index" "$pp") ))
    echo "$total"
}

bulk_ingest_raw() {
    local file="$1" index="$2" pipeline="${3:-}" total=0 batch="" n=0
    local pp="" ts
    [[ -n "$pipeline" ]] && pp="?pipeline=$pipeline"
    ts=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat())")
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local esc
        esc=$(python3 -c "import sys,json; print(json.dumps(sys.argv[1]))" "$line")
        batch+='{"create":{"_index":"'"$index"'"}}'$'\n''{"message":'"$esc"',"@timestamp":"'"$ts"'"}'$'\n'
        (( ++n >= BULK_SIZE )) && { total=$(( total + $(_bulk_flush "$batch" "$index" "$pp") )); batch=""; n=0; }
    done < "$file"
    [[ -n "$batch" ]] && total=$(( total + $(_bulk_flush "$batch" "$index" "$pp") ))
    echo "$total"
}

# ── Pipeline helpers ──────────────────────────────────────────────────────────
_yml_to_json() {
    local f="$1"
    if [[ "$f" == *.yml || "$f" == *.yaml ]]; then
        python3 - "$f" << 'PY'
import sys, json, yaml

path = sys.argv[1]
doc = yaml.safe_load(open(path))

def patch_processors(items):
    if not isinstance(items, list):
        return items
    out = []
    for p in items:
        if not isinstance(p, dict) or not p:
            continue
        k = next(iter(p.keys()))
        v = p.get(k)
        if k == 'pipeline' and isinstance(v, dict):
            name = str(v.get('name', ''))
            if '{{' in name and 'IngestPipeline' in name:
                continue
        if isinstance(v, dict):
            for nk in ('processors', 'on_failure'):
                if nk in v:
                    v[nk] = patch_processors(v[nk])
        out.append({k: v})
    return out

if isinstance(doc, dict):
    if 'processors' in doc:
        doc['processors'] = patch_processors(doc.get('processors', []))
    if 'on_failure' in doc:
        doc['on_failure'] = patch_processors(doc.get('on_failure', []))

print(json.dumps(doc))
PY
    else
        cat "$f"
    fi
}

load_pipeline() {
    local name="$1" file="$2"
    local status
    status=$(_yml_to_json "$file" | curl -s -o /dev/null -w "%{http_code}" \
        -X PUT "$ES_URL/_ingest/pipeline/$name" \
        -H 'Content-Type: application/json' --data-binary @-)
    [[ "$status" == "200" ]] && ok "Pipeline ready: $name" || warn "Pipeline load failed ($status): $name"
}

# ── CEF parser ────────────────────────────────────────────────────────────────
convert_cef() {
    local file="$1" tmp
    tmp=$(mktemp /tmp/upload-cef-XXXXXX)
    python3 - "$file" "$tmp" << 'PY'
import sys, re, json
from datetime import datetime, timezone

def parse_cef(line):
    idx = line.find('CEF:')
    if idx == -1: return None
    parts = line[idx:].split('|', 7)
    if len(parts) < 7: return None
    doc = {
        'cef.version': parts[0].replace('CEF:','').strip(),
        'cef.device_vendor': parts[1], 'cef.device_product': parts[2],
        'cef.device_version': parts[3], 'cef.device_event_class_id': parts[4],
        'cef.name': parts[5], 'cef.severity': parts[6],
        '@timestamp': datetime.now(timezone.utc).isoformat(),
    }
    if len(parts) == 8:
        for m in re.finditer(r'(\w+)=((?:[^\\=]|\\.)*?)(?=\s+\w+=|$)', parts[7]):
            doc[f'cef.extensions.{m.group(1)}'] = m.group(2).replace('\\=','=').strip()
    return doc

with open(sys.argv[1], errors='replace') as fi, open(sys.argv[2], 'w') as fo:
    for line in fi:
        line = line.rstrip()
        if not line: continue
        doc = parse_cef(line)
        fo.write(json.dumps(doc if doc else {'message': line}) + '\n')
PY
    echo "$tmp"
}

# ── Kibana data view ──────────────────────────────────────────────────────────
ensure_data_view() {
    local pattern="$1" name="$2" waited=0
    until curl -sf "http://localhost:5601/api/status" -o /dev/null 2>/dev/null; do
        (( waited == 0 )) && echo -n "[*] Waiting for Kibana"
        echo -n "."; sleep 3; (( waited += 3 ))
        (( waited >= 120 )) && { echo ""; warn "Kibana not reachable — skipping data view"; return; }
    done
    [[ "$waited" -gt 0 ]] && echo ""
    local exists
    exists=$(curl -s "http://localhost:5601/api/data_views" 2>/dev/null | \
        python3 -c "import sys,json; dvs=json.load(sys.stdin); print('yes' if '$pattern' in [d.get('title','') for d in dvs.get('data_view',[])] else 'no')" 2>/dev/null)
    [[ "$exists" == "yes" ]] && return
    curl -s -o /dev/null -X POST "http://localhost:5601/api/data_views/data_view" \
        -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
        -d "{\"data_view\":{\"title\":\"$pattern\",\"timeFieldName\":\"@timestamp\",\"name\":\"$name\"}}"
    ok "Kibana data view: $name ($pattern)"
}

# ── LLM path ─────────────────────────────────────────────────────────────────
llm_pipeline_works() {
    local pipeline_file="$1" source_file="$2"
    local samples
    samples=$(mktemp /tmp/upload-llm-samples-XXXXXX)
    grep -v '^[[:space:]]*$' "$source_file" | head -20 > "$samples"

    python3 - "$pipeline_file" "$samples" "$ES_URL" << 'PY'
import json, sys, yaml, urllib.request

pipeline_file, samples_file, es_url = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(pipeline_file) as f:
        pipeline = yaml.safe_load(f)
    if not isinstance(pipeline, dict):
        sys.exit(1)
except Exception:
    sys.exit(1)

lines = []
with open(samples_file) as f:
    for line in f:
        line = line.rstrip("\n")
        if line.strip():
            lines.append(line)
        if len(lines) >= 3:
            break

if not lines:
    sys.exit(1)

payload = {
    "pipeline": pipeline,
    "docs": [{"_source": {"message": l}} for l in lines],
}

try:
    req = urllib.request.Request(
        f"{es_url}/_ingest/pipeline/_simulate",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        result = json.load(resp)
except Exception:
    sys.exit(1)

docs = [d for d in result.get("docs", []) if isinstance(d, dict)]
if not docs:
    sys.exit(1)

errors = 0
good = 0
boilerplate = {"message", "@timestamp", "event", "ecs", "tags", "parse_error", "error"}
for d in docs:
    if "error" in d:
        errors += 1
        continue
    src = d.get("doc", {}).get("_source", {}) or {}
    if src.get("parse_error"):
        continue
    meaningful = [k for k in src.keys() if k not in boilerplate]
    if meaningful:
        good += 1

if errors == len(docs) or good == 0:
    sys.exit(1)

if good / len(docs) < 0.8:
    sys.exit(1)

sys.exit(0)
PY
    local ok=$?
    rm -f "$samples"
    return $ok
}

run_llm() {
    local file="$1" index="$2" count_file="$3"
    local base pipeline_name saved

    base=$(basename "$file" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9\n' '-' | sed 's/^-//;s/-$//')
    pipeline_name="${LLM_PIPELINE_NAME_OVERRIDE:-llm-${base}}"
    saved="$PIPELINES_GEN/${pipeline_name}.yml"

    _finish() { echo "$(bulk_ingest_raw "$file" "$index" "${1:-}")" > "$count_file"; }

    # Reuse cached LLM pipeline
    if [[ -f "$saved" ]]; then
        if llm_pipeline_works "$saved" "$file"; then
            ok "Reusing saved LLM pipeline: $pipeline_name"
            load_pipeline "$pipeline_name" "$saved"
            _finish "$pipeline_name"; return
        fi
        warn "Saved LLM pipeline failed validation — regenerating: $pipeline_name"
    fi

    # Check Ollama
    if ! curl -s "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
        warn "Ollama not running. Start it with: ollama serve"
        warn "Shipping logs unparsed to $index"
        _finish ""; return
    fi

    # Model selection
    local best="qwen2.5-coder:3b" model
    if curl -s "$OLLAMA_URL/api/tags" | python3 -c "
import sys,json; ms=[m['name'] for m in json.load(sys.stdin).get('models',[])]; exit(0 if any('qwen2.5-coder:3b' in m for m in ms) else 1)
" 2>/dev/null; then
        model="$best"
        ok "Model: $model"
    else
        echo -e "[LLM] Recommended: ${BOLD}$best${NC} (~4.7 GB) — best accuracy on 16 GB RAM"
        echo -n "      Download $best? [y/N] "
        read -r dl
        if [[ "$dl" =~ ^[Yy]$ ]]; then
            curl -s -X POST "$OLLAMA_URL/api/pull" -H 'Content-Type: application/json' \
                -d "{\"name\":\"$best\"}" | python3 -c "
import sys,json
for line in sys.stdin:
    c=json.loads(line)
    t,d=c.get('total',0),c.get('completed',0)
    if t and d:
        p=d/t*100; bar='█'*int(p/5)+'░'*(20-int(p/5))
        print(f'\r  [{bar}] {d/1024/1024:.0f}/{t/1024/1024:.0f} MB ({p:.0f}%)',end='',flush=True)
print()
" || true
            model="$best"
        else
            local installed
            installed=$(curl -s "$OLLAMA_URL/api/tags" | python3 -c "
import sys,json
for m in json.load(sys.stdin).get('models',[]): print(f\"{m['name']}  ({m.get('size',0)/1024**3:.1f} GB)\")
" 2>/dev/null)
            [[ -z "$installed" ]] && { warn "No models installed. Shipping unparsed."; _finish ""; return; }
            echo ""; echo "  Installed models:"; echo "$installed" | sed 's/^/    /'; echo ""
            echo -n "  Model name (or Enter to skip): "; read -r model
            [[ -z "$model" ]] && { _finish ""; return; }
        fi
    fi

    # Generate pipeline
    info "Sampling and generating pipeline..."
    local samples llm_out llm_exit=0
    local paused_containers=""

    if [[ "$LLM_PAUSE_CONTAINERS" == "true" ]]; then
        for c in kibana suricata filebeat elastalert2; do
            if docker ps --format '{{.Names}}' | grep -qx "$c"; then
                paused_containers+="$c "
            fi
        done
        if [[ -n "$paused_containers" ]]; then
            info "Pausing non-essential containers for LLM: ${paused_containers}"
            docker stop $paused_containers >/dev/null 2>&1 || true
        fi
    fi

    samples=$(mktemp /tmp/upload-samples-XXXXXX)
    grep -v '^[[:space:]]*$' "$file" | head -20 > "$samples"
    llm_out=$(mktemp /tmp/llm-out-XXXXXX)

    python3 "$SCRIPT_DIR/scripts/pipeline_generator.py" "$samples" "$pipeline_name" "$model" > "$llm_out" || llm_exit=$?
    rm -f "$samples"

    if [[ -n "$paused_containers" ]]; then
        info "Resuming paused containers..."
        docker start $paused_containers >/dev/null 2>&1 || true
    fi

    if [[ $llm_exit -eq 0 ]] && [[ -s "$llm_out" ]]; then
        mkdir -p "$PIPELINES_GEN"
        cp "$llm_out" "$saved"
        ok "Pipeline saved: pipelines/generated/${pipeline_name}.yml"
        load_pipeline "$pipeline_name" "$saved"
        rm -f "$llm_out"
        _finish "$pipeline_name"
    else
        warn "LLM failed — shipping logs unparsed"
        rm -f "$llm_out"
        _finish ""
    fi
}

error_count_for_index() {
    local index="$1"
    curl -s "$ES_URL/$index/_count?q=error.message:*" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0
}

quality_stats_for_index() {
    local index="$1"
    python3 - "$ES_URL" "$index" << 'PY'
import sys, json, urllib.request, urllib.parse
es = sys.argv[1]
idx = sys.argv[2]
def get(path):
    with urllib.request.urlopen(es + path, timeout=10) as r:
        return json.load(r).get("count", 0)
try:
    total = get(f"/{idx}/_count")
    err = get(f"/{idx}/_count?q=" + urllib.parse.quote("error.message:*", safe=':*'))
    perr = get(f"/{idx}/_count?q=" + urllib.parse.quote("parse_error:*", safe=':*'))
    print(f"{total} {err} {perr}")
except Exception:
    print("0 0 0")
PY
}

# ── Main ──────────────────────────────────────────────────────────────────────
process_file() {
    local original="$1"
    local tmp_files=()
    trap 'rm -f "${tmp_files[@]+"${tmp_files[@]}"}" 2>/dev/null' RETURN

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $(basename "$original")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local work_file
    work_file=$(preprocess "$original")
    [[ -z "$work_file" ]] && return
    [[ "$work_file" != "$original" ]] && tmp_files+=("$work_file")

    # Index name
    local base date_suffix index index_pattern
    base=$(basename "$original" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9\n' '-' | sed 's/^-//;s/-$//')
    date_suffix=$(date +%Y.%m.%d)
    index="${INDEX_OVERRIDE:-logs-$base}-$date_suffix"
    index_pattern="${index%-*}-*"

    if ! $KEEP; then
        local de ie
        de=$(curl -s -o /dev/null -w "%{http_code}" "$ES_URL/_data_stream/$index_pattern")
        ie=$(curl -s -o /dev/null -w "%{http_code}" "$ES_URL/$index_pattern")
        if [[ "$de" == "200" || "$ie" == "200" ]]; then
            curl -s -X DELETE "$ES_URL/_data_stream/$index_pattern" >/dev/null 2>&1 || true
            curl -s -X DELETE "$ES_URL/$index_pattern" >/dev/null 2>&1 || true
            info "Cleared $index_pattern"
        fi
    fi

    local format pipeline_used="none" count=0
    format=$(detect_format "$work_file")

    # Batch mode: resolve only once from first file, reuse for all others.
    if $BATCH && [[ -n "${BATCH_FORMAT:-}" ]]; then
        format="$BATCH_FORMAT"
    fi

    case "$format" in
        json)
            info "JSON → $index"
            pipeline_used="none"
            count=$(bulk_ingest_json "$work_file" "$index")
            ;;

        cef)
            info "CEF → parsing → $index"
            local cef_json
            cef_json=$(convert_cef "$work_file")
            tmp_files+=("$cef_json")
            pipeline_used="none"
            count=$(bulk_ingest_json "$cef_json" "$index")
            ;;

        other)
            local matched=""
            local handled=false
            if $BATCH && [[ -n "${BATCH_MODE:-}" ]]; then
                case "$BATCH_MODE" in
                    matched)
                        matched="${BATCH_PIPELINE:-}"
                        [[ -n "$matched" ]] && ok "Batch pipeline: $matched"
                        handled=false
                        ;;
                    llm)
                        local cf; cf=$(mktemp)
                        LLM_PIPELINE_NAME_OVERRIDE="${BATCH_PIPELINE:-}" run_llm "$work_file" "$index" "$cf"
                        count=$(cat "$cf"); rm -f "$cf"
                        pipeline_used="llm"
                        handled=true
                        ;;
                    raw)
                        warn "Batch mode raw ingest"
                        count=$(bulk_ingest_raw "$work_file" "$index" "")
                        pipeline_used="none (raw)"
                        handled=true
                        ;;
                esac
            elif [[ -n "$TYPE_OVERRIDE" ]]; then
                matched=$(resolve_type "$TYPE_OVERRIDE") || exit 1
                if [[ "$matched" == __AUTO_FAMILY__:* ]]; then
                    local family
                    family="${matched#__AUTO_FAMILY__:}"
                    info "Autodiscovering in family: $family"
                    matched=$(grep -v '^[[:space:]]*$' "$work_file" | head -20 | \
                        python3 "$SCRIPT_DIR/scripts/match_pipeline.py" --prefix "$family" "$PIPELINES_DIR" "$ES_URL" 2>/dev/null) || true
                    [[ -n "$matched" ]] && ok "Matched: $matched" || warn "No match found in family: $family"
                else
                    ok "Using specified type: $matched"
                fi
            else
                info "Matching pipeline..."
                matched=$(grep -v '^[[:space:]]*$' "$work_file" | head -20 | \
                    python3 "$SCRIPT_DIR/scripts/match_pipeline.py" "$PIPELINES_DIR" "$ES_URL" 2>/dev/null) || true
            fi

            if ! $handled && [[ -n "$matched" ]]; then
                ok "Matched: $matched"
                local pfile="$PIPELINES_DIR/${matched}.yml"
                local pname="$matched"
                if $NOW; then
                    # Chain: matched pipeline → reset @timestamp to ingest time
                    local now_name="${matched}-now"
                    curl -s -o /dev/null -X PUT "$ES_URL/_ingest/pipeline/$now_name" \
                        -H 'Content-Type: application/json' \
                        -d '{"processors":[{"pipeline":{"name":"'"$matched"'"}},{"set":{"field":"event.created","copy_from":"@timestamp","ignore_failure":true}},{"set":{"field":"@timestamp","value":"{{{_ingest.timestamp}}}"}}]}'
                    pname="$now_name"
                fi
                load_pipeline "$matched" "$pfile"
                pipeline_used="$pname"
                count=$(bulk_ingest_raw "$work_file" "$index" "$pname")
                curl -s -X POST "$ES_URL/$index/_refresh" >/dev/null 2>&1 || true
                local stats total_docs em pem
                stats=$(quality_stats_for_index "$index")
                total_docs=$(echo "$stats" | awk '{print $1}')
                em=$(echo "$stats" | awk '{print $2}')
                pem=$(echo "$stats" | awk '{print $3}')
                local fallback=false
                if [[ "$count" -eq 0 || "$total_docs" -eq 0 ]]; then
                    fallback=true
                elif [[ "$total_docs" -gt 0 ]]; then
                    # Ratio thresholds: keep vendor pipeline on minor noise, fallback on clearly bad matches.
                    # error.message >= 30% OR parse_error >= 20%
                    if python3 - "$total_docs" "$em" "$pem" << 'PY'
import sys
t,e,p = map(float, sys.argv[1:4])
sys.exit(0 if (e/t >= 0.30 or p/t >= 0.20) else 1)
PY
                    then
                        fallback=true
                    fi
                fi

                if $fallback; then
                    warn "Detected pipeline quality issue after '$matched' (indexed=$count, total=$total_docs, error.message=$em, parse_error=$pem). Re-indexing with LLM-generated pipeline."
                    curl -s -X DELETE "$ES_URL/_data_stream/$index_pattern" >/dev/null 2>&1 || true
                    curl -s -X DELETE "$ES_URL/$index_pattern" >/dev/null 2>&1 || true
                    local cf; cf=$(mktemp)
                    LLM_PIPELINE_NAME_OVERRIDE="${LLM_PIPELINE_NAME_OVERRIDE:-}" run_llm "$work_file" "$index" "$cf"
                    count=$(cat "$cf"); rm -f "$cf"
                    pipeline_used="llm"
                    if $BATCH && [[ -z "${BATCH_MODE:-}" ]]; then
                        BATCH_MODE="llm"
                        BATCH_PIPELINE="${LLM_PIPELINE_NAME_OVERRIDE:-llm-$(basename "$original" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9\n' '-' | sed 's/^-//;s/-$//')}"
                    fi
                fi
                if $BATCH && [[ -z "${BATCH_MODE:-}" ]]; then
                    BATCH_MODE="matched"
                    BATCH_PIPELINE="$matched"
                fi
            elif ! $handled; then
                info "No pipeline matched"
                python3 - "$base" << 'PY'
import sys
n = sys.argv[1]; w = 66
def row(s=""): print(f"║  {s:<{w}}║")
print(); print("╔" + "═"*(w+2) + "╗")
row(f"No pipeline found for: {n}")
row()
row("Browse ready-made pipelines at:")
row("  https://github.com/elastic/integrations")
row()
row(f"Drop a matching .yml into pipelines/elasticsearch/")
print("╚" + "═"*(w+2) + "╝"); print()
PY
                echo -n "  No match found. Generate pipeline with local LLM? [y/N] "
                read -r use_llm
                if [[ "$use_llm" =~ ^[Yy]$ ]]; then
                    local cf; cf=$(mktemp)
                    LLM_PIPELINE_NAME_OVERRIDE="${LLM_PIPELINE_NAME_OVERRIDE:-}" run_llm "$work_file" "$index" "$cf"
                    count=$(cat "$cf"); rm -f "$cf"
                    pipeline_used="llm"
                    if $BATCH && [[ -z "${BATCH_MODE:-}" ]]; then
                        BATCH_MODE="llm"
                        BATCH_PIPELINE="${LLM_PIPELINE_NAME_OVERRIDE:-llm-$(basename "$original" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9\n' '-' | sed 's/^-//;s/-$//')}"
                    fi
                else
                    warn "Skipping LLM. Shipping raw (unparsed) to $index"
                    count=$(bulk_ingest_raw "$work_file" "$index" "")
                    pipeline_used="none (raw)"
                    if $BATCH && [[ -z "${BATCH_MODE:-}" ]]; then
                        BATCH_MODE="raw"
                    fi
                fi
            fi
            ;;
    esac

    if $BATCH && [[ -z "${BATCH_FORMAT:-}" ]]; then
        BATCH_FORMAT="$format"
    fi

    ensure_data_view "$index_pattern" "$base"

    echo ""
    echo "  Index:    $index"
    echo "  Pipeline: $pipeline_used"
    echo -e "  Docs:     ${GREEN}${count} indexed${NC}"
    echo ""
}

watch_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || die "$dir is not a directory"
    local marker="$dir/.last_processed"
    touch "$marker"
    info "Watching $dir... (Ctrl+C to stop)"
    while true; do
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            [[ "$(basename "$f")" == .* ]] && continue
            process_file "$f"
        done < <(find "$dir" -maxdepth 1 -newer "$marker" -type f ! -name '.*' 2>/dev/null)
        touch "$marker"; sleep 5
    done
}

if $WATCH; then
    watch_dir "$TARGET"
else
    if $BATCH; then
        [[ -d "$TARGET" ]] || die "--batch requires a directory target"
        BATCH_FORMAT=""
        BATCH_MODE=""
        BATCH_PIPELINE=""
        BATCH_BASE=$(basename "$TARGET")
        LLM_PIPELINE_NAME_OVERRIDE="llm-batch-${BATCH_BASE}"
        shopt -s nullglob
        files=("$TARGET"/*)
        shopt -u nullglob
        [[ ${#files[@]} -gt 0 ]] || die "No files found in $TARGET"
        for f in "${files[@]}"; do
            [[ -f "$f" ]] || continue
            [[ "$(basename "$f")" == .* ]] && continue
            process_file "$f"
        done
    else
        [[ -f "$TARGET" ]] || die "File not found: $TARGET"
        process_file "$TARGET"
    fi
fi
