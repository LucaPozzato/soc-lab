# SOC Lab — How Everything Works

---

## Modes of operation

SOC Lab supports two user-facing modes:

1. **TUI** (`./soc-lab` or `./soc-lab tui`) — interactive Bubble Tea terminal UI; type subcommands at a prompt
2. **Direct CLI** (`./soc-lab <group> <command> ...`) — runs one command and exits; best for scripts and automation

Both modes call the same underlying shell scripts. The TUI is just a wrapper that streams command output into a viewport and provides status panels on top.

---

## The stack: what each piece actually is

### Elasticsearch

Elasticsearch is a search and analytics database built on Apache Lucene. It stores data as JSON documents and exposes a REST API over HTTP on port 9200. Everything — storing, querying, deleting — is HTTP.

Documents are organized into **indices** (schema-flexible tables). This lab uses daily indices named `suricata-YYYY.MM.DD`. Each document is one event from `eve.json`: one alert, one DNS query, one TLS handshake.

When Filebeat ships a log line it does `POST /suricata-2026.04.19/_doc`. When Kibana queries it does `POST /suricata-*/_search`. Everything is JSON over HTTP.

Internally, ES inverts document fields into a **search index** — for every term in every field it builds a posting list of which documents contain that term. This makes queries like "all alerts where `alert.signature` contains `ET MALWARE`" fast across millions of documents.

**Why `yellow` cluster status?** ES is designed to replicate shards across nodes. On a single node, replica shards have nowhere to go so they stay `UNASSIGNED`. The cluster is fully functional — all data is present — but ES reports `yellow` because the replication target isn't met. `green` requires at least 2 nodes. `index.number_of_replicas: 0` is set via an index template to suppress this.

### Kibana

Kibana is a web UI that sits in front of Elasticsearch. It has no database of its own — every piece of data you see was fetched from ES at request time. When you open Discover and set a time range, Kibana translates your filters into an ES query (`POST /_search`), receives the JSON response, and renders it.

When you create a visualization, Kibana stores the configuration as a "saved object" inside ES itself — in a special `.kibana` index. Kibana persists nothing locally; it is purely a query-and-render layer.

A **data view** tells Kibana "there is an index pattern called `suricata-*` and `@timestamp` is the time field." Without this, Kibana does not know the index exists. `stack start` creates data views by POSTing to Kibana's REST API (`/api/data_views/data_view`), which stores them as documents in `.kibana`.

```
your browser
    ↕ HTTP :5601
  Kibana
    ↕ HTTP :9200 (Docker internal network)
  Elasticsearch
```

Your browser never talks to ES directly. Kibana is the middleman.

### Filebeat

Filebeat is a lightweight log shipper. It tails `eve.json` on disk and POSTs new lines to Elasticsearch. It is essentially a managed `tail -f` with JSON parsing, field manipulation, and HTTP output.

Filebeat keeps a **registry** (in the `filebeat_data` Docker volume at `/usr/share/filebeat/data/registry/`) that records, for each watched file, the inode and the byte offset last read. On restart it resumes from that offset — no duplicates, no gaps.

When `capture replay` resets `eve.json` and Suricata creates a new one, the new file gets a new inode. Filebeat detects the inode change and treats it as a new file, starting from byte 0. This is the correct behavior for clean replays.

Each batch of events becomes a `POST /_bulk` request — ES's bulk ingest endpoint, which accepts multiple documents per HTTP call.

### Suricata + Security Onion ingest path

```
Network packet / PCAP
  -> Suricata event (JSON line in eve.json)
  -> Filebeat ships line to Elasticsearch
  -> Ingest pipeline suricata.common runs
  -> SO sub-pipeline parses by event type / protocol
  -> ECS-shaped document indexed in suricata-YYYY.MM.DD
```

Then detection and UX layers consume that indexed data:

```
suricata-* index
  -> Kibana (search / hunting)
  -> ElastAlert2 rules (detections)
       -> elastalert2_alerts index
            -> soc-alerts alias (unified alert view)
```

### ElastAlert2

ElastAlert2 is an alerting engine that queries Elasticsearch on a schedule and fires alerts when results match a rule. It is the bridge between raw ES data and actionable alerts.

Every 5 seconds, ElastAlert2 reads its rules folder, queries `suricata-*` for each rule's filter conditions, and writes matching results to `elastalert2_alerts`. Rules can be native ElastAlert2 YAML or **Sigma rules** — a vendor-neutral detection format that `elastalert-start.sh` converts automatically on container start.

ElastAlert2 maintains writeback indices:

| Index                        | Purpose                                                                   |
| ---------------------------- | ------------------------------------------------------------------------- |
| `elastalert2_alerts`         | One document per fired alert, including the matched event in `match_body` |
| `elastalert2_alerts_status`  | Per-rule scan progress (`endtime`)                                        |
| `elastalert2_alerts_silence` | Suppression records — prevents re-firing within `alert_time_limit`        |
| `elastalert2_alerts_error`   | Errors encountered while running rules                                    |

**Timestamp correction:** ElastAlert2 writes `@timestamp` as the processing time (when the alert ran), not the event time. A background loop in `elastalert-start.sh` patches this every 2 seconds by copying `match_body.@timestamp` → `@timestamp`, so Kibana's timeline shows when the event happened. The loop uses `ctx.op = "noop"` to skip already-patched documents and `conflicts=proceed` so a concurrent ElastAlert2 write does not abort the update.

**Scan window:** ElastAlert2 uses `endtime` in `elastalert2_alerts_status` to track where it last searched for each rule. On each run it only scans forward from that point. If you do a PCAP replay with old timestamps, clearing the status documents in ES is not enough — the running process keeps its scan window in memory. `capture replay` handles this by stopping and restarting the container, which forces ElastAlert2 to re-read from ES and use the full 180-day `buffer_time` on startup.

