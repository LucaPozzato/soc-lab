# SOC Lab — How Everything Works

---

## The stack: what each piece actually is

Before diving into the config files, it helps to understand what each component does at a fundamental level and how they talk to each other.

### Elasticsearch

Elasticsearch is a search and analytics database built on top of Apache Lucene. It stores data as JSON documents and exposes a REST API over HTTP on port 9200. Everything — storing data, querying it, checking health, deleting indices — is done via HTTP calls.

Documents are organized into **indices** (like database tables, but schema-flexible). This lab uses daily indices named `suricata-2026.04.19`. Each document in an index is one event from eve.json: one alert, one DNS query, one TLS handshake, etc.

When Filebeat ships a log line, it does a `POST /suricata-2026.04.19/_doc` with the JSON body. When Kibana wants to show you data, it does a `POST /suricata-*/_search` with a query body. Everything is just HTTP JSON.

Internally, ES inverts the document fields into a **search index** — for every term in every field, it builds a list of which documents contain that term. That's what makes queries like "show me all alerts where `alert.signature` contains `ET MALWARE`" fast even across millions of documents.

**Why `yellow` status?** ES is designed to replicate shards across multiple nodes for redundancy. On a single node, replica shards have nowhere to go, so they stay `UNASSIGNED`. The cluster is fully functional — all data is there — but ES reports `yellow` because the replication target isn't met. `green` would require at least 2 nodes.

### Kibana

Kibana is a web UI that sits in front of Elasticsearch. It has no database of its own — every piece of data you see in Kibana was fetched from ES at request time.

When you open Kibana's Discover view and set a time range, Kibana translates your filters and time range into an ES query, sends it as a `POST /_search` HTTP request to ES on port 9200, and renders the results. When you create a visualization or dashboard, Kibana stores the configuration (as a "saved object") inside ES itself — in a special `.kibana` index. So Kibana persists nothing locally; it's purely a query-and-render layer.

A **data view** (what `docker.sh start` creates via the Kibana API) tells Kibana "there is an index pattern called `suricata-*`, and `@timestamp` is the time field." Without this, Kibana doesn't know the index exists and won't show it in Discover. The `docker.sh start` script creates it automatically by POSTing to Kibana's own REST API (`/api/data_views/data_view`), which in turn saves it as a document in ES's `.kibana` index. It creates three data views: `suricata-*` (raw events), `elastalert2_alerts` (fired alerts), and `soc-alerts` (unified alerts alias).

Kibana communicates with ES at `http://elasticsearch:9200` — the Docker internal hostname. Your browser communicates with Kibana at `http://localhost:5601`. Kibana is the middleman; your browser never talks to ES directly.

```
your browser
    ↕ HTTP :5601
  Kibana
    ↕ HTTP :9200 (Docker internal network)
  Elasticsearch
```

### Filebeat

Filebeat is a lightweight log shipper. It tails files on disk and POSTs new lines to a destination — in this case, Elasticsearch. It's essentially a managed `tail -f` with JSON parsing, field manipulation, and HTTP output.

Filebeat keeps a **registry** (stored in the `filebeat_data` volume at `/usr/share/filebeat/data/registry/`) that records, for each file it watches, the inode number and the byte offset it last read up to. On restart, it resumes from that offset rather than re-reading from the beginning or missing lines. This is how it survives container restarts without duplicating or losing events.

When `replay-pcap.sh` deletes `eve.json` and Suricata creates a new one, the new file gets a new inode. Filebeat detects the inode change and treats it as a new file, starting from byte 0 — which is exactly the behavior you want for clean replays.

Filebeat connects to Elasticsearch using the same HTTP API as everything else. Each batch of events becomes a `POST /_bulk` request — ES's bulk ingest endpoint, which accepts multiple documents in a single HTTP call for efficiency.

### ElastAlert2

ElastAlert2 is an alerting engine that runs queries against Elasticsearch on a schedule and fires alerts when results match a rule condition. It's the bridge between raw ES data and actionable alerts.

Every 5 seconds, ElastAlert2 reads its rules folder, queries `suricata-*` for each rule's filter conditions, and writes matching results to `elastalert2_alerts` in ES. Rules can be written natively in ElastAlert2's YAML format, or as **Sigma rules** — a vendor-neutral detection format that `elastalert-start.sh` automatically converts to ElastAlert2 format on container start.

ElastAlert2 maintains its own set of writeback indices in ES:

| Index                        | Purpose                                                                          |
| ---------------------------- | -------------------------------------------------------------------------------- |
| `elastalert2_alerts`         | One document per fired alert, including the matched event in `match_body`        |
| `elastalert2_alerts_status`  | Per-rule scan progress (last processed `endtime`)                                |
| `elastalert2_alerts_silence` | Suppression records — prevents re-firing the same rule within `alert_time_limit` |
| `elastalert2_alerts_error`   | Errors ElastAlert2 encountered while running rules                               |

