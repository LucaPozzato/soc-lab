#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/log.sh"

ES_URL="${ES_URL:-http://localhost:9200}"
SO_RAW="https://raw.githubusercontent.com/Security-Onion-Solutions/securityonion/2.4/main/salt/elasticsearch/files/ingest"
SO_RAW_DYNAMIC="https://raw.githubusercontent.com/Security-Onion-Solutions/securityonion/2.4/main/salt/elasticsearch/files/ingest-dynamic"

SO_PIPELINES=(
  suricata.common suricata.alert suricata.dnp3 suricata.dns suricata.smtp suricata.http suricata.flow suricata.tls
  suricata.ssh suricata.smb suricata.ftp suricata.ftp_data suricata.fileinfo suricata.krb5 suricata.snmp suricata.ike
  suricata.rdp suricata.nfs suricata.tftp suricata.dhcp suricata.sip suricata.tld suricata.dnsv3 common common.nids dns.tld http.status
)

wait_for_es() {
  for _ in $(seq 1 30); do
    curl -sf "$ES_URL/_cluster/health" -o /dev/null 2>&1 && return 0
    sleep 2
  done
  die "Elasticsearch did not become ready in time"
}

load_pipeline() {
  local name="$1" body="$2" status
  status=$(echo "$body" | curl -s -o /dev/null -w "%{http_code}" -X PUT "$ES_URL/_ingest/pipeline/$name" -H 'Content-Type: application/json' --data-binary @-)
  if [[ "$status" == "200" ]]; then
    ok "Loaded: $name"
  else
    warn "Failed: $name (HTTP $status)"
  fi
}

load_so_pipeline() {
  local name="$1" body
  if [[ "$name" == "common" ]]; then
    body=$(curl -sf "$SO_RAW_DYNAMIC/$name" 2>/dev/null) || { warn "Missing in SO repo: $name"; return; }
    body=$(python3 -c 'import sys,re; s=sys.stdin.read(); print("\n".join([ln for ln in s.splitlines() if not re.match(r"^\s*\{%-?.*%\}\s*$", ln)]))' <<< "$body")
  else
    body=$(curl -sf "$SO_RAW/$name" 2>/dev/null) || { warn "Missing in SO repo: $name"; return; }
  fi

  if [[ "$name" == "suricata.alert" ]]; then
    # Insert order before common.nids: first suricata.{{app_proto}} (enriches TLS/DNS
    # fields), then re-assert event.dataset=suricata.alert so the sub-pipeline cannot
    # clobber it (e.g. suricata.tls sets event.dataset=ssl which would mis-route alerts).
    body=$(python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
p = d.get("processors", [])
p = [x for x in p if not ("set" in x and x["set"].get("field") == "_index")]
i = next((k for k, v in enumerate(p) if "pipeline" in v and v["pipeline"].get("name") == "common.nids"), len(p))
p.insert(i, {"pipeline": {"if": "ctx.message2?.app_proto != null", "name": "suricata.{{message2.app_proto}}", "ignore_missing_pipeline": True, "ignore_failure": True}})
p.insert(i + 1, {"set": {"field": "event.dataset", "value": "suricata.alert"}})
d["processors"] = p
print(json.dumps(d))
' <<< "$body")
  elif [[ "$name" == "suricata.common" ]]; then
    body=$(python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); p=d.get("processors",[])
for x in p:
    q=x.get("pipeline")
    if isinstance(q,dict) and q.get("name")=="suricata.{{event.dataset}}":
        q["ignore_missing_pipeline"]=True; q["ignore_failure"]=True
print(json.dumps(d))' <<< "$body")
  elif [[ "$name" == "common" ]]; then
    # The SO common pipeline references ecs and global@custom sub-pipelines that do not
    # exist in this minimal deployment. Add ignore_missing_pipeline+ignore_failure to all
    # pipeline processor calls so documents are not dropped when those are absent.
    body=$(python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
for proc in d.get("processors", []):
    q = proc.get("pipeline")
    if isinstance(q, dict):
        q.setdefault("ignore_missing_pipeline", True)
        q.setdefault("ignore_failure", True)
print(json.dumps(d))
' <<< "$body")
  fi

  load_pipeline "$name" "$body"
}

main() {
  banner "SO Pipelines Loader"
  wait_for_es
  info "Loading SO ingest pipelines"
  for p in "${SO_PIPELINES[@]}"; do
    load_so_pipeline "$p"
  done
  ok "All SO pipelines loaded"
}

main "$@"
