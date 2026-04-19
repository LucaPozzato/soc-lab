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

A **data view** (what `docker.sh start` creates via the Kibana API) tells Kibana "there is an index pattern called `suricata-*`, and `@timestamp` is the time field." Without this, Kibana doesn't know the index exists and won't show it in Discover. The `docker.sh start` script creates it automatically by POSTing to Kibana's own REST API (`/api/data_views/data_view`), which in turn saves it as a document in ES's `.kibana` index.

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
entrypoint: ["/suricata-start.sh"]         # overrides the image's default entrypoint
./scripts/suricata-start.sh:/suricata-start.sh:ro   # mounts your script into the container
./config/suricata/suricata.yaml:/etc/suricata/suricata.yaml   # your config replaces the default
./logs/suricata:/var/log/suricata          # eve.json lands on your host filesystem
./pcap:/pcap:ro                            # your pcap folder is readable inside container
./rules:/etc/suricata/rules/custom         # custom .rules files auto-loaded
suricata_rules:/var/lib/suricata/rules     # named volume — rules survive restarts
```

**Filebeat (lines 53–64)**
```yaml
user: root                                 # needed to read files written by Suricata
./logs/suricata:/var/log/suricata:ro       # reads the same eve.json Suricata writes
filebeat_data:/usr/share/filebeat/data     # persists read position — survives restarts
command: filebeat -e --strict.perms=false  # -e logs to stderr; --strict.perms=false skips config ownership check
```

**Volumes (lines 66–69)**
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
profile: medium               # balanced performance vs. depth of inspection
toclient-groups: 3            # how many rule groups to split traffic into (performance tuning)
toserver-groups: 25
```
More groups = faster matching but more memory. `medium` profile is fine for a lab.

**`rule-files` (lines 86–88)**
```yaml
- "*.rules"                         # loads every .rules file from default-rule-path (/var/lib/suricata/rules)
- /etc/suricata/rules/custom/*.rules  # also loads everything from your ./rules/ directory
```
This is how your custom rules in `./rules/` are picked up automatically — that path is mounted into the container and listed here.

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

**Input (lines 1–12)**
```yaml
- type: log
  paths:
    - /var/log/suricata/eve.json   # the same file Suricata writes
  json.keys_under_root: true       # parse JSON and put fields at top level (not nested under "json")
  json.add_error_key: true         # if JSON parse fails, add a field "error.message" instead of silently dropping
  fields:
    source_type: suricata
  fields_under_root: true          # put source_type at top level, not nested under "fields"
  tags: ["suricata"]
```
Filebeat tails `eve.json` line by line. Each line is a JSON event. `json.keys_under_root` means `alert.signature` becomes a top-level field in ES, not `json.alert.signature`.

**Processors (lines 14–25)**

The `timestamp` processor:
```yaml
field: timestamp           # Suricata's eve.json uses "timestamp" for the event time
target_field: "@timestamp" # ES/Kibana expects "@timestamp" for time-based queries
layouts:                   # Go-style time format strings — two variants for ±timezone offset
  - "2006-01-02T15:04:05.999999-0700"
  - "2006-01-02T15:04:05.999999+0000"
```
Without this, `@timestamp` would be the time Filebeat read the line (now), not the time the packet was seen — making time-based queries in Kibana meaningless for replays.

The `drop_fields` processor removes Filebeat's own metadata (`agent.hostname`, `host`, `input`, `log`, `message`) — these are Filebeat bookkeeping fields, not Suricata data, and they'd just clutter your ES documents.

**Output (lines 28–30)**
```yaml
hosts: ["elasticsearch:9200"]        # Docker internal DNS
index: "suricata-%{+yyyy.MM.dd}"     # creates daily indices: suricata-2026.04.19
```
Daily indices let you delete old data by date and keep queries fast.

**`setup.ilm.enabled: false` and `setup.template.enabled: false` (lines 32–33)**
By default Filebeat tries to set up Index Lifecycle Management policies and index templates in ES. Both are disabled here — you're managing the index manually (`docker.sh start` creates the data view via the Kibana API). This avoids permission errors and keeps the setup simple.

---

## `docker.sh` — Stack management

Three subcommands: `start`, `stop`, `reset`.

- **`stop`** runs `docker compose down` — containers stop, volumes survive.
- **`reset`** runs `docker compose down -v` after a confirmation prompt — wipes all volumes (ES data, rules, Filebeat registry). Rules re-download on next start.
- **`start`** is the full orchestration described below.

### `docker.sh start` — Orchestration script

**Step 1 (lines 20–26):** Checks that `docker` exists and the daemon is running — fails fast with a useful message before trying anything.

**Step 2 (lines 29–33):** Creates `logs/suricata/`, `pcap/`, `rules/` on your host machine. These are bind-mounted into containers, so they must exist before `docker compose up`.

**Step 3 (line 39):** `docker compose up -d` — starts all 4 containers in the background. Compose handles the `depends_on` ordering itself.

