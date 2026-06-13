from __future__ import annotations

import base64
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Query

from core.settings import repo_root
from core.ingest.pipeline import list_pipeline_dirs
from api.models import CaptureReplayRequest, CaptureUploadRequest, LiveCaptureStartRequest, PipelineUploadRequest
from api.utils import bad, human_size

router = APIRouter(prefix="/api/capture")

_HISTORY_FILE = lambda: repo_root() / ".soc-lab" / "capture-history.json"
_LIVE_PID_FILE = lambda: repo_root() / ".soc-lab" / "capture-live.pid"
_LIVE_LOG_FILE = lambda: repo_root() / ".soc-lab" / "capture-live.log"
_LIVE_SESSIONS_FILE = lambda: repo_root() / ".soc-lab" / "capture-live-sessions.json"

# ── async replay job store ────────────────────────────────────────────────────
_replay_jobs: dict[str, dict] = {}  # job_id → {lines, done, result, error}
_REPLAY_JOB_ID = "current"  # single-slot: only one replay at a time


# ── history ───────────────────────────────────────────────────────────────────

def _load_history() -> list[dict]:
    h = _HISTORY_FILE()
    if not h.exists():
        return []
    try:
        return json.loads(h.read_text())
    except Exception:
        return []


def _append_history(entry: dict) -> None:
    h = _HISTORY_FILE()
    h.parent.mkdir(parents=True, exist_ok=True)
    history = _load_history()
    history.insert(0, entry)
    h.write_text(json.dumps(history[:50], indent=2))


@router.get("/history")
def capture_history() -> dict:
    return {"history": _load_history()}


# ── network interfaces ────────────────────────────────────────────────────────

@router.get("/interfaces")
def network_interfaces() -> dict:
    import re
    import sys
    try:
        if sys.platform == "darwin":
            r = subprocess.run(["ifconfig", "-l"], capture_output=True, text=True, timeout=5)
            names = r.stdout.strip().split()
        else:
            r = subprocess.run(["ip", "-o", "link", "show"], capture_output=True, text=True, timeout=5)
            names = re.findall(r"^\d+: (\S+?)[@:]", r.stdout, re.MULTILINE)
        skip = set()
        skip_prefix = ("anpi", "XHC", "pktap")
        ifaces = [n for n in names if n not in skip and not any(n.startswith(p) for p in skip_prefix)]
        return {"interfaces": ifaces}
    except Exception as exc:
        return {"interfaces": [], "error": str(exc)}


# ── pcap files ────────────────────────────────────────────────────────────────

@router.get("/pcap/files")
def pcap_files() -> dict:
    pcap_dir = repo_root() / "data" / "pcap"
    if not pcap_dir.exists():
        return {"files": []}
    files = []
    for f in sorted(pcap_dir.rglob("*")):
        if f.is_file() and f.suffix in (".pcap", ".pcapng") and "live" not in f.parts:
            stat = f.stat()
            files.append({"name": str(f.relative_to(pcap_dir)), "size": stat.st_size,
                          "size_human": human_size(stat.st_size), "modified": stat.st_mtime})
    return {"files": files}


@router.get("/pcap/info")
def pcap_file_info(file: str) -> dict:
    from pathlib import Path as _Path
    safe = _Path(file).name
    path = repo_root() / "data" / "pcap" / safe
    if not path.exists():
        return {"error": "not found"}
    try:
        import csv, io, shutil, subprocess as sp
        # capinfos reads only PCAP headers — instant even on multi-GB files
        capinfos_bin = shutil.which("capinfos") or "/Applications/Wireshark.app/Contents/MacOS/capinfos"
        r = sp.run([capinfos_bin, "-T", "-m", str(path)], capture_output=True, text=True, timeout=30)
        rows = list(csv.DictReader(io.StringIO(r.stdout)))
        row = rows[0] if rows else {}
        packets = int(row.get("Number of packets", 0) or 0)
        duration = round(float(row.get("Capture duration (seconds)", 0) or 0), 1)
        size = int(row.get("File size (bytes)", path.stat().st_size) or 0)
    except Exception:
        packets, duration, size = 0, 0.0, path.stat().st_size

    # Protocol sampling — scapy reads only first 300 packets, fast on any file size
    KEEP = {"IP", "IPv6", "TCP", "UDP", "ICMP", "DNS", "ARP", "TLS", "HTTP", "DHCP"}
    protos: set[str] = set()
    try:
        from scapy.all import sniff
        for p in sniff(offline=str(path), count=300):
            for layer in p.layers():
                if layer.__name__ in KEEP:
                    protos.add(layer.__name__)
    except Exception:
        pass

    return {
        "packets": packets,
        "duration_secs": duration,
        "size_bytes": size,
        "protocols": sorted(protos),
    }


