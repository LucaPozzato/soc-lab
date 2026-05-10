#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
info() { echo -e "[*] $*"; }

ES_URL="http://localhost:9200"
OLLAMA_URL="http://localhost:11434"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIPELINES_ES="$REPO_ROOT/pipelines/elasticsearch"
PIPELINES_CUSTOM="$REPO_ROOT/pipelines/custom"
PIPELINES_GEN="$REPO_ROOT/pipelines/generated"
BULK_SIZE=500
LLM_RAM_MODE="${LLM_RAM_MODE:-none}"

VENV="$REPO_ROOT/.venv"
[ -f "$VENV/bin/activate" ] || bash "$REPO_ROOT/scripts/tools/setup-venv.sh"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

usage() {
    cat <<'EOF'
Usage:
  ./soc-lab capture upload <file> (--type <pipeline>|--build-pipeline) [--index <name>] [--keep] [--now] [--llm-ram-mode <mode>]
  ./soc-lab capture upload --batch --folder <dir> (--type <pipeline>|--build-pipeline) [--index <prefix>] [--keep] [--now] [--llm-ram-mode <mode>]

Notes:
  - For text logs, you must choose exactly one mode: --type or --build-pipeline.
  - JSON and CEF logs are shipped directly (no pipeline required).
  - --build-pipeline uses local bare-metal Ollama (preferred 7B model) and reuses one generated pipeline in batch mode.
  - --type accepts either pipeline name or direct .yml/.yaml path.
  - Batch mode expects same log type in one folder; mixed extensions are warned.
  - --llm-ram-mode: none | quit-docker (default: none)
    (quit-docker skips ES validation during generation, then restores Docker/lab before ingest)
EOF
}

TARGET=""
FOLDER=""
BATCH=false
KEEP=false
NOW=false
INDEX_OVERRIDE=""
TYPE_OVERRIDE=""
USE_AI=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --batch) BATCH=true; shift ;;
        --folder) FOLDER="${2:-}"; shift 2 ;;
        --keep) KEEP=true; shift ;;
        --now) NOW=true; shift ;;
        --index) INDEX_OVERRIDE="${2:-}"; shift 2 ;;
        --type) TYPE_OVERRIDE="${2:-}"; shift 2 ;;
        --build-pipeline) USE_AI=true; shift ;;
        --llm-ram-mode) LLM_RAM_MODE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --*) die "Unknown option: $1 (use --build-pipeline)" ;;
        *) TARGET="$1"; shift ;;
    esac
done

case "$LLM_RAM_MODE" in
    none|quit-docker) ;;
    *) die "Invalid --llm-ram-mode '$LLM_RAM_MODE' (use: none|quit-docker)" ;;
esac

if $BATCH; then
    [[ -n "$FOLDER" ]] || [[ -n "$TARGET" ]] || { usage; die "--batch requires --folder <dir> or a directory target"; }
    [[ -z "$FOLDER" ]] && FOLDER="$TARGET"
else
    [[ -n "$TARGET" ]] || { usage; die "Missing target file"; }
fi

if [[ -n "$TYPE_OVERRIDE" ]] && $USE_AI; then
    die "Choose only one mode: --type or --build-pipeline"
fi

preprocess() {
    local file="$1" ext tmp
    ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        gz)
            tmp=$(mktemp /tmp/upload-XXXXXX)
            gunzip -c "$file" > "$tmp"
            echo "$tmp"
            ;;
        zip)
            tmp=$(mktemp /tmp/upload-XXXXXX)
            unzip -p "$file" > "$tmp"
            echo "$tmp"
            ;;
        evtx)
            tmp=$(mktemp /tmp/upload-XXXXXX)
            python3 -c "import evtx" 2>/dev/null || { warn "python-evtx not installed"; echo ""; return; }
            python3 - "$file" "$tmp" << 'PY'
import sys
from evtx import PyEvtxParser
with open(sys.argv[2], 'w') as out:
    for r in PyEvtxParser(sys.argv[1]).records_json():
        out.write(r['data'] + '\n')
PY
            echo "$tmp"
            ;;
        *)
            echo "$file"
            ;;
    esac
}

