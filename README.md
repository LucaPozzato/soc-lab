# SOC Lab

SOC Lab is a self-contained local network security detection lab. It lets you replay PCAPs, run live packet capture, and ingest arbitrary logs — feeding all of it through Suricata IDS and Sigma/ElastAlert2 detections, with results visible in Kibana.

The stack runs entirely in Docker. A single CLI entry point (`./soc-lab`) drives everything, either through a terminal UI or direct subcommands.

---

## What's in the repo

```
soc-lab                  # main CLI entry point
docker-compose.yml       # stack definition
config/                  # Suricata, Filebeat, ElastAlert2 config files
scripts/
  commands/              # CLI command handlers
  lib/                   # shared shell helpers and logging
  loaders/               # Security Onion template and pipeline loaders
  runtime/               # container entrypoint scripts
  tools/                 # upload-logs.sh, pipeline_generator.py, venv setup
rules/
  suricata/              # custom .rules files (auto-loaded by Suricata)
  sigma/                 # Sigma YAML detection rules (auto-converted on container start)
pipelines/
  elasticsearch/         # bundled Elasticsearch ingest pipelines
  custom/                # user-added pipelines
  generated/             # LLM-generated pipelines (--build-pipeline output)
pcap/                    # drop PCAPs here for replay
tui/                     # Go source for the Bubble Tea TUI
docker-logs/             # bind-mount targets; Suricata logs and rule status artifacts
```

---

## Prerequisites

- Docker + Docker Compose plugin
- `dumpcap` (for `capture live`; part of Wireshark/tshark tools)
- Go 1.22+ (only needed to rebuild the TUI binary)
- Python 3.10+
- Ollama running locally (optional; only for `--build-pipeline`)

---

## Install and start

```bash
# Bootstrap Python venv and install local dependencies
./soc-lab stack install

# Start the full stack
./soc-lab stack start

# Verify everything is healthy
./soc-lab health check
```

After `stack start`:
- Kibana: http://localhost:5601
- Elasticsearch: http://localhost:9200

`stack start` loads Security Onion ECS templates and ingest pipelines, creates Kibana data views, and starts the rules watcher. Data views are checked for existence before creation — re-running `stack start` will not create duplicates.

---

## TUI

The default way to use SOC Lab:

```bash
./soc-lab tui
# or just
./soc-lab
```

The TUI shows live service status, rules health, capture state, and a scrollable output pane. Type commands at the prompt and press Enter.

| Key | Action |
|-----|--------|
| `tab` | Autocomplete / cycle completions |
| `↑` / `↓` | Command history |
| `pgup` / `pgdn` | Scroll output |
| `f` | Toggle focus mode (hide panels, maximise output) |
| `q` | Quit |

Type `help` at the prompt to see the command palette.

---

## Command reference

### Stack

```bash
./soc-lab stack install      # install Python venv and local deps
./soc-lab stack start        # start all containers and initialise the stack
./soc-lab stack status       # show container state
./soc-lab stack stop         # stop containers, preserve volumes
./soc-lab stack reset        # stop and wipe all volumes (prompts for confirmation)
./soc-lab stack uninstall    # full teardown: containers, volumes, venv, installer-managed deps
```

### PCAP replay

Drop a PCAP in `./pcap/`, then:

```bash
./soc-lab capture replay pcap/file.pcap
./soc-lab capture replay pcap/file.pcap --now     # shift event timestamps to current time
./soc-lab capture replay pcap/file.pcap --keep    # keep existing indexed data
```

`--now` is useful when the PCAP is old and Kibana's default "last 15 minutes" view would miss the events.

Each replay (without `--keep`) resets Suricata indices, clears ElastAlert2 alert/status/silence indices, stops ElastAlert2, clears Suricata logs, then replays and restarts everything clean.

### Live capture

```bash
./soc-lab capture live                     # default interface (en0), 10 s chunk rotation
./soc-lab capture live en0 30              # interface en0, 30 s chunks
./soc-lab capture live en0 10 --keep       # preserve previously indexed data
```

Captures with `dumpcap` into a rotating ring of `.pcapng` files. Each completed chunk is automatically replayed through Suricata. A new session (without `--keep`) resets all Suricata and ElastAlert2 data before starting.

### Log upload

```bash
# Use a named ingest pipeline
./soc-lab capture upload logs/app.log --type <pipeline-name>

# Generate a pipeline from the log sample using a local LLM
./soc-lab capture upload logs/app.log --build-pipeline

# Batch upload a folder
./soc-lab capture upload --batch --folder logs/sample-set --type <pipeline-name>
./soc-lab capture upload --batch --folder logs/sample-set --build-pipeline
```

Pipeline resolution for `--type`:
- Checks Elasticsearch (pipeline already loaded)
- Falls back to local YAML in `pipelines/elasticsearch/`, `pipelines/custom/`, `pipelines/generated/`
- If the pipeline cannot be loaded, reports the failure; if the log is JSON or CEF, interactively offers to fall back to direct ingest

JSON and CEF files are ingested directly without a pipeline. Plain text requires `--type` or `--build-pipeline`.

Optional flags:
- `--keep` — append to the existing index instead of deleting it first
- `--now` — set `@timestamp` to ingest time; preserve the original parsed time in `event.created`
- `--index <name>` — override the target index name

### Rules

```bash
./soc-lab rules compile    # validate Suricata rules and convert Sigma rules
```

Writes status artifacts to `docker-logs/rules/`:
- `status.json` — machine-readable rule health (read by TUI)
- `suricata-compile.log`
- `sigma-compile.log`

The rules watcher starts automatically with the stack and recompiles whenever rule files change.

### Health

```bash
./soc-lab health check
```

### Security Onion sync

```bash
./soc-lab so sync    # reload SO ECS templates and ingest pipelines
```

Runs automatically during `stack start`. Use manually to refresh pipelines without a full restart.

---

## Rules

| Folder | Contents |
|--------|----------|
| `rules/suricata/` | Custom Suricata `.rules` files — loaded automatically |
| `rules/sigma/` | Sigma YAML detection rules — converted to ElastAlert2 format on container start |

Edit rule files; the watcher picks up changes and recompiles within a few seconds.

---

## Kibana data views

Created automatically by `stack start` (only if they do not already exist):

| Name | Pattern | Contents |
|------|---------|----------|
| All Logs | `*` | Everything |
| Suricata | `suricata-*` | All Suricata events (alerts, DNS, HTTP, TLS, flow, …) |
| ElastAlert2 Alerts | `elastalert2_alerts` | Sigma/ElastAlert2 fired alerts |
| Alerts | `soc-alerts` | Unified: Suricata IDS alerts + ElastAlert2/Sigma alerts |

Each `capture upload` also creates a `logs-<name>-*` data view for the uploaded data.

---

## Stop and cleanup

```bash
./soc-lab stack stop         # stop containers, volumes survive
./soc-lab stack reset        # stop + wipe volumes (requires confirmation)
./soc-lab stack uninstall    # full teardown including deps
```
