#!/bin/sh

STATIC_RULES=/opt/elastalert2/rules-static   # hand-written rules (bind-mounted read-only)
SIGMA_DIR=/opt/sigma/rules                    # sigma source files (bind-mounted read-only)
RULES_OUT=/opt/elastalert2/rules              # writable rules dir ElastAlert2 reads from

echo "[*] Installing sigma plugin..."
pip install sigma-cli -q 2>/dev/null
sigma plugin install elasticsearch 2>&1 | grep -v '^WARNING'

# Patch helper: fix index wildcard → suricata-* and add required alert field
cat > /tmp/patch_rule.py << 'EOF'
import sys, yaml
path = sys.argv[1]
with open(path) as fh:
    r = yaml.safe_load(fh)
if not r.get('index') or r['index'] in ('*', ''):
    r['index'] = 'suricata-*'
if 'alert' not in r:
    r['alert'] = ['debug']
with open(path, 'w') as fh:
    yaml.dump(r, fh, default_flow_style=False, allow_unicode=True)
EOF

# Rebuild rules dir from scratch: static hand-written + freshly converted sigma.
# Static rules are on a read-only bind mount so we copy them; sigma files are
# converted into the same writable dir. This keeps the host filesystem safe.
mkdir -p "$RULES_OUT"
find "$RULES_OUT" -name '*.yaml' -delete 2>/dev/null || true

echo "[*] Copying static rules..."
find "$STATIC_RULES" -name '*.yaml' | while read -r f; do
    name=$(basename "$f")
    cp "$f" "$RULES_OUT/$name"
    echo "[+] Loaded: $name"
done

echo "[*] Converting Sigma rules..."
find "$SIGMA_DIR" -name '*.yml' | while read -r f; do
    name=$(basename "$f")
    out="$RULES_OUT/$(basename "$f" .yml).yaml"

    if sigma convert -t elastalert --without-pipeline "$f" > "$out" 2>/dev/null; then
        python3 /tmp/patch_rule.py "$out" 2>/dev/null || true
        echo "[+] Converted: $name"
    else
        rm -f "$out"
        echo "[!] Skipped (conversion failed): $name"
    fi
done

echo "[*] Initialising writeback indices..."
elastalert-create-index --config /opt/elastalert2/config.yaml --recreate False 2>&1 | grep -v '^WARNING'
# elastalert-create-index recreates elastalert2_alerts, dropping any aliases.
# Re-attach to soc-alerts with retries since the index may not be immediately writable.
python3 -c "
import urllib.request, json, time
payload = json.dumps({'actions': [
    {'add': {'index': 'elastalert2_alerts', 'alias': 'soc-alerts'}}
]}).encode()
for _ in range(5):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            'http://elasticsearch:9200/_aliases',
            data=payload, headers={'Content-Type': 'application/json'}, method='POST'), timeout=10)
        if r.status == 200:
            break
    except Exception:
        pass
    time.sleep(2)
" 2>/dev/null

# ElastAlert2 writes @timestamp = processing time. Patch it to the event time
# so Kibana timeline shows when the event happened, not when the alert ran.
(while true; do
    sleep 2
    python3 -c "
import json, urllib.request
payload = json.dumps({
    'script': {
        'lang': 'painless',
        'source': '''
            if (ctx._source.containsKey(\"match_body\") &&
                ctx._source.match_body.containsKey(\"@timestamp\")) {
                if (!ctx._source[\"@timestamp\"].equals(ctx._source.match_body[\"@timestamp\"])) {
                    ctx._source[\"@timestamp\"] = ctx._source.match_body[\"@timestamp\"];
                } else {
                    ctx.op = \"noop\";
                }
            } else {
                ctx.op = \"noop\";
            }
        '''
    },
    'query': {'match_all': {}}
}).encode()
try:
    urllib.request.urlopen(
        urllib.request.Request(
            'http://elasticsearch:9200/elastalert2_alerts/_update_by_query?conflicts=proceed',
            data=payload,
            headers={'Content-Type': 'application/json'},
            method='POST'),
        timeout=10)
except Exception:
    pass
" 2>/dev/null
done) &

echo "[*] Starting elastalert2..."
exec python -m elastalert.elastalert --config /opt/elastalert2/config.yaml