**Step 4 (lines 43–91):** Four health polls:
- **ES:** hits `/_cluster/health` until it gets a JSON response with `"status"` — covers both `green` and `yellow`
- **Suricata rules:** watches `docker logs suricata` for `"waiting for pcap"` — that line is printed by `suricata-start.sh` only after rule download completes
- **Kibana data view:** polls Kibana's `/api/status` until it's `available`, then POSTs to `/api/data_views/data_view` to create the `suricata-*` pattern — this is what makes the index visible in Discover without manual setup
- **Filebeat:** checks logs for `"Connection to backoff.*established"` which is Filebeat's line when it successfully connects to ES

---

## `replay-pcap.sh` — The main workflow

```bash
curl -s "http://localhost:9200/_cat/indices/suricata-*?h=index" | \
  xargs -I{} curl -s -X DELETE "http://localhost:9200/{}"
```
Lists all existing `suricata-*` indices and deletes them. Gives you a clean slate so old events from a previous replay don't pollute results.

```bash
docker stop filebeat
```
Stops Filebeat before clearing logs. If Filebeat were still running, it might ship a partial `eve.json` or miss the file truncation.

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

```bash
docker start filebeat
```
Restarts Filebeat. It reads its registry (in the `filebeat_data` volume) to find where it last left off — but since `eve.json` was deleted and recreated, Filebeat detects it as a new file and ships everything from the beginning.

---

## Data flow summary

### PCAP replay

```
./replay-pcap.sh capture.pcap
  │
  ├─ curl DELETE /suricata-*          →  Elasticsearch wipes old indices
  ├─ docker stop filebeat             →  Filebeat stops tailing
  ├─ docker exec suricata rm eve.json →  log file deleted (bind mount deletes it on host too)
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
  │     │    3. Parses the JSON, promotes fields to root level
  │     │    4. timestamp processor: copies "timestamp" → "@timestamp"
  │     │    5. drop_fields: strips agent/host/input/log/message noise
  │     │    6. Batches events into bulk HTTP requests
  │     │    7. POST /_bulk → elasticsearch:9200
  │     │         body: { "index": { "_index": "suricata-2026.04.19" } }
  │     │                { ...event document... }
  │     │                { "index": { "_index": "suricata-2026.04.19" } }
  │     │                { ...event document... }
  │     │                ...
  │     │    8. Updates registry with new byte offset after each successful batch
  │     │
  │     └─ continues tailing (waiting for new lines) until stopped
  │
  └─ Elasticsearch receives each _bulk request:
        1. Parses the JSON documents
        2. Assigns each document an internal _id
        3. Writes to the index's transaction log (for durability)
        4. Builds/updates the inverted index for each field value
        5. Documents are now searchable
        6. Returns { "errors": false, ... } to Filebeat
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
  ┌─────────────────────────────────────────────────────────────────┐
  │                                                                 │
  │   browser                        curl / scripts                 │
  │      │                                  │                       │
  │      │ HTTP :5601                       │ HTTP :9200            │
  │      │                                  │                       │
  └──────┼──────────────────────────────────┼───────────────────────┘
         │  port forwarding                 │  port forwarding
  ───────┼──────────────────────────────────┼────────────────────────
         │  DOCKER INTERNAL NETWORK         │
  ───────┼──────────────────────────────────┼────────────────────────
         │                                  │
         ▼                                  ▼
  ┌─────────────────┐    POST /_search   ┌─────────────────────────┐
  │     Kibana      │ ─────────────────► │      Elasticsearch      │
  │                 │                    │                         │
  │  query builder  │ ◄───────────────── │  inverted index + store │
  │  render layer   │   JSON results     │  responds to HTTP only  │
  └─────────────────┘                    └─────────────────────────┘
                                                    ▲
                                                    │ POST /_bulk
                                                    │ (batched JSON docs)
                                                    │
                                          ┌─────────────────────────┐
                                          │        Filebeat         │
                                          │                         │
                                          │  tails eve.json         │
                                          │  parses + remaps fields │
                                          │  buffers into batches   │
                                          └─────────────────────────┘
                                                    │
                                                    │ reads (inode + offset
                                                    │  tracked in registry)
                                                    │
                                          ┌─────────────────────────┐
                                          │  ./logs/suricata/       │
                                          │      eve.json           │
                                          │                         │
                                          │  bind mount — same file │
                                          │  on host and containers │
                                          └─────────────────────────┘
                                                    ▲
                                                    │ writes (one JSON
                                                    │  object per line)
                                                    │
                                          ┌─────────────────────────┐
                                          │        Suricata         │
                                          │                         │
                                          │  on-demand via          │
                                          │  docker exec            │
                                          │  reads PCAP → rules →   │
                                          │  writes eve.json, exits │
                                          └─────────────────────────┘

  ── Notes ────────────────────────────────────────────────────────────
  · Kibana, Filebeat → Elasticsearch: HTTP on Docker internal network,
    using container name "elasticsearch:9200" as the hostname.
  · Suricata has internet access (Docker NATs out) — used by suricata-update
    on first run to download rules. It does not talk to the other containers.
  · Your browser and scripts reach ES/Kibana through port forwarding;
    containers never route through the host to talk to each other.
  ─────────────────────────────────────────────────────────────────────
```