**Timestamp correction:** ElastAlert2 writes the alert document with `@timestamp` set to the current time (when the alert ran), not the time of the matched event. A background loop in `elastalert-start.sh` patches this every 2 seconds by copying `match_body.@timestamp` → `@timestamp`, so Kibana's timeline shows when the event happened rather than when ElastAlert2 processed it. The loop skips documents where `@timestamp` already equals `match_body.@timestamp` (`ctx.op = "noop"`) to avoid unnecessary ES writes. There is a ~2-second window after an alert fires where the timestamp is still the processing time.

**Scan window:** ElastAlert2 uses the `endtime` in `elastalert2_alerts_status` to track where it last searched up to for each rule. On each run it only scans from that point forward. This means if you do a PCAP replay with old timestamps, just clearing the status documents isn't enough — the running process keeps its scan window in memory. `replay-pcap.sh` handles this by stopping and restarting the container, which forces ElastAlert2 to re-read the status from ES and scan the full 180-day `buffer_time` window on startup. The 180-day window means PCAP replays with event timestamps up to 6 months old will still be detected.

---

## `docker-compose.yml` — The spine of the stack

**Elasticsearch (lines 3–23)**

```yaml
discovery.type=single-node      # don't try to form a cluster — it's just one node
xpack.security.enabled=false    # no TLS, no auth — fine for a local lab
bootstrap.memory_lock=true      # prevents the JVM heap from being swapped to disk (performance)
ES_JAVA_OPTS=-Xms1g -Xmx1g     # fix heap at 1GB — prevents ES from grabbing all RAM
```

The `healthcheck` polls `/_cluster/health` every 15s. Other containers declare `condition: service_healthy` on ES, so they won't start until this passes — that's the startup ordering mechanism.

**Kibana (lines 25–35)**

```yaml
ELASTICSEARCH_HOSTS=http://elasticsearch:9200   # Docker internal DNS — container name resolves
depends_on: elasticsearch: condition: service_healthy   # won't start until ES is healthy
```

Port 5601 is forwarded to your host so you can hit `http://localhost:5601`.

**Suricata (lines 37–51)**

```yaml
entrypoint: ["/suricata-start.sh"]              # overrides the image's default entrypoint
./scripts/suricata-start.sh:/suricata-start.sh  # mounts your script into the container
./config/suricata/suricata.yaml:/etc/suricata/suricata.yaml   # your config replaces the default
./logs/suricata:/var/log/suricata               # eve.json lands on your host filesystem
./pcap:/pcap:ro                                 # your pcap folder is readable inside container
./rules/suricata:/etc/suricata/rules/custom     # custom .rules files auto-loaded
suricata_rules:/var/lib/suricata/rules          # named volume — rules survive restarts
```

**Filebeat (lines 53–64)**

```yaml
user: root                                 # needed to read files written by Suricata
./logs/suricata:/var/log/suricata:ro       # reads the same eve.json Suricata writes
filebeat_data:/usr/share/filebeat/data     # persists read position — survives restarts
command: filebeat -e --strict.perms=false  # -e logs to stderr; --strict.perms=false skips config ownership check
```

**ElastAlert2 (lines 66–80)**

```yaml
user: root                                                    # needed for pip install inside container
./scripts/elastalert-start.sh:/elastalert-start.sh           # entrypoint: converts sigma rules, starts elastalert2
./config/elastalert2/elastalert2.yml:/opt/elastalert2/config.yaml  # run interval, buffer window
./config/elastalert2/rules:/opt/elastalert2/rules-static:ro  # hand-written rules mounted read-only
./rules/sigma:/opt/sigma/rules:ro                            # sigma rules mounted read-only; converted on start
```

The rules mount is read-only (`rules-static:ro`) to prevent the startup script from accidentally deleting host files — an earlier version ran `find -delete` on a writable bind mount and removed the source files. The entrypoint copies rules from `/opt/elastalert2/rules-static` into a container-only writable directory at `/opt/elastalert2/rules` before starting ElastAlert2.

The `depends_on: elasticsearch: condition: service_healthy` ensures ElastAlert2 doesn't start before ES is ready — it would fail trying to connect to the writeback indices.

**Volumes (lines 82–85)**

```yaml
es_data        # Elasticsearch index data — survives docker compose down
filebeat_data  # Filebeat registry (tracks how far it's read in each file)
suricata_rules # Emerging Threats rule files — so they don't re-download every start
```

---

## `scripts/suricata-start.sh` — Suricata container entrypoint

```bash
if ! ls /var/lib/suricata/rules/*.rules 2>/dev/null | grep -q .; then
```

