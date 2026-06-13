from __future__ import annotations

import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from core.settings import repo_root
from core.elastic.client import client as es_client


def ensure_soc_alerts_alias() -> None:
    from core.elastic.aliases import ensure_soc_alerts_alias as ensure_reserved_soc_alerts_alias

    ensure_reserved_soc_alerts_alias()


def _fix_suricata_log_ownership() -> None:
    subprocess.run(
        ["docker", "exec", "suricata", "sh", "-c",
         f"chown {os.getuid()}:{os.getgid()} /var/log/suricata/eve.json /var/log/suricata/suricata.log 2>/dev/null || true"],
        capture_output=True,
    )


def _delete_suricata_indices() -> None:
    es = es_client()
    rows = es.options(ignore_status=[404]).cat.indices(index="suricata-*", format="json", h="index")
    for row in rows or []:
        idx = row.get("index", "")
        if idx:
            es.options(ignore_status=[404]).indices.delete(index=idx)


def _clear_elastalert_indices() -> None:
    es = es_client()
    for idx in ["elastalert2_alerts", "elastalert2_alerts_status", "elastalert2_alerts_silence"]:
        es.options(ignore_status=[404]).delete_by_query(
            index=idx,
            body={"query": {"match_all": {}}},
        )


def _resolve_pcap(pcap_arg: str) -> Path:
    root = repo_root()
    pcap_dir = root / "data" / "pcap"
    p = Path(pcap_arg)
    if p.is_absolute():
        abs_path = p.resolve()
    elif str(p).startswith("data/pcap/") or str(p).startswith("./data/pcap/"):
        abs_path = (root / p).resolve()
    else:
        abs_path = (pcap_dir / p).resolve()

    if not abs_path.exists():
        raise FileNotFoundError(f"PCAP not found: {abs_path}")

    pcap_dir_real = pcap_dir.resolve()
    if not str(abs_path).startswith(str(pcap_dir_real) + "/"):
        raise ValueError(f"PCAP must be inside ./pcap (got: {abs_path})")

    return abs_path


def _parse_eve_lines(text: str) -> list[Any]:
    events: list[Any] = []
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            events.append(json.loads(ln))
        except Exception:
            events.append(ln)
    return events


def _shift_events_to_now(events: list[Any]) -> None:
    earliest = None
    for e in events:
        if not isinstance(e, dict):
            continue
        try:
            ts = datetime.fromisoformat(e.get("timestamp", "").replace("+0000", "+00:00"))
            earliest = ts if earliest is None or ts < earliest else earliest
        except Exception:
            pass

    if earliest is None:
        return

    offset = datetime.now(timezone.utc) - earliest
    fmt = "%Y-%m-%dT%H:%M:%S.%f+0000"
    for e in events:
        if not isinstance(e, dict):
            continue
        try:
            ts = datetime.fromisoformat(e.get("timestamp", "").replace("+0000", "+00:00"))
            e["timestamp"] = (ts + offset).strftime(fmt)
        except Exception:
            pass


def _append_eve_events(eve_path: Path, events: list[Any]) -> None:
    with open(eve_path, "a") as f:
        for e in events:
            f.write((json.dumps(e) if isinstance(e, dict) else str(e)) + "\n")


def _valid_eve_event_count(events: list[Any]) -> int:
    return sum(1 for e in events if isinstance(e, dict))


def _shift_timestamps(eve_path: Path) -> None:
    with open(eve_path) as f:
        events = _parse_eve_lines(f.read())

    _shift_events_to_now(events)

    with open(eve_path, "w") as f:
        for e in events:
            f.write((json.dumps(e) if isinstance(e, dict) else str(e)) + "\n")


def _wait_for_docs(timeout: int = 120, expected_suricata_docs: int | None = None) -> dict[str, int]:
    es = es_client()
    deadline = time.monotonic() + timeout
    last_counts = {"suricata_docs": 0, "soc_alerts_docs": 0}
    stable_polls = 0
    while time.monotonic() < deadline:
        try:
            suri = es.options(ignore_status=[404]).count(index="suricata-*").get("count", 0)
            soc = es.options(ignore_status=[404]).count(index="soc-alerts").get("count", 0)
            counts = {"suricata_docs": int(suri), "soc_alerts_docs": int(soc)}
            if expected_suricata_docs is not None and suri >= expected_suricata_docs:
                return counts
            if counts == last_counts and suri > 0:
                stable_polls += 1
            else:
                stable_polls = 0
                last_counts = counts
            if expected_suricata_docs is None and stable_polls >= 3:
                return counts
        except Exception:
            pass
        time.sleep(1)
    warning = "No docs visible yet (Filebeat may still be shipping)"
    if expected_suricata_docs is not None and last_counts["suricata_docs"] > 0:
        warning = (
            f"Elasticsearch has {last_counts['suricata_docs']} Suricata docs, expected about "
            f"{expected_suricata_docs} after replay"
        )
    return {
        **last_counts,
        "warning": warning,
    }


