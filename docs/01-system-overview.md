# System Overview

This document explains what SOC Lab is, what it runs, and how the major components fit together.

## What SOC Lab Is

SOC Lab is a local environment for security operations workflows.

It is designed to let you do things like:

- replay a packet capture through Suricata
- capture live traffic from a local interface and feed it into the lab
- upload arbitrary logs and parse them into Elasticsearch
- test Suricata and Sigma detections
- recreate enterprise-facing alias names without copying data
- run enrichment scripts against the lab cluster or attached Elasticsearch clusters

The lab is intentionally practical. It is not just a static demo. It is a working environment for testing data ingestion, detection logic, alerting, aliasing, and enrichment behavior.

## The Main Idea

At a very high level, SOC Lab turns raw security-relevant input into searchable, enriched, and alertable data.

```text
PCAP / live packets / raw logs
    -> parsers and shippers
    -> Elasticsearch documents
    -> Kibana search + dashboards
    -> detection rules
    -> alerts
    -> enrichment scripts
```

The repo has two major layers:

1. runtime infrastructure
2. control plane code

Runtime infrastructure means the Docker services that actually hold and process data.

Control plane code means the Python and shell code that starts the stack, controls it, queries it, and exposes it to the web UI.

## Runtime Components

SOC Lab runs these core services through Docker Compose.

### Elasticsearch

Elasticsearch is the database and search engine.

It stores documents such as:

- Suricata alerts
- Suricata flow, DNS, HTTP, TLS, SMB, and other protocol records
- uploaded log lines after parsing
- ElastAlert2 alert documents
- enrichment audit records

Important mindset:

- Elasticsearch stores JSON documents
- everything important eventually becomes an Elasticsearch document
- most other components either write to Elasticsearch or read from it

### Kibana

Kibana is the analysis UI for Elasticsearch.

It is not the main SOC Lab control UI. The SOC Lab control UI is Dash. Kibana exists alongside it as the native Elastic search and dashboard experience.

You use Kibana for:

- Discover searches
- index inspection
- dashboards and saved views
- ad-hoc hunting

### Suricata

Suricata is the packet analysis engine.

In this lab, it is used mainly for:

- replaying PCAP files
- processing live-captured packet chunks
- generating `eve.json` event records
- loading Emerging Threats and custom rules

Suricata does not permanently run as a host network sniffer inside this repo's model. Instead, the repo usually runs Suricata on demand against replayed packet files.

### Filebeat

Filebeat is the log shipper.

It tails Suricata's `eve.json` and sends events to Elasticsearch.

This is important because the system does not have Suricata pushing directly into Elasticsearch. The path is:

```text
Suricata writes eve.json
    -> Filebeat tails eve.json
    -> Filebeat sends events to Elasticsearch
```

### ElastAlert2

ElastAlert2 is the alerting engine.

It runs scheduled searches against Elasticsearch and writes matching alerts back into Elasticsearch.

In practice, this gives the lab:

- native ElastAlert2 rules
- Sigma-based detections after conversion
- alert documents that can be queried and displayed in the UI

## Control Plane Components

The runtime services alone are not enough. SOC Lab also needs code that starts them, configures them, and exposes them in a developer-friendly way.

### FastAPI

FastAPI is the backend API.

It is the main state-changing and data-querying interface for the web UI.

FastAPI routes do things like:

- start or stop services
- fetch service logs
- list alerts
- run PCAP replay
- upload logs
- create aliases
- compile rules
- run enrichments

FastAPI should be thought of as the stable backend boundary.

### Dash

Dash is the web UI.

Dash does not directly manipulate Docker or Elasticsearch. Instead, it calls FastAPI endpoints over HTTP.

That boundary is important.

```text
Dash UI
   -> HTTP calls
FastAPI
   -> Python service modules
core/*
   -> Docker / Elasticsearch / Kibana / files
```

### `core/` Service Layer

`core/` contains the real behavior logic.

This is where the application actually decides how to:

- bring the stack up or down
- replay packet captures
- upload logs
- create aliases and Kibana data views
- compile rules
- run enrichments

If FastAPI is the public backend boundary, `core/` is the actual engine room.

## High-Level Architecture Diagram

```text
                           +----------------------+
                           |      Web Browser     |
                           |  Dash UI on :8050    |
                           +----------+-----------+
                                      |
                                      | HTTP
                                      v
                           +----------------------+
                           |       FastAPI        |
                           |   API on :8000       |
                           +----------+-----------+
                                      |
                                      | Python calls
                                      v
        +---------------------------------------------------------------+
        |                         core/* services                       |
        | stack | elastic | capture | ingest | rules | enrich | helpers |
        +-------------------+----------------------+--------------------+
                            |                      |
                            |                      |
              +-------------+----+      +----------+-----------------+
              |                  |      |                            |
              v                  v      v                            v
      +----------------+   +----------------------------+   +---------------+
      | Docker Compose |   | Elasticsearch and Kibana   |   | local files   |
      | service ctrl   |   | search, ingest, aliases    |   | config/data   |
      +----------------+   +----------------------------+   +---------------+
```

## Data-Centric View

If you look at the system from the point of view of data, Elasticsearch is the center.

```text
Suricata events -------------------------> Elasticsearch
Uploaded logs ---------------------------> Elasticsearch
ElastAlert2 queries ---------------------> Elasticsearch
ElastAlert2 alerts ----------------------> Elasticsearch
Kibana searches -------------------------> Elasticsearch
Dash/FastAPI queries --------------------> Elasticsearch
Enrichment scripts read and write -------> Elasticsearch
```

That is why so much of the repo revolves around:

- index names
- aliases
- pipelines
- timestamps
- mappings
- query behavior

## Reserved System Concepts

There are a few core concepts that appear again and again across the repo.

### `soc-alerts`

`soc-alerts` is a system alias.

It provides a unified alert view by combining multiple alert sources into one search target.

This matters because the UI and enrichment workflows should not need to remember every raw index name in order to work with alerts.

### Managed Data Views

When the repo creates important aliases or upload indices, it also tries to create matching Kibana data views.

This keeps Kibana usable without requiring manual UI setup after every change.

### Rules Watcher

The rules system includes a watcher process that notices rule file changes and reruns compile checks.

This is a development quality-of-life feature. It reduces the feedback loop for rule editing.

### Enrichment Audit

The enrichment subsystem records its changes in audit indices.

That matters because enrichment changes are not just reads. They can mutate data. The audit trail is what makes rollback and safety checks possible.

## Why The Repo Looks The Way It Does

The repo is in a migration stage.

Historically, SOC Lab used a stronger shell/TUI model. The current direction is a Python-centered web control plane.

So the codebase carries two important truths at once:

1. older docs still explain many underlying concepts very well
2. the current live architecture is increasingly centered on `core/`, FastAPI, and Dash

That is why some older documents mention `./soc-lab` CLI and shell-oriented flows in more detail than the current `start.sh`-driven web path.

## Mental Model For Contributors

If you are about to work on the repo, the safest mental model is:

```text
SOC Lab is a Python-controlled local Elastic security lab.

Docker services do the heavy runtime work.
FastAPI exposes backend control and data access.
Dash is the control UI.
core/* contains the behavior.
Elasticsearch is the system of record for most useful data.
```

If you keep that model in mind, the rest of the repo becomes much easier to navigate.