@router.get("/logs/files")
def log_files() -> dict:
    d = repo_root() / "data" / "ingest"
    if not d.exists():
        return {"files": []}
    files = []
    for f in sorted(d.rglob("*")):
        if f.is_file() and not f.name.startswith("."):
            stat = f.stat()
            files.append({"name": str(f.relative_to(d)), "size": stat.st_size,
                          "size_human": human_size(stat.st_size), "modified": stat.st_mtime})
    return {"files": files}


# ── replay ────────────────────────────────────────────────────────────────────

def _run_replay_job(target_pcap: str, keep: bool, now: bool, pcap_name: str) -> None:
    job = _replay_jobs[_REPLAY_JOB_ID]
    def log(line: str) -> None:
        job["lines"].append(line)

    try:
        log(f"[INFO] keep={keep}  now={now}  pcap={pcap_name}")
        from core.capture.replay import (
            _resolve_pcap, _delete_suricata_indices, _clear_elastalert_indices,
            ensure_soc_alerts_alias, _wait_for_docs,
            _eve_event_count, _suricata_doc_count, _fix_suricata_log_ownership,
            _as_added_counts, _soc_alert_doc_count,
            _parse_eve_lines, _shift_events_to_now, _append_eve_events, _valid_eve_event_count,
        )
        from core.elastic.aliases import ensure_suricata_alias
        import subprocess as sp

        abs_path = _resolve_pcap(target_pcap)
        pcap_dir_real = (repo_root() / "data" / "pcap").resolve()
        pcap_rel = str(abs_path.relative_to(pcap_dir_real))

        if not keep:
            log("[INFO] Clearing previous Suricata indices…")
            _delete_suricata_indices()
            _clear_elastalert_indices()
            sp.run(["docker", "stop", "elastalert2"], capture_output=True)
            sp.run(["docker", "exec", "suricata", "sh", "-c",
                    ": > /var/log/suricata/eve.json; : > /var/log/suricata/suricata.log"],
                   capture_output=True)
            _fix_suricata_log_ownership()

        log("[INFO] Ensuring soc-alerts alias…")
        ensure_soc_alerts_alias()
        baseline_docs = _suricata_doc_count()
        baseline_soc_docs = _soc_alert_doc_count()
        baseline_events = _eve_event_count()

        log(f"[INFO] Starting Suricata replay: {pcap_rel}")
        if now:
            tmp_log_dir = f"/tmp/soc-lab-replay-api-{os.getpid()}-{int(time.time())}"
            sp.run(["docker", "exec", "suricata", "sh", "-c", f"rm -rf {tmp_log_dir} && mkdir -p {tmp_log_dir}"], capture_output=True)
            try:
                proc = sp.Popen(
                    ["docker", "exec", "suricata", "suricata",
                     "-c", "/etc/suricata/suricata.yaml",
                     "-r", f"/pcap/{pcap_rel}",
                     "--pidfile", "/var/run/suricata-replay.pid",
                     "-l", tmp_log_dir,
                     "-k", "none"],
                    stdout=sp.PIPE, stderr=sp.STDOUT, text=True,
                )
                assert proc.stdout
                for line in proc.stdout:
                    line = line.rstrip()
                    if line:
                        log(line)
                proc.wait()
                if proc.returncode == 0:
                    raw_eve = sp.run(
                        ["docker", "exec", "suricata", "sh", "-c", f"cat {tmp_log_dir}/eve.json 2>/dev/null || true"],
                        capture_output=True, text=True,
                    ).stdout
                    events = _parse_eve_lines(raw_eve)
                    _shift_events_to_now(events)
                    eve = repo_root() / "runtime" / "logs" / "suricata" / "eve.json"
                    eve.parent.mkdir(parents=True, exist_ok=True)
                    _fix_suricata_log_ownership()
                    _append_eve_events(eve, events)
                    replay_new_events = _valid_eve_event_count(events)
                else:
                    replay_new_events = 0
            finally:
                sp.run(["docker", "exec", "suricata", "sh", "-c", f"rm -rf {tmp_log_dir}"], capture_output=True)
        else:
            proc = sp.Popen(
                ["docker", "exec", "suricata", "suricata",
                 "-c", "/etc/suricata/suricata.yaml",
                 "-r", f"/pcap/{pcap_rel}",
                 "--pidfile", "/var/run/suricata-replay.pid",
                 "-l", "/var/log/suricata",
                 "-k", "none"],
                stdout=sp.PIPE, stderr=sp.STDOUT, text=True,
            )
            assert proc.stdout
            for line in proc.stdout:
                line = line.rstrip()
                if line:
                    log(line)
            proc.wait()
            _fix_suricata_log_ownership()
            replay_new_events = max(_eve_event_count() - baseline_events, 0)

        if proc.returncode != 0:
            log(f"[ERROR] Suricata exited with code {proc.returncode}")
            job["error"] = "Suricata replay failed"
            return

        if now:
            log("[INFO] Shifted replay timestamps to now before Filebeat ingestion")

        ensure_soc_alerts_alias()
        ensure_suricata_alias()

        if not keep:
            sp.run(["docker", "start", "elastalert2"], capture_output=True)
            log("[INFO] ElastAlert2 restarted")

        log("[INFO] Waiting for docs to appear in Elasticsearch…")
        new_events = replay_new_events
        expected_docs = baseline_docs + new_events
        if new_events:
            log(f"[INFO] Suricata eve.json new events: {new_events:,}")
        docs = _as_added_counts(
            _wait_for_docs(expected_suricata_docs=expected_docs),
            baseline_docs,
            baseline_soc_docs,
        )
        log(f"[INFO] Suricata docs: +{docs.get('suricata_docs', 0):,}")
        if "suricata_docs_total" in docs:
            log(f"[INFO] Suricata docs total: {docs.get('suricata_docs_total', 0):,}")
        log(f"[INFO] soc-alerts docs: +{docs.get('soc_alerts_docs', 0)}")
        if "soc_alerts_docs_total" in docs:
            log(f"[INFO] soc-alerts docs total: {docs.get('soc_alerts_docs_total', 0):,}")
        if docs.get("warning"):
            log(f"[WARN] {docs['warning']}")

        result = {"pcap": str(abs_path), "keep": keep, "now": now, **docs}
        _append_history({
            "pcap": pcap_name,
            "keep": keep,
            "now": now,
            "suricata_docs": docs.get("suricata_docs"),
            "soc_alerts_docs": docs.get("soc_alerts_docs"),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": "done",
        })
        job["result"] = result

    except Exception as exc:
        log(f"[ERROR] {exc}")
        job["error"] = str(exc)
    finally:
        job["done"] = True


