#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
info() { echo -e "[*] $*"; }

ES_URL="${ES_URL:-http://localhost:9200}"
SO_RAW="https://raw.githubusercontent.com/Security-Onion-Solutions/securityonion/2.4/main/salt/elasticsearch/files/ingest"
SO_RAW_DYNAMIC="https://raw.githubusercontent.com/Security-Onion-Solutions/securityonion/2.4/main/salt/elasticsearch/files/ingest-dynamic"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SO_PIPELINES=(
  suricata.common
  suricata.alert
  suricata.dnp3
  suricata.dns
  suricata.smtp
  suricata.http
  suricata.flow
  suricata.tls
  suricata.ssh
  suricata.smb
  suricata.ftp
  suricata.ftp_data
  suricata.fileinfo
  suricata.krb5
  suricata.snmp
  suricata.ike
  suricata.rdp
  suricata.nfs
  suricata.tftp
  suricata.dhcp
  suricata.sip
  suricata.tld
  suricata.dnsv3
  common
  common.nids
  dns.tld
  http.status
)

wait_for_es() {
  info "Waiting for Elasticsearch..."
  for i in $(seq 1 30); do
    curl -sf "$ES_URL/_cluster/health" -o /dev/null 2>&1 && { ok "Elasticsearch is up"; return 0; }
    sleep 2
  done
  die "Elasticsearch did not become ready in time"
}

load_pipeline() {
  local name="$1" body="$2"
  local status
  status=$(echo "$body" | curl -s -o /dev/null -w "%{http_code}" -X PUT "$ES_URL/_ingest/pipeline/$name" -H 'Content-Type: application/json' --data-binary @-)
  if [[ "$status" == "200" ]]; then
    ok "Loaded: $name"
  else
    warn "Failed: $name (HTTP $status) - may not exist in SO repo, skipping"
  fi
}

load_so_pipeline() {
  local name="$1"
  local body
  if [[ "$name" == "common" ]]; then
    body=$(curl -sf "$SO_RAW_DYNAMIC/$name" 2>/dev/null) || { warn "Not found in SO repo: $name, skipping"; return; }
    body=$(python3 -c 'import sys,re; s=sys.stdin.read(); out=[]
for line in s.splitlines():
    if re.match(r"^\s*\{%-?.*%\}\s*$", line):
        continue
    out.append(line)
print("\n".join(out))' <<< "$body")
  else
    body=$(curl -sf "$SO_RAW/$name" 2>/dev/null) || { warn "Not found in SO repo: $name, skipping"; return; }
  fi
  if [[ "$name" == "suricata.alert" ]]; then
    body=$(python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); procs=d.get("processors",[]); procs=[p for p in procs if not ("set" in p and p["set"].get("field")=="_index")];
inject={"pipeline":{"if":"ctx.message2?.app_proto != null","name":"suricata.{{message2.app_proto}}","ignore_missing_pipeline":True,"ignore_failure":True}};
force_alert_dataset={"set":{"field":"event.dataset","value":"suricata.alert"}};
idx=next((i for i,p in enumerate(procs) if "pipeline" in p and p["pipeline"].get("name")=="common.nids"), len(procs));
procs.insert(idx, inject); d["processors"]=procs; print(json.dumps(d))' <<< "$body")
    body=$(python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); procs=d.get("processors",[]); idx=next((i for i,p in enumerate(procs) if "pipeline" in p and p["pipeline"].get("name")=="common.nids"), len(procs)); procs.insert(idx, {"set":{"field":"event.dataset","value":"suricata.alert"}}); d["processors"]=procs; print(json.dumps(d))' <<< "$body")
  elif [[ "$name" == "suricata.common" ]]; then
    body=$(python3 -c 'import sys,json; d=json.loads(sys.stdin.read());
procs=d.get("processors",[])
for p in procs:
    pipe=p.get("pipeline")
    if isinstance(pipe,dict) and pipe.get("name")=="suricata.{{event.dataset}}":
        pipe["ignore_missing_pipeline"]=True
        pipe["ignore_failure"]=True
print(json.dumps(d))' <<< "$body")
  fi
  load_pipeline "$name" "$body"
}

main() {
  wait_for_es

  info "Loading SO ingest pipelines from GitHub..."
  for p in "${SO_PIPELINES[@]}"; do
    load_so_pipeline "$p"
  done

  ok "All pipelines loaded"
}

main "$@"
