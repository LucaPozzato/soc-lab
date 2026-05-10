# SOC Lab

Personal security lab for testing Suricata IDS detection and whitelist rules via PCAP replay and live capture.

## Stack

| Container | Image | Role |
|---|---|---|
| elasticsearch | elastic/elasticsearch:8.13.0 | Log storage and search |
| kibana | elastic/kibana:8.13.0 | Dashboards — http://localhost:5601 |
| suricata | jasonish/suricata:latest | IDS — writes eve.json |
| filebeat | elastic/filebeat:8.13.0 | Ships suricata logs to ES |
| elastalert2 | jertel/elastalert2:latest | Alerting — converts Sigma rules, fires on ES matches |

## Quick Start

```bash
./docker.sh start
```

On first run, Suricata downloads ~43k Emerging Threats community rules (~1-2 minutes). Rules persist across restarts.

## Security Onion ingest compatibility

Suricata events are parsed with Security Onion (SO) ingest pipelines and ECS component templates, loaded at startup.

- `docker.sh start` runs `load-so-templates.sh` and `load-so-pipelines.sh` after Elasticsearch is healthy
- Filebeat writes to `suricata-%{+yyyy.MM.dd}` with ingest pipeline `suricata.common`
- `suricata.common` dispatches by event type; `suricata.alert` is patched to also dispatch by `app_proto` when available
- Alert docs are forced to `event.dataset: suricata.alert` and stay in `suricata-*` (no alert index override)
- `suricata-so-ecs` template composes SO ECS components and sets `index.mapping.total_fields.limit: 5000`

This keeps broad event coverage (dns/http/tls/flow/quic/alert/etc.) while preserving SO-native parsing behavior.

## Directory Layout

```
config/
  suricata/suricata.yaml      Suricata config
  suricata/threshold.config   Alert suppression (checksum noise SIDs)
  filebeat/filebeat.yml       Log shipping config
  elastalert2/
    elastalert2.yml           ElastAlert2 config (run interval, buffer window)
    rules/                    Hand-written ElastAlert2 rules (deployed directly)
scripts/
  suricata-start.sh           Container entrypoint: downloads rules on first run
  elastalert-start.sh         Container entrypoint: converts Sigma rules, starts ElastAlert2
logs/
  suricata/                   eve.json and suricata.log written here
pcap/                         Drop .pcap files here for replay
rules/
  suricata/                   Custom Suricata .rules files (auto-loaded by Suricata)
  sigma/                      Sigma rule files (auto-converted to ElastAlert2 on startup)
```

## Scripts

| Script | What it does |
|---|---|
| `docker.sh start` | Start stack, wait for healthy, load SO templates/pipelines, create ES data views |
| `docker.sh stop` | Stop containers, keep volumes (ES data + rules) |
| `docker.sh reset` | Stop containers and wipe all volumes |
| `check-health.sh` | Container status, ES cluster health, recent log samples, ElastAlert2 alert count |
| `replay-pcap.sh` | Replay a .pcap through Suricata |
| `live-capture.sh` | Continuous tcpdump capture with auto-replay |
| `reload-rules.sh` | Pull latest ET community rules, reload without restart |
| `clean.sh` | Wipe ES indices, eve.json, and suricata.log for a clean slate |
| `upload-logs.sh` | Upload arbitrary logs, auto-pick/LLM-generate ingest pipeline |

## PCAP Replay

```bash
cp /path/to/capture.pcap ./pcap/
./replay-pcap.sh pcap/capture.pcap
```

Each replay wipes previous Suricata events and all ElastAlert2 state (alerts, status, silence), then restarts ElastAlert2 so it rescans from scratch. Suricata events appear in Kibana under `suricata-*`; ElastAlert2 alerts under `elastalert2_alerts`. Both are combined in the `soc-alerts` unified alias (Kibana data view "Alerts"), which shows Suricata IDS alerts and ElastAlert2/Sigma fired alerts together in one place.

Replay also re-applies the `suricata-soc-alerts` template and re-attaches the `soc-alerts` alias after the new `suricata-*` index is created, so Suricata alert membership is stable after resets.