---

## `docker-compose.yml` — The spine of the stack

**Elasticsearch**

```yaml
discovery.type=single-node      # don't try to form a cluster
xpack.security.enabled=false    # no TLS, no auth — fine for a local lab
bootstrap.memory_lock=true      # prevents JVM heap from swapping to disk
ES_JAVA_OPTS=-Xms1g -Xmx1g     # fix heap at 1 GB
```

The `healthcheck` polls `/_cluster/health` every 15 s. Other containers declare `condition: service_healthy` on ES so they don't start until this passes.

**Kibana**

```yaml
ELASTICSEARCH_HOSTS=http://elasticsearch:9200   # Docker internal DNS
depends_on: elasticsearch: condition: service_healthy
```

Port 5601 is forwarded to the host.

**Suricata**

```yaml
entrypoint: ["/suricata-start.sh"]
./scripts/runtime/suricata-start.sh:/suricata-start.sh
./config/suricata/suricata.yaml:/etc/suricata/suricata.yaml
./docker-logs/suricata:/var/log/suricata        # eve.json on the host filesystem
./pcap:/pcap:ro                                  # pcap folder readable inside container
./rules/suricata:/etc/suricata/rules/custom      # custom rules auto-loaded
suricata_rules:/var/lib/suricata/rules           # ET rules survive restarts
```

**Filebeat**

```yaml
user: root                                  # needed to read Suricata-written files
./docker-logs/suricata:/var/log/suricata:ro
filebeat_data:/usr/share/filebeat/data      # persists read position
command: filebeat -e --strict.perms=false   # -e logs to stderr; skip ownership check
```

**ElastAlert2**

```yaml
./scripts/runtime/elastalert-start.sh:/elastalert-start.sh
./config/elastalert2/elastalert2.yml:/opt/elastalert2/config.yaml
./config/elastalert2/rules:/opt/elastalert2/rules-static:ro   # hand-written rules, read-only
./rules/sigma:/opt/sigma/rules:ro                              # sigma rules, read-only
```

The rules mount is read-only to prevent the startup script from accidentally modifying host files. The entrypoint copies rules from `/opt/elastalert2/rules-static` into a container-only writable directory before starting ElastAlert2.

**Volumes**

```yaml
es_data        # ES index data — survives docker compose down
filebeat_data  # Filebeat registry (tracks read position per file)
suricata_rules # ET rule files — avoids re-download every start
```

---

## `scripts/runtime/suricata-start.sh` — Suricata container entrypoint

```bash
if ! ls /var/lib/suricata/rules/*.rules 2>/dev/null | grep -q .; then
```

Checks if the named volume already has `.rules` files. If not (first run), downloads Emerging Threats rules:

```bash
suricata-update \
    --suricata-conf /etc/suricata/suricata.yaml \
    --output /var/lib/suricata/rules \
    --no-merge \   # keep individual rule files per source
    --no-test      # skip rule validation (faster)
```

Two rule files are deleted after download:

```bash
rm -f .../dnp3-events.rules .../modbus-events.rules
```

These cover industrial protocols (DNP3, Modbus). The `jasonish/suricata` image is compiled without those parsers, so loading these rules would error on startup.

```bash
exec sleep infinity
```

After rules are ready the container idles. **Suricata itself is not running as a daemon.** It only runs on-demand when replay/live paths call `docker exec suricata suricata ...`. `exec` replaces the shell so `sleep infinity` becomes PID 1 and Docker keeps the container alive.

`stack start` also runs `suricata-update` inside the already-running container to refresh ET rules on every start. If that fails, startup continues with existing rules and prints a warning.

---

## `scripts/runtime/elastalert-start.sh` — ElastAlert2 container entrypoint

```bash
sigma plugin install elasticsearch
```

Installs the ElastAlert2 backend for the `sigma` CLI, needed to convert Sigma rule files.

```bash
find "$SIGMA_DIR" -name '*.yml' | while read -r f; do
    sigma convert -t elastalert --without-pipeline "$f" > "$out"
    python3 /tmp/patch_rule.py "$out"
done
```

Converts every Sigma `.yml` from `./rules/sigma/` into ElastAlert2 YAML. The patch script fixes two things that sigma's conversion leaves incomplete:

- Sets `index: *` when the converted rule has no index or uses an empty value
- Adds `alert: [debug]` if the `alert` field is missing (required by ElastAlert2)

Previously converted rules are deleted first so removing a sigma file doesn't leave a stale converted rule.

```bash
elastalert-create-index --recreate False
```

Pre-creates ElastAlert2's writeback indices before starting. Without this, ElastAlert2 can crash with a 404 on its first run. `--recreate False` means: create if missing, leave alone if present.

As a side effect, `elastalert-create-index` drops all ES aliases. A retry loop re-attaches `elastalert2_alerts` to the `soc-alerts` alias after it runs (5 attempts, 2 s sleep each).

```bash
(while true; do
    sleep 2
    python3 -c "...update_by_query..." &
done) &
```

Background loop patching `@timestamp` every 2 seconds. Uses `ctx.op = "noop"` when already patched; `conflicts=proceed` to tolerate concurrent writes.

```bash
exec python -m elastalert.elastalert --config /opt/elastalert2/config.yaml
```

Starts ElastAlert2 as PID 1. `exec` ensures it receives SIGTERM directly on `docker stop`.

---

## `config/elastalert2/elastalert2.yml` — ElastAlert2 config

```yaml
run_every:
  seconds: 5 # query ES for new matches every 5 s

buffer_time:
  days: 180 # on first run (no status), scan back 180 days

alert_time_limit:
  minutes: 1 # discard queued-but-unsent alerts after 1 minute
```