@router.post("/replay")
def capture_replay(request: CaptureReplayRequest) -> dict:
    try:
        if request.content:
            data = base64.b64decode(request.content.split(",", 1)[-1])
            pcap_dir = repo_root() / "data" / "pcap"
            pcap_dir.mkdir(exist_ok=True)
            target = pcap_dir / Path(request.pcap).name
            target.write_bytes(data)
            target_pcap = str(target.relative_to(repo_root()))
        else:
            # file selected from data/pcap/ folder — just the filename
            candidate = repo_root() / "data" / "pcap" / request.pcap
            target_pcap = str(candidate.relative_to(repo_root())) if candidate.exists() else request.pcap

        _replay_jobs[_REPLAY_JOB_ID] = {"lines": [], "done": False, "result": None, "error": None}
        t = threading.Thread(
            target=_run_replay_job,
            args=(target_pcap, request.keep, request.now, Path(target_pcap).name),
            daemon=True,
        )
        t.start()
        return {"started": True, "job_id": _REPLAY_JOB_ID}
    except Exception as exc:
        raise bad(exc, 500)


@router.get("/replay/status")
def capture_replay_status() -> dict:
    job = _replay_jobs.get(_REPLAY_JOB_ID)
    if not job:
        return {"running": False, "done": True, "lines": [], "result": None, "error": None}
    return {
        "running": not job["done"],
        "done": job["done"],
        "lines": job["lines"],
        "result": job.get("result"),
        "error": job.get("error"),
    }


