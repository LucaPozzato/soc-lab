# SOC Lab

Personal security lab for testing Suricata IDS detection and whitelist rules via PCAP replay and live capture.

## Stack

| Container | Image | Role |
|---|---|---|
| elasticsearch | elastic/elasticsearch:8.13.0 | Log storage and search |
| kibana | elastic/kibana:8.13.0 | Dashboards — http://localhost:5601 |
| suricata | jasonish/suricata:latest | IDS — writes eve.json |
| filebeat | elastic/filebeat:8.13.0 | Ships suricata logs to ES |

## Quick Start

```bash
./docker.sh start
```

On first run, Suricata downloads ~43k Emerging Threats community rules (~1-2 minutes). Rules persist across restarts.

## Directory Layout

```
config/
  suricata/suricata.yaml      Suricata config
  suricata/threshold.config   Alert suppression (checksum noise SIDs)
  filebeat/filebeat.yml       Log shipping config
scripts/
  suricata-start.sh           Container entrypoint: downloads rules on first run
logs/
  suricata/                   eve.json and suricata.log written here
pcap/                         Drop .pcap files here for replay
pcap/live/                    Live capture PCAPs (managed by live-capture.sh)
rules/                        Custom .rules files (auto-loaded by Suricata)
```

## Scripts

| Script | What it does |
|---|---|
| `docker.sh start` | Start stack, wait for healthy, create ES data view |
| `docker.sh stop` | Stop containers, keep volumes (ES data + rules) |
| `docker.sh reset` | Stop containers and wipe all volumes |
| `check-health.sh` | Container status, ES cluster health, recent log samples |
| `replay-pcap.sh` | Replay a .pcap through Suricata |
| `live-capture.sh` | Continuous tcpdump capture with auto-replay |
| `reload-rules.sh` | Pull latest ET community rules, reload without restart |
| `clean.sh` | Wipe ES indices, eve.json, and suricata.log for a clean slate |

## PCAP Replay

```bash
cp /path/to/capture.pcap ./pcap/
./replay-pcap.sh pcap/capture.pcap
```

Each replay wipes the previous ES data and eve.json for a clean slate. Events appear in Kibana under `suricata-*`.

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
# Total alerts
curl -s "http://localhost:9200/suricata-*/_count?q=event_type:alert"

# Alerts by signature
curl -s "http://localhost:9200/suricata-*/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"size":0,"query":{"term":{"event_type":"alert"}},"aggs":{"by_sig":{"terms":{"field":"alert.signature.keyword","size":20}}}}'

# Quick count from eve.json directly
docker exec suricata grep -c '"event_type":"alert"' /var/log/suricata/eve.json
```

## Custom Rules

Add `.rules` files to `./rules/` — loaded automatically by Suricata. To reload without restarting:

```bash
./reload-rules.sh
```

Suricata rule syntax reference: https://docs.suricata.io/en/latest/rules/index.html

## Stop / Reset

```bash
./docker.sh stop    # stop, keep volumes (ES data + rules)
./docker.sh reset   # stop and wipe everything (rules re-download on next start)
```

## Known Constraints

- **ES yellow status**: Normal on a single-node cluster — replicas are unassigned.
- **Live capture delay**: Traffic appears in Kibana after the current rotation completes, not in real time.
- **First-run rule download**: Requires internet access, takes ~1-2 minutes.