`buffer_time: 180 days` is why PCAP replay works with old timestamps — ElastAlert2 finds events from PCAPs captured up to 6 months ago on its first scan after container restart.

`run_every: 5 s` combined with Filebeat's `scan_frequency: 1 s` means Sigma alerts typically fire within seconds of indexing.

---

## `soc-alerts` — Unified alerts alias

`soc-alerts` is an ES alias that combines two sources:

| Source               | Filter                                                                     |
| -------------------- | -------------------------------------------------------------------------- |
| `suricata-*`         | `event.dataset: alert` or `event.dataset: suricata.alert` or `tags: alert` |
| `elastalert2_alerts` | none — all ElastAlert2/Sigma alerts                                        |

A query to `soc-alerts` returns both Suricata IDS alerts and Sigma/ElastAlert2 detections without querying two separate indices.

**How it stays alive across resets:**

- An ES index template `suricata-soc-alerts` auto-applies the alias+filter to every new `suricata-*` index created by Filebeat, so the alias survives volume wipes.
- `elastalert-start.sh` re-attaches `elastalert2_alerts` to `soc-alerts` after `elastalert-create-index` runs (which drops all aliases as a side effect).
- `stack start` applies the template and alias at startup.

---

## `config/suricata/suricata.yaml`

**`vars`**

```yaml
HOME_NET: "[10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,...]"
EXTERNAL_NET: "!$HOME_NET"
```

Rules use these — e.g. `alert tcp $EXTERNAL_NET any -> $HOME_NET 22` = SSH from outside to inside.

**`outputs`**

```yaml
- eve-log:
    filename: eve.json
    append: yes       # replay resets the file before each run; append: yes is safe here
    types:
      - alert
      - flow
      - dns
      - http: extended: yes
      - tls: extended: yes
      - smtp/ssh/ftp/smb/rdp/krb5/...
```

Every event type listed becomes a JSON record in `eve.json`. Filebeat ships all of them, so Kibana shows not just alerts but all DNS, HTTP, and TLS traffic.

**`stream` and `pcap-file`**

```yaml
stream:
  checksum-validation: no
pcap-file:
  checksum-checks: no
```

NIC hardware offloading means captured packets often contain dummy checksums. Disabling validation prevents Suricata from dropping most packets as invalid.

**`rule-files`**

```yaml
- "*.rules" # ET rules from named volume
- /etc/suricata/rules/custom/*.rules # custom rules from ./rules/suricata/
```

---

## `config/suricata/threshold.config` — Alert suppression

```
suppress gen_id 1, sig_id 2200073
...
```

Eight ET SIDs for checksum-anomaly rules are suppressed. Since checksums are always wrong in PCAP replays (NIC offloading), these would flood logs with noise on every replay. `suppress` evaluates the rule but never generates an alert for it. `gen_id 1` = Suricata's built-in detection engine.

---

## `config/filebeat/filebeat.yml`

**Input**

```yaml
- type: log
  paths:
    - /var/log/suricata/eve.json
  fields:
    source_type: suricata
    module: suricata # required by suricata.common ingest chain
  fields_under_root: true
  tags: ["suricata"]
```

**Processors**

`drop_fields` removes Filebeat bookkeeping fields (`agent.hostname`, `host`, `input`, `log`, `ecs`) to keep indexed docs focused on Suricata event content.

**Output**

```yaml
hosts: ["elasticsearch:9200"]
index: "suricata-%{+yyyy.MM.dd}"
pipeline: "suricata.common"
```

Protocol parsing happens server-side in ES ingest (SO pipelines), not in Filebeat.

`setup.ilm.enabled: false` and `setup.template.enabled: false` — automatic ILM/template setup is disabled so the lab explicitly controls mappings through `load-so-templates.sh` and startup index templates.

---

## SO ingest loaders

### `scripts/loaders/load-so-templates.sh`

Pulls curated ECS component templates from the Security Onion 2.4 GitHub repo and creates index template `suricata-so-ecs` for `suricata-*`. That template sets:

- `index.mapping.ignore_malformed: true` — prevents field-type mismatches from dropping documents
- `index.mapping.total_fields.limit: 5000` — Suricata events have many fields; the default 1000 is too low

### `scripts/loaders/load-so-pipelines.sh`

Loads SO ingest pipelines: `suricata.*`, `common.nids`, `dns.tld`, `http.status`, and dynamic `common`. Several compatibility patches are applied:

- `suricata.common` — tolerates missing protocol pipelines (`ignore_missing_pipeline`, `ignore_failure`) so unsupported event families don't drop whole documents
- `suricata.alert` — runs protocol enrichment pipeline `suricata.{{message2.app_proto}}` when available, then reasserts `event.dataset: suricata.alert` so sub-pipelines can't clobber it
- `common` — all `pipeline` processor calls get `ignore_missing_pipeline` and `ignore_failure` to tolerate absent sub-pipelines (`ecs`, `global@custom`) not present in this minimal deployment
- Dynamic `common` is pulled from `ingest-dynamic/common` and Jinja template wrapper lines are stripped before PUT

---

## Kibana data views — creation and deduplication

### Where views are created

| Script                            | Views created                                                    |
| --------------------------------- | ---------------------------------------------------------------- |
| `stack start`                     | `*` (All Logs), `suricata-*`, `elastalert2_alerts`, `soc-alerts` |
| `capture upload`                  | `logs-<basename>-*` per uploaded file                            |
| `capture replay` / `capture live` | None — existing views cover all Suricata data                    |

### `ensure_kibana_data_view` (in `scripts/lib/common.sh`)

All data view creation goes through a shared function:

```bash
ensure_kibana_data_view() {
  local title="$1" time_field="${2:-@timestamp}" name="${3:-$1}"
  local kb="http://localhost:5601"
  curl -sf "$kb/api/status" -o /dev/null 2>/dev/null || return 0   # silent if Kibana not up
  local exists
  exists=$(curl -s "$kb/api/data_views" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    dvs = json.load(sys.stdin)
    print('yes' if any(d.get('title') == sys.argv[1] for d in dvs.get('data_view', [])) else 'no')
except Exception:
    print('no')
" "$title" 2>/dev/null || echo "no")
  [[ "$exists" == "yes" ]] && return 0   # already exists — skip
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({'data_view':{'title':sys.argv[1],'timeFieldName':sys.argv[2],'name':sys.argv[3]}}))
" "$title" "$time_field" "$name")
  curl -s -o /dev/null \
    -X POST "$kb/api/data_views/data_view" \
    -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    -d "$payload"
}
```

Key properties:

- **Silent on Kibana being down** — returns 0 immediately if `/api/status` fails. Safe to call at any point in the stack lifecycle.
- **Checks before creating** — fetches all existing data views and compares by `title` field. No duplicates across `stack start` calls.
- **Python for JSON** — payload is built with `json.dumps` rather than shell string interpolation. Handles patterns with special characters (`*`, `-`) safely.
- **Separated python call** — payload is stored in a variable before being passed to `curl`, avoiding the bash double-quote nesting bug where `"$(python3 -c "...")"` inside `-d "..."` misparsed the inner quotes.

`upload-logs.sh` has its own copy of the same pattern (`ensure_data_view`) since it does not source `lib/common.sh`.

---

## `scripts/commands/stack.sh`

### `cmd_start` orchestration

1. Checks Docker is running
2. Creates bind-mount directories (`docker-logs/suricata/`, `pcap/`, `rules/suricata/`, `rules/sigma/`)
3. `docker compose up -d` — Compose handles `depends_on` ordering
4. Waits for Elasticsearch health (`/_cluster/health`)
5. Applies single-node index template (`number_of_replicas: 0` for all `suricata-*`, `elastalert2_alerts`, `logs-*`)
6. Applies `soc-alerts` alias template and attaches `elastalert2_alerts` if index exists
7. Waits for Suricata rules, refreshes ET rules via `suricata-update`
8. Loads SO ECS component templates and ingest pipelines
9. Waits for Kibana (`/api/status` = `available`), creates the 4 core data views
10. Starts the rules watcher

### `cmd_stop` / `cmd_reset`

- `stop`: `docker compose down` — containers stop, volumes survive
- `reset`: `docker compose down -v` after confirmation — wipes all volumes. Rules re-download on next start.

---

## `scripts/commands/capture-replay.sh` — PCAP replay

### Reset phase (without `--keep`)

```
section "Resetting Replay State"
  info "Deleting suricata indices"
  curl DELETE /suricata-*

  info "Clearing ElastAlert2 alert indices"
  _delete_by_query elastalert2_alerts
  _delete_by_query elastalert2_alerts_status   # resets scan window
  _delete_by_query elastalert2_alerts_silence  # clears suppression

  info "Stopping ElastAlert2"
  docker stop elastalert2                      # required: process keeps endtime in memory

  info "Clearing Suricata logs"
  docker exec suricata sh -c ': > eve.json; : > suricata.log'

  ok "State reset complete"
```

Why `_delete_by_query` instead of `DELETE /index`? Deleting the index itself would destroy ElastAlert2's field mappings, causing sort-by-`alert_time` queries to fail. The documents are cleared but the index (and its mapping) stays.

Why stop ElastAlert2? The running process keeps its scan `endtime` in memory. Clearing `elastalert2_alerts_status` in ES has no effect on a live process. The container must restart so it re-reads the now-empty status index and starts from scratch.

### Replay phase

```bash
docker exec suricata suricata \
  -c /etc/suricata/suricata.yaml \
  -r /pcap/$PCAP_REL \
  --pidfile /var/run/suricata-replay.pid \
  -l /var/log/suricata \
  -k none                 # disable checksum validation (belt+suspenders)
```

This runs Suricata **synchronously** inside the already-running container. The `docker exec` call blocks until Suricata finishes processing all packets and writes `eve.json`. The next line only runs after all events are on disk.

### `--now` flag

A Python script reads the completed `eve.json`, finds the earliest event timestamp, and shifts all event timestamps forward so the earliest lands at the current time. Relative timing between events is preserved. Useful when Kibana's default "last 15 minutes" view would miss old-timestamped events.

### Restart phase

```bash
ensure_soc_alerts_alias        # re-applies alias+template to any new indices
docker start elastalert2       # re-reads empty status → 180-day lookback on first cycle
```

Filebeat is not restarted between reset and replay — it keeps tailing `eve.json`. When Suricata creates a new `eve.json` (new inode after the truncation), Filebeat detects the inode change and starts shipping from byte 0.

### Post-replay index status

Polls up to 60 seconds for documents to appear in `suricata-*` and `soc-alerts`. This covers the Filebeat shipping delay. Prints counts when documents arrive, or a warning if nothing appears after the timeout.

---

## `scripts/commands/capture-live.sh` — Live capture

### How it works

```
dumpcap ring buffer -> pcap/live/capture_*.pcapng
                    -> replay loop processes each completed chunk
                    -> docker exec suricata suricata -r /pcap/live/<chunk>
                    -> eve.json updated
                    -> Filebeat ships to ES
```

`dumpcap` runs with `-b duration:<N>` (rotate every N seconds) and `-b files:50` (ring buffer of 50 files max). The replay loop always skips the most recently modified file (the one `dumpcap` is currently writing to) and processes all older completed chunks.