detect_format() {
    local file="$1" first_line
    first_line=$(grep -v '^[[:space:]]*$' "$file" 2>/dev/null | head -1)
    if echo "$first_line" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
        echo "json"; return
    fi
    if grep -m5 -v '^[[:space:]]*$' "$file" | python3 -c "import sys,re; sys.exit(0 if re.search(r'CEF:[0-9]+\|',sys.stdin.read()) else 1)" 2>/dev/null; then
        echo "cef"; return
    fi
    echo "other"
}

_bulk_flush() {
    local batch="$1" pipeline_param="${2:-}"
    echo "$batch" | curl -s -X POST "$ES_URL/_bulk${pipeline_param}" \
        -H 'Content-Type: application/x-ndjson' --data-binary @- | \
        python3 -c '
import sys, json
r = json.load(sys.stdin)
ok = 0
errs = []
for item in r.get("items", []):
    op = item.get("create") or item.get("index") or {}
    err = op.get("error")
    if err:
        errs.append(err)
    else:
        ok += 1
if errs:
    first = errs[0]
    msg = first.get("reason") if isinstance(first, dict) else str(first)
    typ = first.get("type") if isinstance(first, dict) else "bulk_error"
    print(f"[!] Bulk ingest error ({typ}): {msg}", file=sys.stderr)
print(ok)
' || echo 0
}

bulk_ingest_json() {
    local file="$1" index="$2" pipeline="${3:-}" total=0 batch="" n=0 pp=""
    [[ -n "$pipeline" ]] && pp="?pipeline=$pipeline"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        batch+='{"create":{"_index":"'"$index"'"}}'$'\n'"$line"$'\n'
        (( ++n >= BULK_SIZE )) && { total=$(( total + $(_bulk_flush "$batch" "$pp") )); batch=""; n=0; }
    done < "$file"
    [[ -n "$batch" ]] && total=$(( total + $(_bulk_flush "$batch" "$pp") ))
    echo "$total"
}

bulk_ingest_raw() {
    local file="$1" index="$2" pipeline="${3:-}" total=0 batch="" n=0 pp="" ts
    [[ -n "$pipeline" ]] && pp="?pipeline=$pipeline"
    ts=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat())")
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local esc
        esc=$(python3 -c "import sys,json; print(json.dumps(sys.argv[1]))" "$line")
        batch+='{"create":{"_index":"'"$index"'"}}'$'\n''{"message":'"$esc"',"@timestamp":"'"$ts"'"}'$'\n'
        (( ++n >= BULK_SIZE )) && { total=$(( total + $(_bulk_flush "$batch" "$pp") )); batch=""; n=0; }
    done < "$file"
    [[ -n "$batch" ]] && total=$(( total + $(_bulk_flush "$batch" "$pp") ))
    echo "$total"
}

convert_cef() {
    local file="$1" tmp
    tmp=$(mktemp /tmp/upload-cef-XXXXXX)
    python3 - "$file" "$tmp" << 'PY'
import sys, re, json
from datetime import datetime, timezone
def parse_cef(line):
    idx = line.find('CEF:')
    if idx == -1:
        return None
    parts = line[idx:].split('|', 7)
    if len(parts) < 7:
        return None
    doc = {
        'cef.version': parts[0].replace('CEF:','').strip(),
        'cef.device_vendor': parts[1],
        'cef.device_product': parts[2],
        'cef.device_version': parts[3],
        'cef.device_event_class_id': parts[4],
        'cef.name': parts[5],
        'cef.severity': parts[6],
        '@timestamp': datetime.now(timezone.utc).isoformat(),
    }
    if len(parts) == 8:
        for m in re.finditer(r'(\w+)=((?:[^\\=]|\\.)*?)(?=\s+\w+=|$)', parts[7]):
            doc[f'cef.extensions.{m.group(1)}'] = m.group(2).replace('\\=','=').strip()
    return doc
with open(sys.argv[1], errors='replace') as fi, open(sys.argv[2], 'w') as fo:
    for line in fi:
        line = line.rstrip()
        if not line:
            continue
        doc = parse_cef(line)
        fo.write(json.dumps(doc if doc else {'message': line}) + '\n')
PY
    echo "$tmp"
}