def _eve_event_count() -> int:
    eve = repo_root() / "runtime" / "logs" / "suricata" / "eve.json"
    count = 0
    try:
        with open(eve) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    json.loads(line)
                except json.JSONDecodeError:
                    continue
                count += 1
    except FileNotFoundError:
        return 0
    return count


def _suricata_doc_count() -> int:
    try:
        return int(es_client().options(ignore_status=[404]).count(index="suricata-*").get("count", 0))
    except Exception:
        return 0


def _soc_alert_doc_count() -> int:
    try:
        return int(es_client().options(ignore_status=[404]).count(index="soc-alerts").get("count", 0))
    except Exception:
        return 0


def _as_added_counts(
    docs: dict[str, int],
    baseline_suricata_docs: int,
    baseline_soc_alert_docs: int = 0,
) -> dict[str, int]:
    suricata_total = int(docs.get("suricata_docs", 0))
    soc_total = int(docs.get("soc_alerts_docs", 0))
    return {
        **docs,
        "suricata_docs": max(suricata_total - baseline_suricata_docs, 0),
        "soc_alerts_docs": max(soc_total - baseline_soc_alert_docs, 0),
        "suricata_docs_total": suricata_total,
        "soc_alerts_docs_total": soc_total,
    }


def replay(pcap_arg: str, *, keep: bool = False, now: bool = False) -> dict[str, Any]:
    abs_path = _resolve_pcap(pcap_arg)
    pcap_dir_real = (repo_root() / "data" / "pcap").resolve()
    pcap_rel = str(abs_path.relative_to(pcap_dir_real))

    if not keep:
        _delete_suricata_indices()
        _clear_elastalert_indices()
        subprocess.run(["docker", "stop", "elastalert2"], capture_output=True)
        subprocess.run(
            ["docker", "exec", "suricata", "sh", "-c",
             ": > /var/log/suricata/eve.json; : > /var/log/suricata/suricata.log"],
            capture_output=True,
        )
        _fix_suricata_log_ownership()

    ensure_soc_alerts_alias()
    baseline_docs = _suricata_doc_count()
    baseline_soc_docs = _soc_alert_doc_count()
    baseline_events = _eve_event_count()

    if now:
        tmp_log_dir = f"/tmp/soc-lab-replay-{os.getpid()}-{int(time.time())}"
        subprocess.run(
            ["docker", "exec", "suricata", "sh", "-c", f"rm -rf {tmp_log_dir} && mkdir -p {tmp_log_dir}"],
            capture_output=True,
        )
        try:
            result = subprocess.run(
                ["docker", "exec", "suricata", "suricata",
                 "-c", "/etc/suricata/suricata.yaml",
                 "-r", f"/pcap/{pcap_rel}",
                 "--pidfile", "/var/run/suricata-replay.pid",
                 "-l", tmp_log_dir,
                 "-k", "none"],
                capture_output=True, text=True,
            )
            if result.returncode == 0:
                raw_eve = subprocess.run(
                    ["docker", "exec", "suricata", "sh", "-c", f"cat {tmp_log_dir}/eve.json 2>/dev/null || true"],
                    capture_output=True, text=True,
                ).stdout
                events = _parse_eve_lines(raw_eve)
                _shift_events_to_now(events)
                eve = repo_root() / "runtime" / "logs" / "suricata" / "eve.json"
                eve.parent.mkdir(parents=True, exist_ok=True)
                _fix_suricata_log_ownership()
                _append_eve_events(eve, events)
                new_events = _valid_eve_event_count(events)
            else:
                new_events = 0
        finally:
            subprocess.run(
                ["docker", "exec", "suricata", "sh", "-c", f"rm -rf {tmp_log_dir}"],
                capture_output=True,
            )
    else:
        result = subprocess.run(
            ["docker", "exec", "suricata", "suricata",
             "-c", "/etc/suricata/suricata.yaml",
             "-r", f"/pcap/{pcap_rel}",
             "--pidfile", "/var/run/suricata-replay.pid",
             "-l", "/var/log/suricata",
             "-k", "none"],
            capture_output=True, text=True,
        )
        _fix_suricata_log_ownership()
        new_events = max(_eve_event_count() - baseline_events, 0)

    if result.returncode != 0:
        raise RuntimeError(f"Suricata replay failed: {result.stderr.strip()}")

    ensure_soc_alerts_alias()
    from core.elastic.aliases import ensure_suricata_alias
    ensure_suricata_alias()

    if not keep:
        subprocess.run(["docker", "start", "elastalert2"], capture_output=True)

    docs = _as_added_counts(
        _wait_for_docs(expected_suricata_docs=baseline_docs + new_events),
        baseline_docs,
        baseline_soc_docs,
    )
    return {"pcap": str(abs_path), "keep": keep, "now": now, **docs}