# ── upload ────────────────────────────────────────────────────────────────────

@router.post("/upload")
def capture_upload(request: CaptureUploadRequest) -> dict:
    try:
        from core.ingest.upload import upload
        orig_name = Path(request.filename or "upload.log")
        index = request.index or orig_name.stem.replace(" ", "-").lower()

        if request.content:
            data = base64.b64decode(request.content.split(",", 1)[-1])
            suffix = orig_name.suffix or ".log"
            fd, tmp = tempfile.mkstemp(suffix=suffix)
            tmp_path = Path(tmp)
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
                results = upload(
                    target=str(tmp_path), keep=request.keep, now=request.now,
                    index_override=index, type_override=request.type or "",
                    use_ai=request.build_pipeline, llm_ram_mode=request.llm_ram_mode,
                )
            finally:
                if tmp_path.exists():
                    tmp_path.unlink()
            return {"results": results}

        # file selected from data/ingest/ folder
        if request.filename:
            ingest_path = repo_root() / "data" / "ingest" / request.filename
            if not ingest_path.exists():
                raise FileNotFoundError(f"File not found in data/ingest/: {request.filename}")
            results = upload(
                target=str(ingest_path), keep=request.keep, now=request.now,
                index_override=index, type_override=request.type or "",
                use_ai=request.build_pipeline, llm_ram_mode=request.llm_ram_mode,
            )
            return {"results": results}

        results = upload(
            target=request.file_path, batch=request.batch, folder=request.folder,
            keep=request.keep, now=request.now, index_override=request.index or "",
            type_override=request.type or "", use_ai=request.build_pipeline,
            llm_ram_mode=request.llm_ram_mode,
        )
        return {"results": results}
    except Exception as exc:
        raise bad(exc, 500)


# ── pipelines ─────────────────────────────────────────────────────────────────

@router.get("/pipelines")
def pipelines_list() -> dict:
    root = repo_root()
    pipelines: list[dict] = []
    for category, d in list_pipeline_dirs().items():
        if d.is_dir():
            for f in sorted(d.iterdir()):
                if f.suffix in (".yml", ".yaml"):
                    pipelines.append({"name": f.stem, "category": category, "file": str(f.relative_to(root))})
    return {"pipelines": pipelines}


@router.post("/pipeline/upload")
def pipeline_upload(body: PipelineUploadRequest) -> dict:
    try:
        data = base64.b64decode(body.content.split(",", 1)[-1])
        target = repo_root() / "data" / "pipelines" / "custom" / body.filename
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return {"saved": True, "path": str(target.relative_to(repo_root()))}
    except Exception as exc:
        raise bad(exc, 500)