The optional `-now` flag shifts all event timestamps to the current time while preserving relative timing:

```bash
./replay-pcap.sh pcap/capture.pcap --now
./replay-pcap.sh pcap/capture.pcap --keep
```

Without `-now`, original PCAP timestamps are preserved and Kibana shows events at their original capture time.

## ElastAlert2 and Sigma Rules

ElastAlert2 queries Elasticsearch on a 5-second cycle and fires alerts when rule conditions match.

**Two ways to write rules:**

1. **Sigma rules** — place `.yml` files in `./rules/sigma/`. On each container start, `elastalert-start.sh` converts them to ElastAlert2 format via `sigma convert`. Good for portable, shareable detection logic.

2. **Native ElastAlert2 rules** — place `.yaml` files in `./config/elastalert2/rules/`. These are deployed directly without conversion. Good for rules that need ElastAlert2-specific features.

Alerts are stored in the `elastalert2_alerts` index in Elasticsearch. The `@timestamp` field is patched to reflect the original event time (not the time ElastAlert2 ran), so Kibana shows alerts on the correct timeline.

## Live Capture

Captures traffic via tcpdump on a macOS interface, rotates PCAPs, and auto-replays each one through Suricata.

```bash
./live-capture.sh              # capture on en0, rotate every 10s
./live-capture.sh lo0 30       # loopback interface, rotate every 30s
./live-capture.sh -h           # full usage
```

- Each session starts fresh (ES indices and eve.json cleared)
- Each completed rotation is replayed through Suricata and appended to eve.json
- Filebeat ships events continuously — no restarts between rotations
- Ctrl+C stops capture; indexed events remain in Kibana
- There is always a ~rotation_seconds delay before traffic appears in Kibana (default ~10s)

> Use `lo0` for localhost testing, or use PCAP replay for clean controlled analysis.

## Testing Rules

### Network topology for localhost testing

`HOME_NET` includes `127.0.0.0/24`. The separate subnet `127.0.1.0/24` is treated as `EXTERNAL_NET`. This lets directional rules fire correctly on localhost traffic.

| Range | Classification |
|---|---|
| `127.0.0.0/24` | HOME_NET (internal) |
| `127.0.1.0/24` | EXTERNAL_NET (external) |

If `127.0.1.x` addresses are not available on your system, bind one manually:

```bash
sudo ip addr add 127.0.1.1/8 dev <loopback-interface>
```

### Simulating inbound traffic (external → internal)

Run your server on `127.0.0.1`, curl from `127.0.1.1`:

```bash
curl --interface 127.0.1.1 http://127.0.0.1/malicious-path
```

Rules matching `$EXTERNAL_NET → $HOME_NET` will fire.

### Simulating outbound traffic (internal → external)

Run your server on `127.0.1.1`, curl from `127.0.0.1`:

```bash
curl --interface 127.0.0.1 http://127.0.1.1/beacon
```

Rules matching `$HOME_NET → $EXTERNAL_NET` will fire.

### HTTP testing

```bash
# Start a simple HTTP server on the "external" address
python3 -m http.server 8080 --bind 127.0.1.1

# Capture and replay loopback traffic
./live-capture.sh lo0 30

# In another terminal, generate traffic
curl --interface 127.0.0.1 "http://127.0.1.1:8080/evil.exe"
```

### SMB testing

```bash
# Start your SMB server bound to 127.0.1.1 (port 445)
# Capture loopback
./live-capture.sh lo0 30

# Connect from the "internal" side
smbclient //127.0.1.1/share -U user --interface 127.0.0.1
```

### Checking alert count after a replay