Why chunks instead of direct interface sniffing in-container:

- keeps the Suricata container model consistent across Linux/WSL/macOS
- avoids host NIC coupling inside Docker runtime
- chunk artifacts are inspectable for troubleshooting

Visibility delay is bounded by the rotation interval + ingest/query lag. With 10 s rotation, expect near-real-time but not packet-by-packet immediacy.

### Session reset (without `--keep`)

```
section "Resetting session data"
  info "Deleting suricata indices"
  curl DELETE /suricata-*

  info "Clearing ElastAlert2 alert indices"
  _delete_by_query elastalert2_alerts
  _delete_by_query elastalert2_alerts_status
  _delete_by_query elastalert2_alerts_silence

  info "Restarting ElastAlert2"
  docker restart elastalert2      # clears in-memory scan window

  info "Clearing Suricata logs"
  docker exec suricata sh -c ': > eve.json; ...'

  ok "Session reset complete"
```

This mirrors the replay reset: Sigma/ElastAlert2 alert data and the ElastAlert2 scan window are cleared so each live session starts fresh.

### Alert alias setup

`ensure_alert_aliases` (which applies the `soc-alerts` index template and alias) is called **once at startup**, before the capture loop begins. It is not called per-chunk — doing so would add a multi-step curl+retry cycle for every replayed packet file, which is wasteful and introduces latency.

### Queue and played tracking

- `.queue` file: names of chunks enqueued for replay (FIFO, one per line)
- `.played` file: names of chunks already replayed (skip-list)
- `enqueue_pcap`: adds a chunk name to the queue if not already queued or played
- `dequeue_head`: removes the first line (shifts the queue)
- `process_queue_once`: processes one chunk; on success writes the name to `.played` and dequeues

The queue enables retry: if a chunk replay fails, it stays at the head of the queue and is retried after an exponential backoff (1→2→4→8→10 s cap).

The TUI reads the `.played` file and counts `capture_*.pcapng` files to show the live capture status panel (`ChunksTotal`, `ChunksPlayed`, `LastChunkAge`).

### Cleanup on SIGINT/SIGTERM

```bash
trap cleanup SIGINT SIGTERM
cleanup() {
  kill $CAPTURE_PID
  # if CURRENT_PCAP not yet played, enqueue and process it
  process_queue_once || true
  ok "Capture stopped"
}
```

The last in-progress chunk is enqueued and replayed on exit so no captured data is lost.

---

## `scripts/tools/upload-logs.sh` — Generic log ingest

### Priority and decision flow

```
--type given?
  YES → resolve pipeline (ES lookup → local YAML search)
        pipeline resolved? → use it (bulk_ingest_raw + pipeline)
        pipeline failed?  → warn user
                            format = json/cef? → ask_yn to use direct ingest
                            format = text?     → die (no automatic fallback)

--build-pipeline given?
  format = json/cef → direct ingest (AI not needed)
  format = text     → generate pipeline with Ollama → load → bulk_ingest_raw

neither flag?
  format = json → direct ingest
  format = cef  → convert to JSON → direct ingest
  format = text → die (must specify --type or --build-pipeline)
```

The `--type` flag always takes priority over format detection. If the user explicitly requests a pipeline for a JSON file, the pipeline is tried — maybe they want field transformations the direct ingest path wouldn't apply.

### `ask_yn`

```bash
ask_yn() {
    local prompt="$1"
    if [ -t 0 ]; then
        printf '[?] %s [y/N] ' "$prompt" >&2
        local ans
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]]
    else
        return 1   # non-interactive (TUI, scripts): no fallback
    fi
}
```

`[ -t 0 ]` checks whether stdin is a terminal. When called from the TUI (where the script runs with stdin not a tty), the prompt is skipped and the function returns failure — no hanging on input.

### Format detection

```bash
detect_format() {
    first_line=$(grep -v '^[[:space:]]*$' "$file" | head -1)
    if echo "$first_line" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null
        then echo "json"; return
    if grep -m5 ... | python3 -c "...CEF regex..." 2>/dev/null
        then echo "cef"; return
    echo "other"
}
```

Detection is based on the first non-empty line only. `json` → parse-able as JSON; `cef` → matches `CEF:[0-9]+|`; everything else is `other`.

### Pipeline resolution (`resolve_explicit_pipeline`)

1. Check if the name already exists as an ES ingest pipeline (`GET /_ingest/pipeline/<name>` → 200)
2. If not, search local folders: `pipelines/elasticsearch/`, `pipelines/custom/`, `pipelines/generated/`
3. If a local YAML is found, load it via `PUT /_ingest/pipeline/<name>`
4. If not found anywhere, print error + fuzzy hints (difflib) and return 1 (does not `exit`)

Returning 1 instead of exiting lets the caller decide whether to fall back or abort. Batch mode hard-fails; single-file interactive mode offers the `ask_yn` fallback.

### Direct ingest (`_ingest_direct`)

```bash
_ingest_direct() {
    case "$format" in
        json) bulk_ingest_json "$work_file" "$index" ;;
        cef)  cef_json=$(convert_cef "$work_file")
              bulk_ingest_json "$cef_json" "$index"
              rm -f "$cef_json" ;;
    esac
}
```

JSON lines are sent as-is. CEF is first converted to JSON using a Python parser that maps CEF header fields and extension key=value pairs to a flat JSON document.

### Bulk ingest

```bash
bulk_ingest_json() {  # for pre-parsed JSON lines
    POST /_bulk?pipeline=<name>
    body: { "create": { "_index": "<index>" } }
          { ...json line... }
          ...
}

bulk_ingest_raw() {  # for plain text lines
    POST /_bulk?pipeline=<name>
    body: { "create": { "_index": "<index>" } }
          { "message": "<escaped line>", "@timestamp": "<now>" }
          ...
}
```