ensure_data_view() {
    local pattern="$1" name="$2"
    curl -sf "http://localhost:5601/api/status" -o /dev/null 2>/dev/null || return 0
    local exists
    exists=$(curl -s "http://localhost:5601/api/data_views" 2>/dev/null | \
        python3 -c "import sys,json; dvs=json.load(sys.stdin); print('yes' if '$pattern' in [d.get('title','') for d in dvs.get('data_view',[])] else 'no')" 2>/dev/null)
    [[ "$exists" == "yes" ]] && return
    curl -s -o /dev/null -X POST "http://localhost:5601/api/data_views/data_view" \
        -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
        -d "{\"data_view\":{\"title\":\"$pattern\",\"timeFieldName\":\"@timestamp\",\"name\":\"$name\"}}"
}

report_ingest_quality() {
    local index="$1"
    local pipeline="$2"
    local keep_mode="${3:-false}"
    [[ "$pipeline" == "none" ]] && return 0
    [[ "$keep_mode" == "true" ]] && { info "Skipping quality warning checks with --keep (index may contain historical docs)"; return 0; }
    local stats total err perr avgf
    stats=$(python3 - "$ES_URL" "$index" << 'PY'
import sys, json, urllib.request, urllib.parse
es, idx = sys.argv[1], sys.argv[2]
def c(q=None):
    u = f"{es}/{idx}/_count"
    if q:
        u += "?q=" + urllib.parse.quote(q, safe=':*')
    with urllib.request.urlopen(u, timeout=10) as r:
        return json.load(r).get('count', 0)
try:
    t = c()
    e = c('error.message:*')
    p = c('parse_error:*')
    q = {
      "size": 100,
      "_source": True,
      "query": {"match_all": {}}
    }
    req = urllib.request.Request(f"{es}/{idx}/_search", data=json.dumps(q).encode(), headers={"Content-Type":"application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        hits = json.load(r).get('hits', {}).get('hits', [])
    keep = {"message", "@timestamp", "event", "ecs", "tags", "error", "parse_error"}
    vals = []
    for h in hits:
        src = h.get('_source', {}) or {}
        vals.append(len([k for k in src.keys() if k not in keep]))
    avgf = (sum(vals) / len(vals)) if vals else 0.0
    print(f"{t} {e} {p} {avgf:.2f}")
except Exception:
    print('0 0 0 0')
PY
)
    total=$(echo "$stats" | awk '{print $1}')
    err=$(echo "$stats" | awk '{print $2}')
    perr=$(echo "$stats" | awk '{print $3}')
    avgf=$(echo "$stats" | awk '{print $4}')
    if [[ "$total" -gt 0 ]] && [[ "$err" -gt 0 || "$perr" -gt 0 ]]; then
        warn "Pipeline '$pipeline' produced ingest errors (error.message=$err, parse_error=$perr, total=$total)"
    fi
    if [[ "$total" -gt 0 ]] && python3 - "$avgf" << 'PY'
import sys
sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)
PY
    then
        warn "Pipeline '$pipeline' appears low-quality for this log (avg_extracted_fields=$avgf). Consider a different --type or --build-pipeline."
    fi
}

pipeline_file_for_type() {
    local t="$1"
    local c

    if [[ "$t" == *.yml || "$t" == *.yaml ]]; then
        if [[ -f "$t" ]]; then
            python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$t"
            return 0
        fi
        if [[ -f "$REPO_ROOT/$t" ]]; then
            python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$REPO_ROOT/$t"
            return 0
        fi
        return 1
    fi

    for c in \
        "$PIPELINES_ES/$t.yml" \
        "$PIPELINES_ES/$t.yaml" \
        "$PIPELINES_CUSTOM/$t.yml" \
        "$PIPELINES_CUSTOM/$t.yaml" \
        "$PIPELINES_GEN/$t.yml" \
        "$PIPELINES_GEN/$t.yaml"; do
        [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

pipeline_hints_for_type() {
    local q="$1"
    python3 - "$q" "$PIPELINES_ES" "$PIPELINES_CUSTOM" "$PIPELINES_GEN" << 'PY'
import os, sys, difflib
q = (sys.argv[1] or '').strip().lower()
dirs = sys.argv[2:]
names = []
for d in dirs:
    if not os.path.isdir(d):
        continue
    for fn in os.listdir(d):
        if not (fn.endswith('.yml') or fn.endswith('.yaml')):
            continue
        stem = os.path.splitext(fn)[0]
        names.append(stem)

uniq = sorted(set(names))
if not q or not uniq:
    sys.exit(0)

subs = [n for n in uniq if q in n.lower() or n.lower() in q]
close = difflib.get_close_matches(q, uniq, n=12, cutoff=0.45)
out = []
seen = set()
for n in subs + close:
    if n not in seen:
        seen.add(n)
        out.append(n)
for n in out[:5]:
    print(n)
PY
}

require_ollama_ready() {
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "$OLLAMA_URL/api/tags" || true)
    [[ "$status" == "200" ]] || die "Ollama is required for --build-pipeline and must be running on bare metal at $OLLAMA_URL (start with: ollama serve)"
}

pause_for_llm() {
    [[ "$LLM_RAM_MODE" == "none" ]] && { info "LLM RAM mode: none (keep Docker/lab up, ES-validated generation)" >&2; return 0; }
    if [[ "$LLM_RAM_MODE" == "quit-docker" ]]; then
        info "LLM RAM mode: quit-docker (stop Docker before generation)" >&2
        docker_quit_for_generation || die "Could not stop Docker for quit-docker mode"
        return 0
    fi
}

resume_after_llm() {
    if [[ "$LLM_RAM_MODE" == "quit-docker" ]]; then
        docker_restore_after_generation || die "Docker/Lab restore failed after generation"
    fi
}

docker_quit_for_generation() {
    local uname_s
    uname_s=$(uname -s 2>/dev/null || echo unknown)
    info "Stopping Docker engine/desktop..." >&2

    if command -v docker >/dev/null 2>&1 && docker desktop stop >/dev/null 2>&1; then
        return 0
    fi
    if [[ "$uname_s" == "Darwin" ]]; then
        osascript -e 'quit app "Docker"' >/dev/null 2>&1 && return 0
    fi
    if grep -qi microsoft /proc/version 2>/dev/null; then
        powershell.exe -NoProfile -Command "Stop-Process -Name 'Docker Desktop' -Force" >/dev/null 2>&1 && return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop docker-desktop >/dev/null 2>&1 && return 0
        systemctl stop docker >/dev/null 2>&1 && return 0
    fi
    return 1
}

docker_restore_after_generation() {
    local uname_s
    uname_s=$(uname -s 2>/dev/null || echo unknown)
    info "Starting Docker engine/desktop..." >&2

    if command -v docker >/dev/null 2>&1 && docker desktop start >/dev/null 2>&1; then
        :
    elif [[ "$uname_s" == "Darwin" ]]; then
        open -a Docker >/dev/null 2>&1 || true
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        powershell.exe -NoProfile -Command "Start-Process 'Docker Desktop'" >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl --user start docker-desktop >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true
    fi

    local i
    for i in $(seq 1 90); do
        docker info >/dev/null 2>&1 && break
        sleep 2
    done
    docker info >/dev/null 2>&1 || return 1

    info "Waiting for SOC lab services..." >&2
    bash "$REPO_ROOT/soc-lab" --cli stack start >/dev/null 2>&1 || true
    for i in $(seq 1 120); do
        curl -sf "$ES_URL/_cluster/health" >/dev/null 2>&1 && { ok "Docker/Lab recovered" >&2; return 0; }
        sleep 2
    done
    return 1
}

pipeline_exists_in_es() {
    local name="$1"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$ES_URL/_ingest/pipeline/$name")
    [[ "$code" == "200" ]]
}

_yml_to_json() {
    local f="$1"
    python3 - "$f" << 'PY'
import sys, json, yaml
doc = yaml.safe_load(open(sys.argv[1]))
print(json.dumps(doc))
PY
}

load_pipeline() {
    local name="$1" file="$2"
    local status
    status=$(_yml_to_json "$file" | curl -s -o /dev/null -w "%{http_code}" -X PUT "$ES_URL/_ingest/pipeline/$name" -H 'Content-Type: application/json' --data-binary @-)
    [[ "$status" == "200" ]] || die "Failed to load pipeline '$name' from $file (HTTP $status)"
}

resolve_explicit_pipeline() {
    local t="$1"
    if pipeline_exists_in_es "$t"; then
        echo "$t"
        return 0
    fi
    local p
    p=$(pipeline_file_for_type "$t") || {
        local hints
        hints=$(pipeline_hints_for_type "$t" || true)
        if [[ -n "$hints" ]]; then
            {
                echo "Pipeline '$t' not found in Elasticsearch or local folders."
                echo "Did you mean:"
                while IFS= read -r h; do
                    [[ -n "$h" ]] && echo "  - $h"
                done <<< "$hints"
            } >&2
            exit 1
        fi
        die "Pipeline '$t' not found in Elasticsearch or local folders ($PIPELINES_ES, $PIPELINES_CUSTOM, $PIPELINES_GEN)"
    }
    local pname
    pname=$(basename "$p")
    pname="${pname%.*}"
    load_pipeline "$pname" "$p"
    echo "$pname"
}

choose_ollama_model_7b() {
    python3 - "$OLLAMA_URL" << 'PY'
import sys, json, urllib.request
url = sys.argv[1]
try:
    with urllib.request.urlopen(url + '/api/tags', timeout=10) as r:
        tags = json.load(r)
except Exception:
    print('')
    sys.exit(0)
models = [m.get('name','') for m in tags.get('models', [])]
priority = [
    'qwen2.5-coder:7b',
    'qwen2.5:7b',
    'mistral:7b',
    'llama3.1:8b',
    'qwen3:8b',
]
for p in priority:
    for m in models:
        if p in m:
            print(m)
            sys.exit(0)
print('')
PY
}

generate_pipeline_ai() {
    local sample_file="$1" pipeline_name="$2"
    mkdir -p "$PIPELINES_GEN"
    local out="$PIPELINES_GEN/${pipeline_name}.yml"

    local model
    model=$(choose_ollama_model_7b)
    [[ -n "$model" ]] || die "No suitable 7B/8B Ollama model found. Install one (for example: ollama pull qwen2.5-coder:7b)"
    info "Generating pipeline with Ollama model: $model" >&2

    local samples llm_out
    samples=$(mktemp /tmp/upload-samples-XXXXXX)
    grep -v '^[[:space:]]*$' "$sample_file" | head -20 > "$samples"
    llm_out=$(mktemp /tmp/upload-llm-XXXXXX)

    pause_for_llm
    local validate_flag="true"
    [[ "$LLM_RAM_MODE" == "quit-docker" ]] && validate_flag="false"
    if ! PIPELINE_GEN_VALIDATE_ES="$validate_flag" python3 "$REPO_ROOT/scripts/tools/pipeline_generator.py" "$samples" "$pipeline_name" "$model" > "$llm_out"; then
        resume_after_llm
        rm -f "$samples" "$llm_out"
        die "LLM pipeline generation failed"
    fi
    resume_after_llm

    cp "$llm_out" "$out"
    rm -f "$samples" "$llm_out"
    [[ -s "$out" ]] || die "Generated pipeline file is empty"
    echo "$out"
}

check_batch_consistency() {
    local files=("$@")
    local first_ext=""
    local mixed=false
    local f ext
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        ext="${f##*.}"
        ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
        if [[ -z "$first_ext" ]]; then
            first_ext="$ext"
            continue
        fi
        if [[ "$ext" != "$first_ext" ]]; then
            mixed=true
            break
        fi
    done
    if $mixed; then
        warn "Batch folder has mixed file extensions. Expected one log type per folder."
    fi
}

wrap_now_pipeline() {
    local base="$1" now_name="${base}-now"
    curl -s -o /dev/null -X PUT "$ES_URL/_ingest/pipeline/$now_name" \
        -H 'Content-Type: application/json' \
        -d '{"processors":[{"pipeline":{"name":"'"$base"'"}},{"set":{"field":"event.created","copy_from":"@timestamp","ignore_failure":true}},{"set":{"field":"@timestamp","value":"{{{_ingest.timestamp}}}"}}]}'
    echo "$now_name"
}

process_file() {
    local original="$1" fixed_pipeline="${2:-}"
    local tmp_files=()
    trap 'rm -f "${tmp_files[@]+${tmp_files[@]}}" 2>/dev/null' RETURN

    local work_file
    work_file=$(preprocess "$original")
    [[ -n "$work_file" ]] || die "Could not preprocess $original"
    [[ "$work_file" != "$original" ]] && tmp_files+=("$work_file")

    local format
    format=$(detect_format "$work_file")

    local base date_suffix index index_pattern count pipeline_used="none"
    base=$(basename "$original" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9\n' '-' | sed 's/^-//;s/-$//')
    date_suffix=$(date +%Y.%m.%d)
    if [[ -n "$INDEX_OVERRIDE" ]]; then
        index="${INDEX_OVERRIDE}-$date_suffix"
    else
        index="logs-${base}-$date_suffix"
    fi
    index_pattern="${index%-*}-*"

    if ! $KEEP; then
        curl -s -X DELETE "$ES_URL/_data_stream/$index_pattern" >/dev/null 2>&1 || true
        curl -s -X DELETE "$ES_URL/$index_pattern" >/dev/null 2>&1 || true
    fi

    case "$format" in
        json)
            info "Strategy: json direct ingest"
            count=$(bulk_ingest_json "$work_file" "$index")
            ;;
        cef)
            info "Strategy: cef convert + direct ingest"
            local cef_json
            cef_json=$(convert_cef "$work_file")
            tmp_files+=("$cef_json")
            count=$(bulk_ingest_json "$cef_json" "$index")
            ;;
        other)
            local pipeline="$fixed_pipeline"
            if [[ -z "$pipeline" ]]; then
                if [[ -n "$TYPE_OVERRIDE" ]]; then
                    info "Strategy: explicit --type pipeline"
                    pipeline=$(resolve_explicit_pipeline "$TYPE_OVERRIDE")
                elif $USE_AI; then
                    info "Strategy: --build-pipeline"
                    local pname pfile
                    pname="gen-${base}"
                    pfile=$(generate_pipeline_ai "$work_file" "$pname")
                    load_pipeline "$pname" "$pfile"
                    pipeline="$pname"
                else
                    die "For text logs you must specify --type <pipeline> or --build-pipeline"
                fi
            fi
            if $NOW; then
                pipeline=$(wrap_now_pipeline "$pipeline")
            fi
            pipeline_used="$pipeline"
            count=$(bulk_ingest_raw "$work_file" "$index" "$pipeline")
            ;;
    esac

    ensure_data_view "$index_pattern" "$base"
    report_ingest_quality "$index" "$pipeline_used" "$KEEP"
    ok "$(basename "$original") -> $index ($count docs, pipeline: $pipeline_used)"
}