```bash
# Total Suricata alerts
curl -s "http://localhost:9200/suricata-*/_count?q=event_type:alert"

# Alerts by signature
curl -s "http://localhost:9200/suricata-*/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"size":0,"query":{"term":{"event_type":"alert"}},"aggs":{"by_sig":{"terms":{"field":"alert.signature.keyword","size":20}}}}'

# ElastAlert2 fired alerts
curl -s "http://localhost:9200/elastalert2_alerts/_count"

# All alerts unified (Suricata IDS + ElastAlert2/Sigma)
curl -s "http://localhost:9200/soc-alerts/_count"

# Dataset distribution in suricata-* (quick parse sanity)
curl -s "http://localhost:9200/suricata-*/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"size":0,"aggs":{"by_dataset":{"terms":{"field":"event.dataset.keyword","size":20}}}}'

# Alert protocol enrichment check (examples)
curl -s "http://localhost:9200/suricata-*/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"size":5,"query":{"term":{"event.dataset.keyword":"suricata.alert"}},"_source":["event.dataset","app_proto","dns.query.name","http.response.status_code","ssl.server_name","alert.signature"]}'

# Quick count from eve.json directly
docker exec suricata grep -c '"event_type":"alert"' /var/log/suricata/eve.json
```

## Custom Rules

**Suricata rules:** Add `.rules` files to `./rules/suricata/` — loaded automatically by Suricata. To reload without restarting:

```bash
./reload-rules.sh
```

**Sigma rules:** Add `.yml` files to `./rules/sigma/` — converted to ElastAlert2 format on every container start. Restart the `elastalert2` container after adding new rules:

```bash
docker restart elastalert2
```

Suricata rule syntax reference: https://docs.suricata.io/en/latest/rules/index.html

## Upload Arbitrary Logs

Use this when ingesting non-Suricata logs into Elasticsearch:

```bash
./upload-logs.sh logs/test/syslog.log --build-pipeline
./upload-logs.sh logs/test/cisco-asa.log --type cisco
./upload-logs.sh logs/test/custom.log --type pipelines/custom/my-parser.yml
./upload-logs.sh logs/test/apache-access.log --type apache-access --now
./upload-logs.sh --batch --folder logs/test/custom-stress --build-pipeline
```

Behavior:

- JSON logs: shipped directly (no pipeline matching)
- CEF logs: converted and shipped directly
- Other logs: require explicit mode (`--type` or `--build-pipeline`)
- `--type`: uses pipeline from Elasticsearch, `pipelines/elasticsearch/`, `pipelines/custom/`, or `pipelines/generated/`
- `--build-pipeline`: generates a parser with local bare-metal Ollama (7B preferred) and validates it against Elasticsearch (unless `--llm-ram-mode quit-docker`)
- Generated pipelines are cached in `pipelines/generated/`

Notes:

- No automatic pipeline matching is performed
- The local generator lives in `scripts/pipeline_generator.py`

Flags:

- `--keep`: keep existing target index data (no delete)
- `--now`: for matched text pipelines, rewrites `@timestamp` to ingest time while preserving original event time in `event.created`
- `--type <name|path.yml>`: use exact pipeline name or direct YAML path
- `--build-pipeline`: auto-build parser locally (requires local Ollama running at `http://localhost:11434`)
- `--batch --folder <dir>`: process all files in directory with one selected/generated text pipeline
- `--llm-ram-mode <none|quit-docker>`: memory behavior during `--build-pipeline` (default `none`; `quit-docker` disables ES validation during generation, then cycles Docker and waits for lab recovery before ingest)

Batch note:

- Put same log family in one folder; mixed file extensions are flagged with a warning.

`--build-pipeline` requires a local bare-metal Ollama instance reachable at `http://localhost:11434`.

## Stop / Reset

```bash
./docker.sh stop    # stop, keep volumes (ES data + rules)
./docker.sh reset   # stop and wipe everything (rules re-download on next start)
```

## Known Constraints

- **ES yellow status**: Normal on a single-node cluster — replicas are unassigned.
- **Live capture delay**: Traffic appears in Kibana after the current rotation completes, not in real time.
- **First-run rule download**: Requires internet access, takes ~1-2 minutes.
- **ElastAlert2 timestamp race**: `@timestamp` on alerts is patched to event time by a background loop every 2 seconds. Alerts will briefly show processing time in Kibana immediately after firing (window is ~2 seconds).