Checks if the named volume already has `.rules` files. If not (first run), downloads them.

```bash
suricata-update \
    --suricata-conf /etc/suricata/suricata.yaml \
    --output /var/lib/suricata/rules \
    --no-merge \                    # keep individual rule files, don't combine into one
    --no-test                       # skip rule validation (faster)
```

This downloads ~43k Emerging Threats community rules. `--no-merge` keeps them as separate files per source, which matters because the next line deletes two specific ones:

```bash
rm -f .../dnp3-events.rules .../modbus-events.rules
```

These cover industrial control protocols (DNP3, Modbus). The `jasonish/suricata` image is compiled without those protocol parsers, so loading these rules would cause Suricata to error on startup.

```bash
exec sleep infinity
```

After rules are ready, the container just idles. **Suricata itself is not running as a daemon here** — it only runs on-demand when `replay-pcap.sh` calls `docker exec suricata suricata ...`. The `exec` replaces the shell process with `sleep`, so PID 1 in the container is `sleep infinity` and Docker keeps it alive.

---

## `scripts/elastalert-start.sh` — ElastAlert2 container entrypoint

```bash
sigma plugin install elasticsearch
```

Installs the ElastAlert2 backend for the `sigma` CLI tool, which is needed to convert Sigma rule files.

```bash
find "$SIGMA_DIR" -name '*.yml' | while read -r f; do
    sigma convert -t elastalert --without-pipeline "$f" > "$out"
    python3 /tmp/patch_rule.py "$out"
done
```

Converts every `.yml` file from `./rules/sigma/` (mounted at `/opt/sigma/rules`) into ElastAlert2 YAML format. The patch script fixes two things sigma's conversion leaves incomplete:

- Sets `index: suricata-*` when the converted rule has no index or uses `*`
- Adds `alert: [debug]` if the `alert` field is missing (required by ElastAlert2)

Previously converted rules are deleted first so that removing a sigma file doesn't leave a stale converted rule behind.

```bash
elastalert-create-index --recreate False
```

Pre-creates ElastAlert2's writeback indices (`elastalert2_alerts`, `elastalert2_alerts_status`, etc.) before starting the main process. Without this, ElastAlert2 can crash with a 404 error on its first run if the indices don't yet exist. `--recreate False` means: create them if missing, leave them alone if they already exist.

As a side effect, `elastalert-create-index` drops all ES aliases. After it runs, a retry loop re-attaches `elastalert2_alerts` to the `soc-alerts` unified alias (5 attempts, 2s sleep between each) so the alias is always live when ElastAlert2 starts writing alerts.

```bash
(while true; do
    sleep 2
    python3 -c "...update_by_query..." &
done) &
```

A background loop that runs every 2 seconds. ElastAlert2 writes alert documents with `@timestamp` set to the processing time (when the alert ran), not the event time. This loop patches every document in `elastalert2_alerts` by copying `match_body.@timestamp` → `@timestamp`. Kibana uses `@timestamp` for its timeline, so without this fix all alerts would appear at "now" regardless of when the underlying event happened.

The script uses `ctx.op = "noop"` when `@timestamp` already equals `match_body.@timestamp`, so already-patched documents are skipped without an ES write. The `_update_by_query` call uses `conflicts=proceed` so a concurrent ElastAlert2 write doesn't cause the whole update to abort.

```bash
exec python -m elastalert.elastalert --config /opt/elastalert2/config.yaml
```

Starts ElastAlert2 as PID 1. `exec` replaces the shell so the process gets signals (SIGTERM on `docker stop`) directly.

---

## `config/elastalert2/elastalert2.yml` — ElastAlert2 config

```yaml
es_host: elasticsearch
es_port: 9200

writeback_index: elastalert2_alerts # prefix for all writeback indices

run_every:
  seconds: 5 # query ES for new matches every 5 seconds

buffer_time:
  days: 180 # on first run (no status), scan back 180 days

rules_folder: /opt/elastalert2/rules

alert_time_limit:
  minutes: 1 # discard queued-but-unsent alerts after 1 minute
```

`run_every: seconds: 5` combined with Filebeat's `scan_frequency: 1s` means sigma alerts typically fire within ~30 seconds of events being indexed — the pipeline is: Suricata writes eve.json → Filebeat picks it up within 1s → ships to ES → ElastAlert2 queries within 5s.

`buffer_time` matters for PCAP replay: events in a replay PCAP often have timestamps from days, weeks, or months ago. With 180 days of lookback, ElastAlert2 finds events from PCAPs captured up to 6 months ago on its first scan after the container starts.

---

## `soc-alerts` — Unified alerts alias

`soc-alerts` is an Elasticsearch alias that combines two alert sources into a single queryable endpoint:

| Source               | Filter applied                                                                |
| -------------------- | ----------------------------------------------------------------------------- |
| `suricata-*`         | Alias filter matches `event.dataset: alert` or `event.dataset: suricata.alert`, plus `tags: alert` fallback |
| `elastalert2_alerts` | none — all ElastAlert2/Sigma fired alerts                                     |

This means a single query to `soc-alerts` returns both Suricata IDS alerts and higher-level Sigma/ElastAlert2 detections without querying two separate indices.

**How it's kept alive across resets:**

- `docker.sh start` creates a Kibana data view called "Alerts" pointing at `soc-alerts`, alongside the existing `suricata-*` and `elastalert2_alerts` views.
- An ES index template `suricata-soc-alerts` auto-applies the alias+filter to every new `suricata-*` index when it's created by Filebeat, so the alias survives volume wipes and fresh index creation.
- `replay-pcap.sh` re-PUTs the template before starting Filebeat, ensuring the template is present even after a full `docker compose down -v`.
- `elastalert-start.sh` re-attaches `elastalert2_alerts` to `soc-alerts` after `elastalert-create-index` runs (which drops all aliases as a side effect).

---

## `upload-logs.sh` — Generic log ingest workflow

`upload-logs.sh` is intentionally separate from the Suricata replay path. It is a generic parser/uploader for arbitrary log files.

### Decision flow

1. **Format detect**
   - JSON line logs → ship directly
   - CEF logs → convert to JSON, then ship directly
   - Other text logs → require explicit mode: `--type` or `--build-pipeline`

2. **Explicit pipeline mode (`--type`)**
   - Accepts a pipeline name in Elasticsearch or a local YAML path
   - Local resolution checks `pipelines/elasticsearch/`, `pipelines/custom/`, and `pipelines/generated/`
   - YAML is loaded into Elasticsearch ingest before indexing

3. **Build mode (`--build-pipeline`)**
   - Requires local bare-metal Ollama at `http://localhost:11434`
   - Uses LLM-generated Grok pipeline with closed-loop retries
   - Output is validated via `_simulate` before use (unless `--llm-ram-mode quit-docker`) and cached in `pipelines/generated/`

### End-to-end details (what the script actually does)

1. **Input normalization and target naming**
   - Derives a base name from the file (for example `custom-kv.log` → `custom-kv`)
   - Builds target index pattern `logs-<base>-*` and daily write index `logs-<base>-YYYY.MM.DD`
   - Unless `--keep` is set, deletes existing `logs-<base>-*` indices first for a clean run

2. **Format detection path**
   - **JSON lines**: sends as-is with bulk ingest helpers
   - **CEF**: converts CEF fields to JSON and ingests directly
   - **Plain text / mixed text**: requires `--type` or `--build-pipeline`

3. **Pipeline load and validation**
   - For `--type`, loads named/local YAML pipeline into Elasticsearch if needed
   - For `--build-pipeline`, generates pipeline using `scripts/pipeline_generator.py`
   - Validates generated parser via `_simulate` before indexing

4. **Timestamp behavior**
   - For text pipelines, `--now` wraps output so:
      - original parsed event time is copied to `event.created`
      - `@timestamp` is replaced with ingest time
    - Without `--now`, event-time `@timestamp` from parsing is preserved

5. **Result reporting**
   - Prints selected pipeline mode (`named`, `generated`, or `none`)
   - Prints final target index and indexed document count
   - Creates/updates Kibana data view for the target pattern when Kibana is reachable

### Who actually ships logs in this path?

For `upload-logs.sh`, **the script itself ships documents directly to Elasticsearch**. Filebeat is not in this path.

- The script builds NDJSON bulk payloads (`{"create":...}` action line + document line).
- It sends them to `POST /_bulk` using `curl`.
- If a pipeline is selected/generated, it adds `?pipeline=<pipeline_name>` to the same bulk request.
- Elasticsearch executes ingest processors server-side before indexing each document.

So the upload path is:

1. local file -> read/normalize by `upload-logs.sh`
2. optional pipeline selection/generation
3. `upload-logs.sh` sends `_bulk` requests directly to ES
4. ES ingest node runs pipeline processors and indexes docs
5. Kibana reads indexed docs from ES

By contrast, in the Suricata replay path, Filebeat tails `eve.json` and ships those logs. That is a separate ingest path.

### Performance and RAM behavior

LLM generation is the expensive path. Use a local 7B-class Ollama model on bare metal for the best balance of quality and latency.

`--llm-ram-mode` controls behavior during generation:

- `none` (default): keep Docker/lab up and validate generated pipeline against Elasticsearch `_simulate`
- `quit-docker`: stop Docker before generation (no ES validation during generation), then start Docker and wait for lab recovery before ingest

### `--type` behavior