Both send batches of `BULK_SIZE` (500) documents per request. ES ingest processors run server-side on each document before indexing.

### LLM pipeline generation (`--build-pipeline`)

1. `choose_ollama_model_7b` — polls `GET /api/tags` and picks the highest-priority available model from: `qwen2.5-coder:7b`, `qwen2.5:7b`, `mistral:7b`, `llama3.1:8b`, `qwen3:8b`
2. `generate_pipeline_ai` — samples 20 lines from the log file, sends to `scripts/tools/pipeline_generator.py`
3. `pipeline_generator.py` prompts the LLM to produce an ES ingest pipeline YAML, then validates it via `POST /_ingest/pipeline/_simulate` (unless `--llm-ram-mode quit-docker`)
4. Generated YAML is saved to `pipelines/generated/<name>.yml` and loaded into ES

`--llm-ram-mode quit-docker`: stops Docker before LLM generation (frees RAM for the model), then restores Docker and waits for lab recovery before ingesting. Useful on RAM-constrained machines.

### Quality reporting

After ingest, `report_ingest_quality` checks:

- `error.message:*` count — ingest processor errors
- `parse_error:*` count — explicit parser failures
- Average extracted field count per document (excluding baseline fields like `message`, `@timestamp`, `event`)

Low field counts or high error rates are warned. Skipped in `--keep` mode since the index may contain unrelated historical documents.

### Batch mode

With `--batch --folder <dir>`:

- Forces `--keep` semantics across all files (appends rather than wipes on each)
- With `--type`: pipeline resolved once, reused for all files; batch hard-fails if pipeline can't load
- With `--build-pipeline`: first text file generates the pipeline; remaining files reuse it
- Mixed file extensions in the folder produce a warning

---

## Rules subsystem

### `soc-lab rules compile`

Runs two checks and writes artifacts:

1. Suricata compile test: `docker exec suricata suricata -T -c /etc/suricata/suricata.yaml`
2. Sigma conversion: `sigma convert -t elastalert --without-pipeline` for each `rules/sigma/*.yml`

Artifacts:

- `docker-logs/rules/status.json` — machine-readable health (read by TUI rules status panel)
- `docker-logs/rules/suricata-compile.log`
- `docker-logs/rules/sigma-compile.log`

Rule counts in `status.json`:

- ET count: `sid:` occurrences across `/var/lib/suricata/rules/*.rules`
- custom count: `sid:` occurrences across `/etc/suricata/rules/custom/*.rules`

No ET rule download happens here; no container restart happens here. Non-zero exit if either check fails.

### `soc-lab rules watch`

```
rules/suricata/*.rules or rules/sigma/*.yml changes
          │
          ▼
   watch loop (every 2 s)
          │
          ├─ hash unchanged ─────────────► sleep 2 s
          │
          └─ hash changed / status missing
                     │
                     ▼
            soc-lab rules compile
                     │
                     ├─ docker-logs/rules/status.json
                     ├─ suricata-compile.log
                     └─ sigma-compile.log
```

Mechanism: hashes `(path, mtime)` sets for both watched folders. If the hash changes (or `status.json` is missing), triggers one compile run. Edge-triggered — rapid edits coalesce into a single compile.

PID file: `.soc-lab/rules-watcher.pid` (repository-local). Watcher start/stop is invoked by `stack start` / `stack stop` as managed internals.

---

## TUI — Bubble Tea terminal UI

### Architecture