if $BATCH; then
    [[ -d "$FOLDER" ]] || die "Batch folder not found: $FOLDER"
    shopt -s nullglob
    files=("$FOLDER"/*)
    shopt -u nullglob
    [[ ${#files[@]} -gt 0 ]] || die "No files in folder: $FOLDER"
    check_batch_consistency "${files[@]}"

    shared_pipeline=""
    batch_keep_original="$KEEP"
    KEEP=true
    info "Batch mode: forcing keep semantics across all files"
    if [[ -n "$TYPE_OVERRIDE" ]]; then
        shared_pipeline=$(resolve_explicit_pipeline "$TYPE_OVERRIDE")
        info "Batch strategy: explicit pipeline '$shared_pipeline' for all files"
    elif $USE_AI; then
        require_ollama_ready
        first=""
        for f in "${files[@]}"; do
            [[ -f "$f" ]] || continue
            first="$f"
            break
        done
        [[ -n "$first" ]] || die "No regular files in folder: $FOLDER"
        fmt=$(detect_format "$first")
        info "Batch strategy source file: $(basename "$first") (format=$fmt)"
        if [[ "$fmt" == "other" ]]; then
            batch_name="gen-batch-$(basename "$FOLDER" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9\n' '-')"
            batch_file=$(generate_pipeline_ai "$first" "$batch_name")
            load_pipeline "$batch_name" "$batch_file"
            shared_pipeline="$batch_name"
            info "Batch strategy: generated pipeline '$shared_pipeline' from first file, reusing for remaining files"
        else
            info "Batch strategy: non-text first file; each file ingests by detected format"
        fi
    fi

    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == .* ]] && continue
        process_file "$f" "$shared_pipeline"
    done
    KEEP="$batch_keep_original"
else
    [[ -f "$TARGET" ]] || die "File not found: $TARGET"
    if $USE_AI; then
        require_ollama_ready
    fi
    process_file "$TARGET"
fi