@router.get("/pipelines/vendors")
def pipelines_vendors() -> dict:
    pipeline_dir = repo_root() / "data" / "pipelines" / "elasticsearch"
    if not pipeline_dir.exists():
        return {"vendors": []}
    vendor_counts: dict[str, int] = {}
    for f in pipeline_dir.iterdir():
        if f.suffix not in (".yml", ".yaml"):
            continue
        vendor = f.stem.split("-")[0].replace("_", " ").title()
        vendor_counts[vendor] = vendor_counts.get(vendor, 0) + 1
    vendors = sorted(
        [{"vendor": v, "count": c, "category": _vendor_category(v)} for v, c in vendor_counts.items()],
        key=lambda x: x["vendor"],
    )
    return {"vendors": vendors}


def _vendor_category(vendor: str) -> str:
    v = vendor.lower()
    if v.startswith("ti ") or any(x in v for x in ["threat intel", "threatconnect", "opencti", "misp",
                                                     "greynoise", "recordedfuture", "flashpoint", "anomali",
                                                     "cybersixgill", "cyware", "domaintools", "eclecticiq",
                                                     "mandiant", "abuse.ch", "abusech", "threatq", "otx",
                                                     "anyrun", "epss"]):
        return "Threat Intel"
    if any(x in v for x in ["crowdstrike", "carbon black", "carbonblack", "cybereason", "sentinel one",
                              "sentinelone", "cylance", "symantec", "trendmicro", "trend micro", "sophos",
                              "bitdefender", "eset", "jamf", "trellix", "fireeye", "digital guardian",
                              "nextron", "claroty", "forescout", "tanium", "tetragon", "sysdig", "falco",
                              "osquery", "vectra", "darktrace", "cyera", "withsecure", "armis", "nozomi", "airlock"]):
        return "Endpoint"
    if any(x in v for x in ["okta", "ldap", "duo", "pingidentity", "auth0", "authentik", "beyondtrust",
                              "beyondinsight", "cyberark", "jumpcloud", "keycloak", "forgerock", "ping ",
                              "sailpoint", "teleport", "thycotic", "hashicorp vault", "1password",
                              "bitwarden", "lastpass", "entityanalytics", "keeper", "identity", "lumos", "entro"]):
        return "Identity"
    if any(x in v for x in ["windows", "sysmon", "microsoft", "active directory", "m365 ", "o365", "entra", "defender", "intune"]):
        return "Windows"
    if any(x in v for x in ["linux", "syslog", "ubuntu", "debian", "rhel", "centos", "auditd", "macos", "santa", "iptables"]):
        return "Linux"
    if any(x in v for x in ["aws ", "azure", "gcp", "google ", "cloudtrail", "salesforce", "amazon security", "tencent cloud", "awsfirehose"]):
        return "Cloud"
    if any(x in v for x in ["suricata", "zeek", "snort", "palo", "cisco", "fortinet", "checkpoint", "juniper",
                              "arista", "f5 ", "sonicwall", "pfsense", "watchguard", "bluecoat", "forcepoint",
                              "stormshield", "netflow", "network traffic", "radware", "netscout", "pulse connect",
                              "proxysg", "squid", "zscaler", "netskope", "akamai", "cloudflare", "extrahop",
                              "goflow", "hpe aruba", "imperva", "haproxy", "traefik", "envoyproxy", "prisma access"]):
        return "Network"
    if any(x in v for x in ["proofpoint", "mimecast", "ironscales", "sublime security", "barracuda", "checkpoint email", "abnormal"]):
        return "Email"
    if any(x in v for x in ["mysql", "postgresql", "oracle ", "mongodb", "redis", "cassandra", "couchdb",
                              "couchbase", "memcached", "cockroachdb", "influxdb", "etcd", "rabbitmq",
                              "kafka", "nats ", "elasticsearch", "ceph", "ibmmq"]):
        return "Database"
    if any(x in v for x in ["splunk", "qradar", "ibm q", "rapid7", "swimlane", "tines", "elastic agent",
                              "elastic package", "elastic security", "logstash", "kibana", "cribl", "canva",
                              "wiz ", "servicenow", "tenable", "qualys", "snyk", "rubrik"]):
        return "Security Ops"
    if any(x in v for x in ["kubernetes", "docker", "gitlab", "github", "jenkins", "istio", "coredns",
                              "grafana", "prometheus", "golang", "spring boot", "airflow", "apache spark",
                              "activemq", "vsphere", "netbox", "nginx", "apache ", "tomcat", "iis",
                              "citrix", "modsecurity", "php fpm", "websphere"]):
        return "DevOps/Web"
    return "Other"