- `--type <name>`: use exact pipeline name (Elasticsearch or local pipeline folders)
- `--type <path.yml>`: use explicit local YAML pipeline path

### `--batch` behavior

- `--batch --folder <dir>` processes all files in a directory.
- Batch mode expects same log type per folder; mixed file extensions are flagged with a warning.
- With `--build-pipeline`, first text file is used to generate one pipeline and remaining files reuse it.

### `--keep` / `--now`

- Without `--keep`, the target index pattern is deleted before ingest
- With `--keep`, new docs are appended
- `--now` wraps text pipelines so `@timestamp` is set to ingest time and original parsed time is copied to `event.created`

### Practical limitations (important)

- Even a good pipeline can partially fail on synthetic or heavily customized lines.
- For quality checks after ingest, query:
  - `error.message:*` (ingest processor errors)
  - `parse_error:*` (explicit parser fallback/error tagging)
- If those rates are high, prefer a custom `--type <path.yml>` parser for that log source.

---

## `config/suricata/suricata.yaml` — Suricata config

**`vars` section (lines 3–33)**

```yaml
HOME_NET: "[10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,...]"
EXTERNAL_NET: "!$HOME_NET"
```

`HOME_NET` is the set of IP ranges Suricata treats as "your network." `EXTERNAL_NET` is everything else. Rules use these variables — e.g., `alert tcp $EXTERNAL_NET any -> $HOME_NET 22` = SSH from outside to inside. All the server groups (`HTTP_SERVERS`, `DNS_SERVERS`, etc.) default to `$HOME_NET` because in a flat lab environment, any host could be running any service.

**`outputs` section (lines 37–70)**

```yaml
- eve-log:
    filetype: regular
    filename: eve.json     # writes to /var/log/suricata/eve.json
    append: yes            # each replay run appends — replay-pcap.sh deletes the file first for clean runs
    types:
      - alert              # IDS rule hits
      - flow               # connection metadata (src/dst/bytes/duration)
      - dns                # every DNS query/response
      - http: extended: yes   # HTTP with full headers
      - tls: extended: yes    # TLS with cert details
      - smtp/ssh/ftp/smb/rdp/krb5/...  # protocol-specific metadata
```

Every event type listed here becomes a JSON record in `eve.json`. Filebeat ships all of them to ES, so in Kibana you can query not just alerts but all DNS, HTTP, and TLS traffic.

**`stream` and `pcap-file` (lines 72–76)**

```yaml
stream:
  checksum-validation: no
pcap-file:
  checksum-checks: no
```

Both disable TCP checksum validation. On real network captures, NIC hardware offloading means checksums are filled in by the NIC after capture — the PCAP contains dummy checksums. Without this, Suricata would drop most packets as invalid and miss most traffic.

**`detection` (lines 78–82)**

```yaml
profile: medium # balanced performance vs. depth of inspection
toclient-groups: 3 # how many rule groups to split traffic into (performance tuning)
toserver-groups: 25
```

More groups = faster matching but more memory. `medium` profile is fine for a lab.

**`rule-files` (lines 86–88)**

```yaml
- "*.rules" # loads every .rules file from /var/lib/suricata/rules
- /etc/suricata/rules/custom/*.rules # also loads everything from ./rules/suricata/
```

This is how your custom rules in `./rules/suricata/` are picked up automatically — that path is mounted into the container and listed here.

**`threshold-file` (line 90)**
Points to `threshold.config`, explained below.

---

## `config/suricata/threshold.config` — Alert suppression

```
suppress gen_id 1, sig_id 2200073
suppress gen_id 1, sig_id 2200074
...
```

These 8 SIDs are Emerging Threats rules that fire on bad TCP checksums (`ET SCAN` and similar checksum-anomaly rules). Since checksums are always wrong in PCAP replays (NIC offloading), these would fire on almost every packet and flood your logs with noise. `suppress` tells Suricata to evaluate the rule but never generate an alert for it.

`gen_id 1` = Suricata's built-in detection engine (as opposed to gen_id 2 which is for the preprocessor).

---

## `config/filebeat/filebeat.yml` — Log shipping

Filebeat tails Suricata `eve.json` and sends each line to Elasticsearch through ingest pipeline `suricata.common`.

**Input (lines 1–13)**

```yaml
- type: log
  paths:
    - /var/log/suricata/eve.json
  fields:
    source_type: suricata
    module: suricata
  fields_under_root: true
  tags: ["suricata"]
```

`module: suricata` is required by the SO ingest chain because `suricata.common` builds `event.dataset` from module + event type.

**Processors (lines 14–17)**

`drop_fields` removes Filebeat bookkeeping fields (`agent.hostname`, `host`, `input`, `log`, `ecs`) so indexed docs stay focused on Suricata event content.