The TUI uses [Bubble Tea](https://github.com/charmbracelet/bubbletea), a Go framework based on the Elm architecture:

```
Init() → initial Cmds (background fetches, tick timer)
Update(msg) → receives messages (keyboard, window size, async results) → returns new model + Cmds
View() → renders the full terminal frame from model state
```

All state lives in the `model` struct. `Update` is the only place state changes. `View` is pure — it reads the model and returns a string, called by Bubble Tea every time the model changes.

### Model state

```go
type model struct {
    input         textinput.Model   // text input field
    spinner       spinner.Model     // animated spinner (MiniDot style)
    services      []serviceStatus   // Docker container states (from docker ps)
    es            esStats           // ES event/alert counts + cluster health
    rules         rulesStatus       // suricata + sigma rule health from status.json
    capture       captureStatus     // live capture: active, interface, chunk counts
    output        string            // accumulated command output
    viewport      viewport.Model    // scrollable output pane
    history       []string          // command history
    histPos       int               // history navigation cursor (-1 = not navigating)
    completions   []string          // current autocomplete candidates
    completionIdx int               // selected completion index
    running       bool              // command in progress
    focusMode     bool              // hide panels, maximise output
    confirming    bool              // waiting for y/n on destructive command
    lastCmd       string            // last executed command
    lastExitCode  int               // exit code of last command
    lastDuration  time.Duration     // wall time of last command
    followOutput  bool              // auto-scroll to bottom on new output
    ...
}
```

### Async commands

All I/O runs off the main goroutine via Bubble Tea `Cmd` functions that return messages. The main patterns:

**Status polling** — a tick fires every 5 seconds and dispatches four parallel fetches:

```
tickMsg → fetchStatusCmd()        → statusMsg (docker ps)
       → fetchESStatsCmd()       → esStatsMsg (ES count queries)
       → fetchRulesStatusCmd()   → rulesStatusMsg (reads status.json)
       → fetchCaptureStatusCmd() → captureStatusMsg (pgrep dumpcap + file globs)
```

**Command streaming** — when the user runs a command:

```
runSocLabCmd() → launches bash subprocess → streams stdout/stderr
              → sends cmdStreamChunkMsg for each line
              → sends cmdOutMsg when the process exits
```

Streaming uses a Go channel (`chan tea.Msg`) fed by a goroutine reading from the process pipe. The `waitForStreamMsg` command waits for the next value from the channel and returns it as a `streamEnvelopeMsg`. This keeps the Bubble Tea event loop single-threaded while streaming output asynchronously.

**Interrupt** — `ctrl+c` during a running command sends `SIGINT` to the process group (`syscall.Kill(-pid, syscall.SIGINT)`), which signals the entire subprocess tree.

### Layout

```
┌─────────────────────────────────────────────────────────────┐
│  ASCII banner          │  Services panel                    │
│  (SOC LAB)             │  Rules Status panel                │
│  Helper line           │  Capture panel                     │
├─────────────────────────────────────────────────────────────┤
│  ─────── rule line ───────────────────────────────────────  │
│  STATE idle  CMD -  ELAPSED -  EXIT 0         (activity bar)│
│ ╭─────────────────────────────────────────────────────────╮ │
│ │ $ <last command>                                        │ │
│ │                                                         │ │
│ │  <scrollable output viewport>                           │ │
│ │                                                         │ │
│ ╰─────────────────────────────────────────────────────────╯ │
│ ╭─────────────────────────────────────────────────────────╮ │
│ │ soc-lab> <input>                                        │ │
│ ╰─────────────────────────────────────────────────────────╯ │
└─────────────────────────────────────────────────────────────┘
```

**Viewport height calculation** — the output viewport must exactly fill the remaining space. `View()` computes:

```
overhead = topH + 1 (rule) + 1 (activity) + inputH + 4 (outputBlock borders+header)
vpH      = terminalHeight - overhead
```

`outputBlock` height = `vpH` (viewport content) + 2 (cmdHeader line + blank line) + 2 (rounded border) = `vpH + 4`.

`estimateVpH()` in `view_helpers.go` approximates this same calculation for use inside `Update()` (where the actual rendered heights aren't known yet) so that `viewport.SetContent()` + `GotoBottom()` use a realistic height rather than the initial `20`.

**Panel stability** — the services panel pads to a minimum of 5 rows. Without this, when the stack is stopped and the panel shows only "no data", the panel height drops and shifts everything above the output box.

**Focus mode** — `f` toggles `m.focusMode`, which sets `topH = 0`. The panels are excluded from `View()`'s `sections` slice and the viewport gets the full terminal height minus the input and activity bar.

### Completion overlay

Completions are painted **over** the last N lines of the viewport rather than inserted as a separate layout section. This means the viewport height — and therefore the entire layout — doesn't change when completions appear or disappear.

```go
rawVP := m.styleOutput(m.viewport.View())
vpLines := strings.Split(rawVP, "\n")
if len(completionOverlay) > 0 {
    n := len(completionOverlay)
    start := len(vpLines) - n
    for i, cl := range completionOverlay {
        if start+i < len(vpLines) {
            vpLines[start+i] = cl
        }
    }
}
```

Each overlay row has a `background-colored` style (dark grey `235`/`237`) so it visually floats over the output. The separator line (`─` repeated) and selection indicator (`❯`) match the rest of the TUI's color scheme.

### Activity bar

```
STATE ● running  CMD stack start  ELAPSED 12s  EXIT 0
```

The spinner (`MiniDot`) only ticks when `m.running == true`. The `spinner.TickMsg` handler returns `nil` when not running, which stops the animation goroutine from generating spurious redraws. The spinner is started alongside each command via `tea.Batch(runSocLabCmd(...), m.spinner.Tick)`.

### Live panels

**Services panel** — `fetchStatusCmd` runs `docker ps --format json`, parses container `Name`, `State`, and `Health` fields. Styled: green for `running`, red for `exited`/`dead`, yellow for non-healthy health states.

**Rules Status panel** — `fetchRulesStatusCmd` reads `docker-logs/rules/status.json`. Shows suricata/sigma status, rule counts, and any error log snippet.

**Capture panel** — `fetchCaptureStatusCmd`:

- `pgrep -x dumpcap` → determines if live capture is active
- `ps -p <pid> -o args` → extracts the interface name from dumpcap command line
- `glob pcap/live/capture_*.pcapng` → total chunk count
- reads `pcap/live/.played` → played chunk count
- `stat` on the most recent chunk → last chunk age (displayed as `Xs ago` / `Xm ago` / `Xh ago`)

The panel always renders exactly 4 content rows regardless of state (active vs idle), so the overall layout height stays stable.

---

## Data flow summary

### PCAP replay

```
./soc-lab capture replay pcap/<file>.pcap
  │
  ├─ DELETE /suricata-*                         Elasticsearch: wipe old Suricata indices
  ├─ _delete_by_query elastalert2_alerts*        ElastAlert2 writeback cleared
  ├─ docker stop elastalert2                     stops in-memory scan window
  ├─ truncate eve.json                           log file cleared
  │
  ├─ docker exec suricata suricata -r /pcap/<file>
  │     │
  │     │  Suricata reads each packet:
  │     │    1. Reassembles TCP streams
  │     │    2. Runs protocol decoders (DNS, HTTP, TLS, SMB, …)
  │     │    3. Evaluates every loaded rule
  │     │    4. Writes alert and protocol metadata records to eve.json
  │     │
  │     └─ exits when last packet processed → eve.json is complete
  │
  │  (Filebeat tails eve.json continuously)
  │     │
  │     │  1. Detects new inode → starts from byte 0
  │     │  2. Reads each JSON line
  │     │  3. POST /_bulk?pipeline=suricata.common → elasticsearch:9200
  │     │  4. ES ingest chain: suricata.common → sub-pipeline → ECS document
  │     │  5. Indexed in suricata-YYYY.MM.DD
  │
  ├─ docker start elastalert2
  │     │
  │     │  elastalert-start.sh:
  │     │    1. sigma convert: sigma rules → ElastAlert2 YAML
  │     │    2. elastalert-create-index: pre-creates writeback indices
  │     │    3. retry loop: re-attaches elastalert2_alerts to soc-alerts
  │     │    4. background @timestamp patch loop starts
  │     │    5. ElastAlert2 starts → empty status → starttime = now-180d
  │     │
  │     │  ElastAlert2 first cycle (~5 s after start):
  │     │    - queries suricata-* for each rule's filter conditions
  │     │    - writes matches to elastalert2_alerts
  │     │    - background loop patches @timestamp → event time
  │     │    - subsequent cycles scan only new events
  │
  └─ poll /suricata-*/_count until docs appear → print summary
```

### Live capture

```
./soc-lab capture live [iface] [rotation]
  │
  ├─ session reset (without --keep):
  │    DELETE /suricata-*
  │    _delete_by_query elastalert2_alerts*
  │    docker restart elastalert2
  │    truncate eve.json
  │
  ├─ ensure_alert_aliases (once, before loop)
  │
  ├─ dumpcap -i <iface> -b duration:<N> -b files:50 -w pcap/live/capture.pcapng &
  │    (writes: pcap/live/capture_00001.pcapng, capture_00002.pcapng, ...)
  │
  └─ replay loop (while dumpcap is running):
       for each completed chunk (all except current active file):
         enqueue_pcap <chunk>
       process_queue_once:
         docker exec suricata suricata -r /pcap/live/<chunk>
         mark chunk as played (.played file)
       retry with exponential backoff on failure
       sleep 2 s
```

### Log upload

```
./soc-lab capture upload <file> --type <pipeline>
  │
  ├─ preprocess: decompress (.gz/.zip) or convert (.evtx) if needed
  ├─ detect_format: json / cef / other
  │
  ├─ TYPE_OVERRIDE set?
  │    YES → resolve_explicit_pipeline (ES lookup → local YAML)
  │          ok?  → bulk_ingest_raw + pipeline
  │          fail → warn; if json/cef: ask_yn → _ingest_direct
  │                        if text:   die
  │
  ├─ USE_AI set?
  │    json/cef → _ingest_direct
  │    other   → generate_pipeline_ai → load → bulk_ingest_raw + pipeline
  │
  └─ neither?
       json/cef → _ingest_direct
       other   → die (must specify mode)
  │
  ├─ ensure_data_view logs-<base>-* (create Kibana view if missing)
  └─ report_ingest_quality (warn on errors or low field extraction)
```

### Component communication map

```
  HOST MACHINE
  ┌───────────────────────────────────────────────────────────────────┐
  │  browser                          curl / scripts / TUI            │
  │     │                                    │                        │
  │     │ HTTP :5601                         │ HTTP :9200             │
  └─────┼────────────────────────────────────┼────────────────────────┘
        │  port forwarding                   │  port forwarding
  ──────┼────────────────────────────────────┼─────────────────────────
        │  DOCKER INTERNAL NETWORK           │
  ──────┼────────────────────────────────────┼─────────────────────────
        │                                    │
        ▼                                    ▼
  ┌─────────────────┐                  ┌──────────────────────────────┐
  │     Kibana      │── POST /_search ►│        Elasticsearch         │
  │  query builder  │◄─ JSON results ──│                              │
  │  render layer   │                  │  suricata-YYYY.MM.DD         │
  └─────────────────┘                  │  elastalert2_alerts          │
                                       │                              │
                                       │  soc-alerts alias:           │
                                       │    suricata-* (alert filter) │
                                       │    + elastalert2_alerts      │
                                       └──────────┬──────────┬────────┘
                                                  ▲          ▲
                                       POST /_bulk│          │POST /_search
                                                  │          │POST /_update_by_query
                             ┌────────────────────┘          └─────────────────────┐
                             │                                                     │
                 ┌───────────┴──────────┐                   ┌──────────────────────┴───┐
                 │       Filebeat       │                   │       ElastAlert2        │
                 │                      │                   │                          │
                 │  scan every 1 s      │                   │  queries suricata-*      │
                 │  tails eve.json      │                   │    every 5 s             │
                 │  ships to suricata-* │                   │  writes elastalert2_*    │
                 └───────────┬──────────┘                   │  patches @timestamp      │
                             │  inode + offset              │    every 2 s             │
                             │  tracked in registry         └──────────────────────────┘
                 ┌───────────▼──────────────────────────────────────────────────────┐
                 │               docker-logs/suricata/eve.json                      │
                 │           bind mount — same file on host and containers          │
                 └───────────────────────────▲──────────────────────────────────────┘
                                             │ writes (one JSON object per line)
                 ┌───────────────────────────┴──────────────────────────────────────┐
                 │                        Suricata                                  │
                 │  on-demand: docker exec suricata suricata -r /pcap/<file>        │
                 │  reads PCAP → evaluates rules → writes eve.json → exits          │
                 └──────────────────────────────────────────────────────────────────┘

  Notes
  · Kibana, Filebeat, and ElastAlert2 all initiate HTTP requests TO Elasticsearch.
    ES never pushes — it only responds.
  · Filebeat and ElastAlert2 are independent. Filebeat ships raw events; ElastAlert2
    queries them. They do not communicate with each other.
  · soc-alerts is an ES alias, not a container. Kibana queries it like any index;
    ES fans out to suricata-* and elastalert2_alerts transparently.
  · Suricata has internet access (Docker NATs out) — used by suricata-update on first
    run and ET refresh during stack start. It does not talk to other containers.
  · Your browser and scripts reach ES/Kibana through port forwarding; containers
    never route through the host to reach each other.
```