# ── live capture ──────────────────────────────────────────────────────────────

def _load_live_sessions() -> list[dict]:
    f = _LIVE_SESSIONS_FILE()
    if not f.exists():
        return []
    try:
        return json.loads(f.read_text())
    except Exception:
        return []


def _save_live_sessions(sessions: list[dict]) -> None:
    f = _LIVE_SESSIONS_FILE()
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(sessions[:50], indent=2))


@router.get("/live/sessions")
def live_sessions() -> dict:
    return {"sessions": _load_live_sessions()[:15]}


@router.get("/live/status")
def live_status() -> dict:
    pid_file = _LIVE_PID_FILE()
    if not pid_file.exists():
        return {"running": False, "pid": None}
    try:
        pid = int(pid_file.read_text().strip())
        os.kill(pid, 0)
        return {"running": True, "pid": pid}
    except (ProcessLookupError, ValueError):
        pid_file.unlink(missing_ok=True)
        return {"running": False, "pid": None}


@router.post("/live/start")
def live_start(body: LiveCaptureStartRequest) -> dict:
    pid_file = _LIVE_PID_FILE()
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, 0)
            return {"already_running": True, "pid": pid}
        except (ProcessLookupError, ValueError):
            pid_file.unlink(missing_ok=True)
    try:
        root = str(repo_root())
        log_file = _LIVE_LOG_FILE()
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log_file.write_text("")  # clear stale output from previous session
        log_fh = open(log_file, "w")
        proc = subprocess.Popen(
            [sys.executable, "-c",
             f"import sys, warnings; warnings.filterwarnings('ignore'); "
             f"sys.path.insert(0, r'{root}'); "
             f"from core.capture.live import live; "
             f"live('{body.iface}', rotation_secs={body.rotation}, keep={body.keep})"],
            start_new_session=True, cwd=root,
            stdout=log_fh, stderr=log_fh,
        )
        pid_file.write_text(str(proc.pid))
        sessions = _load_live_sessions()
        sessions.insert(0, {
            "interface": body.iface,
            "rotation_secs": body.rotation,
            "keep": body.keep,
            "started_at": datetime.now(timezone.utc).isoformat(),
            "stopped_at": None,
            "status": "running",
        })
        _save_live_sessions(sessions)
        return {"started": True, "pid": proc.pid}
    except Exception as exc:
        raise bad(exc, 500)


@router.post("/live/stop")
def live_stop() -> dict:
    pid_file = _LIVE_PID_FILE()
    if not pid_file.exists():
        return {"stopped": True, "was_running": False}
    try:
        pid = int(pid_file.read_text().strip())
        os.kill(pid, signal.SIGTERM)
        pid_file.unlink(missing_ok=True)
        sessions = _load_live_sessions()
        for s in sessions:
            if s.get("status") == "running":
                s["stopped_at"] = datetime.now(timezone.utc).isoformat()
                s["status"] = "stopped"
                break
        _save_live_sessions(sessions)
        return {"stopped": True, "was_running": True, "pid": pid}
    except (ProcessLookupError, ValueError):
        pid_file.unlink(missing_ok=True)
        return {"stopped": True, "was_running": False}
    except Exception as exc:
        raise bad(exc, 500)


@router.get("/live/log")
def live_log(lines: int = Query(default=100)) -> dict:
    log_file = _LIVE_LOG_FILE()
    if not log_file.exists():
        return {"log": ""}
    try:
        text = log_file.read_text(errors="replace")
        tail = "\n".join(text.splitlines()[-lines:])
        return {"log": tail}
    except Exception:
        return {"log": ""}