**Output (lines 19–23)**

```yaml
hosts: ["elasticsearch:9200"]
index: "suricata-%{+yyyy.MM.dd}"
pipeline: "suricata.common"
```

Protocol parsing happens server-side in ES ingest (SO pipelines), not in Filebeat.

**`setup.ilm.enabled: false` and `setup.template.enabled: false`**

Automatic ILM/template setup is disabled so this lab can explicitly control mappings/templates through `load-so-templates.sh` and startup index templates.

---

## SO ingest loaders (`load-so-pipelines.sh`, `load-so-templates.sh`)

Startup loads Security Onion ingest artifacts directly from the SO 2.4 repository, then applies small compatibility patches.

- `load-so-templates.sh` loads curated ECS component templates and creates index template `suricata-so-ecs` for `suricata-*`
- `suricata-so-ecs` sets `index.mapping.ignore_malformed: true` and `index.mapping.total_fields.limit: 5000` to prevent field-limit drops on rich Suricata events
- `load-so-pipelines.sh` loads `suricata.*`, `common.nids`, `dns.tld`, `http.status`, and dynamic `common`
- Dynamic `common` is pulled from SO `ingest-dynamic/common` and Jinja wrapper lines are stripped before PUT
- `suricata.common` is patched to tolerate missing protocol pipelines (`ignore_missing_pipeline`, `ignore_failure`) so unsupported event families do not drop whole docs
- `suricata.alert` is patched to run protocol enrichment pipeline `suricata.{{message2.app_proto}}` when available and to enforce `event.dataset: suricata.alert`

This preserves SO-native parsing while keeping replay coverage stable when protocol-specific pipelines are missing.

---

## `docker.sh` — Stack management

Three subcommands: `start`, `stop`, `reset`.

- **`stop`** runs `docker compose down` — containers stop, volumes survive.
- **`reset`** runs `docker compose down -v` after a confirmation prompt — wipes all volumes (ES data, rules, Filebeat registry). Rules re-download on next start.
- **`start`** is the full orchestration described below.

### `docker.sh start` — Orchestration script

**Step 1 (lines 20–26):** Checks that `docker` exists and the daemon is running — fails fast with a useful message before trying anything.

**Step 2 (lines 29–33):** Creates `logs/suricata/`, `pcap/`, `rules/suricata/`, `rules/sigma/` on your host machine. These are bind-mounted into containers, so they must exist before `docker compose up`.

**Step 3 (line 39):** `docker compose up -d` — starts all containers in the background. Compose handles the `depends_on` ordering itself.

**Step 4 (lines 43–91):** Health polls:

- **ES:** hits `/_cluster/health` until it gets a JSON response with `"status"` — covers both `green` and `yellow`
- **Suricata rules:** watches `docker logs suricata` for `"waiting for pcap"` — that line is printed by `suricata-start.sh` only after rule download completes
- **Kibana data views:** polls Kibana's `/api/status` until it's `available`, then POSTs to `/api/data_views/data_view` to create three data views: `suricata-*` (raw events), `elastalert2_alerts` (fired alerts), and `soc-alerts` (unified alias — Suricata IDS alerts + ElastAlert2/Sigma alerts combined)
- **Filebeat:** checks logs for `"Connection to backoff.*established"` which is Filebeat's line when it successfully connects to ES

---

## `replay-pcap.sh` — The main workflow

```bash
curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | \
  xargs -I{} curl -s -X DELETE "http://localhost:9200/{}"
```

Lists all existing `suricata-*` indices and deletes them. Gives you a clean slate so old events from a previous replay don't pollute results.

```bash
for idx in elastalert2_alerts elastalert2_alerts_status elastalert2_alerts_silence; do
  curl -s -X POST "http://localhost:9200/${idx}/_delete_by_query" ...
done
```

Clears all ElastAlert2 writeback documents but **keeps the indices**. Deleting the indices themselves would cause ElastAlert2 to lose its field mappings and error on queries that sort by `alert_time`. Three indices must be cleared:

- `elastalert2_alerts` — removes old alert results
- `elastalert2_alerts_status` — resets the scan window so ElastAlert2 rescans from scratch
- `elastalert2_alerts_silence` — clears suppression so the rule can fire again

```bash
docker stop filebeat elastalert2
```

Stops both shippers before touching logs. Stopping ElastAlert2 here is critical: the running process keeps its scan `endtime` in memory, so clearing the status index documents has no effect on a live process. The container must be restarted so it re-reads the (now-empty) status from ES on startup.

```bash
docker exec suricata sh -c 'rm -f /var/log/suricata/eve.json ...'
```

Deletes the log files inside the container (which also deletes them on your host since it's a bind mount). This is why `suricata.yaml` sets `append: yes` — each `docker exec suricata suricata -r ...` appends to the file, so deleting it first keeps each replay clean.

```bash
docker exec suricata suricata \
  -c /etc/suricata/suricata.yaml \
  -r /pcap/$PCAP_NAME \    # -r = read from file (not live interface)
  --pidfile /var/run/suricata-replay.pid \
  -l /var/log/suricata \
  -k none                  # -k none = disable checksum validation (belt+suspenders on top of suricata.yaml)
```

This runs Suricata **synchronously inside the already-running container**. It reads the PCAP, runs every packet through all loaded rules, writes eve.json, then exits. The `exec` call blocks until Suricata finishes — so the next line only runs after all events are written.

**`--now` flag (optional):** When passed, a Python script reads the completed `eve.json`, finds the earliest timestamp, and shifts all event timestamps forward so the earliest event lands at the current time. Relative timing between events is preserved. This is useful when you want Kibana's default "last 15 minutes" view to show the replay events without manually adjusting the time range.

**`--keep` flag (optional):** Skips the cleanup phase and appends new replayed events/alerts to existing data. Without `--keep`, replay runs are clean-slate by default (old Suricata indices are removed and ElastAlert2 writeback docs are cleared before replay).

```bash
docker start filebeat elastalert2
```

Restarts both. Filebeat detects the new `eve.json` inode and ships from byte 0. ElastAlert2 starts fresh, reads the empty status index, and on its first run scans back 180 days (`buffer_time`) — picking up the PCAP events regardless of how old their timestamps are (up to 6 months).

---

## Data flow summary

### PCAP replay

```
./replay-pcap.sh capture.pcap
  │
  ├─ curl DELETE /suricata-*              →  Elasticsearch wipes old Suricata indices
  ├─ _delete_by_query elastalert2_alerts* →  ElastAlert2 writeback cleared
  ├─ docker stop filebeat elastalert2     →  both shippers stopped
  ├─ docker exec suricata rm eve.json     →  log file deleted
  │
  ├─ docker exec suricata suricata -r /pcap/capture.pcap
  │     │
  │     │  Suricata reads each packet from the PCAP:
  │     │    1. Reassembles TCP streams
  │     │    2. Runs protocol decoders (DNS, HTTP, TLS, SMB, ...)
  │     │    3. Evaluates every loaded rule against each packet/stream
  │     │    4. For each match: writes an alert record to eve.json
  │     │    5. For every protocol event (DNS query, HTTP request, etc.):
  │     │       writes a metadata record to eve.json regardless of rule match
  │     │
  │     └─ exits when the last packet is processed
  │          → eve.json is now complete and closed
  │
  ├─ docker start filebeat
  │     │
  │     │  Filebeat starts up:
  │     │    1. Reads registry — sees eve.json has a new inode, starts from byte 0
  │     │    2. Reads each line of eve.json (one JSON object per line)
  │     │    3. Adds fields/tags (including module=suricata)
  │     │    4. drop_fields: strips Filebeat bookkeeping noise
  │     │    5. Batches events into bulk HTTP requests
  │     │    6. POST /_bulk?pipeline=suricata.common → elasticsearch:9200
  │     │         body: { "index": { "_index": "suricata-2026.04.19" } }
  │     │                { ...event document... }
  │     │                ...
  │     │    7. ES ingest pipeline chain parses event_type/app_proto and normalizes ECS fields
  │     │    8. Updates registry with new byte offset after each successful batch
  │     │
  │     └─ continues tailing (waiting for new lines) until stopped
  │
  ├─ docker start elastalert2
  │     │
  │     │  elastalert-start.sh runs:
  │     │    1. sigma convert: converts ./rules/sigma/*.yml → ElastAlert2 YAML
  │     │    2. elastalert-create-index: pre-creates writeback indices
  │     │    3. retry loop: re-attaches elastalert2_alerts to soc-alerts alias
  │     │    4. background loop starts (patches @timestamp every 2s)
  │     │    5. ElastAlert2 starts, reads status index → empty → starttime = now-180d
  │     │
  │     │  ElastAlert2 first cycle (~5 seconds after start):
  │     │    1. Queries suricata-* with each rule's filter
  │     │    2. Finds matching events in the 180-day window
  │     │    3. Writes alert document to elastalert2_alerts:
  │     │         { "@timestamp": <processing time>,   ← patched to event time by loop
  │     │           "alert_time": <processing time>,
  │     │           "match_body": { "@timestamp": <event time>, ...full event... } }
  │     │    4. Writes silence entry (prevents re-firing within alert_time_limit)
  │     │    5. Updates status with new endtime
  │     │
  │     │  Background loop (every 2s):
  │     │    _update_by_query elastalert2_alerts:
  │     │      @timestamp ← match_body.@timestamp  (noop if already equal)
  │     │      (corrects processing time → event time for Kibana timeline)
  │     │
  │     └─ subsequent cycles scan only new events (from last endtime to now)
  │
  └─ Elasticsearch receives all documents:
        Suricata events → suricata-2026.xx.xx indices
        ElastAlert2 alerts → elastalert2_alerts index
```

### Kibana query (what happens when you open Discover)

```
your browser loads http://localhost:5601
  │
  ├─ Kibana serves the React SPA (HTML/JS/CSS)
  │
  └─ you open Discover, select suricata-* data view, set time range
        │
        ├─ Kibana builds an Elasticsearch query:
        │    POST http://elasticsearch:9200/suricata-*/_search
        │    {
        │      "query": {
        │        "bool": {
        │          "filter": [
        │            { "range": { "@timestamp": { "gte": "now-15m", "lte": "now" } } }
        │          ]
        │        }
        │      },
        │      "sort": [{ "@timestamp": "desc" }],
        │      "size": 500
        │    }
        │
        ├─ Elasticsearch searches the inverted index, returns matching documents
        │
        ├─ Kibana receives the JSON response and renders it as rows in Discover
        │
        └─ every filter, search bar query, or visualization you add
           translates to a new or modified _search HTTP call to ES
```

### Component communication map

```
  HOST MACHINE
  ┌──────────────────────────────────────────────────────────────────┐
  │                                                                  │
  │   browser                         curl / scripts                 │
  │      │                                   │                       │
  │      │ HTTP :5601                        │ HTTP :9200            │
  │      │                                   │                       │
  └──────┼───────────────────────────────────┼───────────────────────┘
         │  port forwarding                  │  port forwarding
  ───────┼───────────────────────────────────┼────────────────────────
         │  DOCKER INTERNAL NETWORK          │
  ───────┼───────────────────────────────────┼────────────────────────
         │                                   │
         ▼                                   ▼
  ┌─────────────────┐                   ┌──────────────────────────────┐
  │     Kibana      │ ── POST /_search ►│         Elasticsearch        │
  │                 │ ◄─ JSON results ──│                              │
  │  query builder  │                   │  suricata-* (daily indices)  │
  │  render layer   │                   │  elastalert2_alerts          │
  └─────────────────┘                   │                              │
                                        │  soc-alerts alias:           │
                                        │    suricata-* (event_type:   │
                                        │      alert filter)           │
                                        │    + elastalert2_alerts      │
                                        └──────────┬─────────┬─────────┘
                                                   ▲         ▲
                                        POST /_bulk│         │POST /_search
                                                   │         │POST /_update_by_query
                                                   │         │
                              ┌────────────────────┘         └──────────────────────┐
                              │                                                     │
                  ┌───────────┴───────────┐                 ┌───────────────────────┴───┐
                  │       Filebeat        │                 │       ElastAlert2         │
                  │                       │                 │                           │
                  │  scan every 1s        │                 │  queries suricata-*       │
                  │  tails eve.json       │                 │    every 5s               │
                  │  parses + remaps      │                 │  writes →                 │
                  │  ships to suricata-*  │                 │    elastalert2_alerts     │
                  └───────────┬───────────┘                 │  patches @timestamp       │
                              │                             │    every 2s (noop if ok)  │
                              │ reads (inode + offset       └───────────────────────────┘
                              │  tracked in registry)
                  ┌───────────▼───────────────────────────────────────────────────────┐
                  │                  ./logs/suricata/eve.json                         │
                  │                                                                   │
                  │              bind mount — same file on host and containers        │
                  └───────────────────────────▲───────────────────────────────────────┘
                                              │ writes (one JSON object per line)
                  ┌───────────────────────────┴───────────────────────────────────────┐
                  │                         Suricata                                  │
                  │                                                                   │
                  │   on-demand via docker exec                                       │
                  │   reads PCAP → evaluates rules → writes eve.json → exits          │
                  └───────────────────────────────────────────────────────────────────┘

  ── Notes ────────────────────────────────────────────────────────────
  · Kibana, Filebeat, ElastAlert2 all initiate HTTP requests TO
    Elasticsearch. ES never pushes to them — it only responds.
  · Filebeat and ElastAlert2 are independent. Filebeat ships raw
    events to suricata-*; ElastAlert2 queries suricata-* separately.
    They do not communicate with each other.
  · soc-alerts is an ES alias, not a container. Kibana queries it like
    any index; ES fans out to the underlying suricata-* and
    elastalert2_alerts indices transparently.
  · Suricata has internet access (Docker NATs out) — used by
    suricata-update on first run. It does not talk to other containers.
  · Your browser and scripts reach ES/Kibana through port forwarding;
    containers never route through the host to talk to each other.
  ─────────────────────────────────────────────────────────────────────
```
