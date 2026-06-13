from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from core.settings import repo_root


def _fix_suricata_log_ownership() -> None:
    subprocess.run(
        ["docker", "exec", "suricata", "sh", "-c",
         f"chown {os.getuid()}:{os.getgid()} /var/log/suricata/eve.json /var/log/suricata/suricata.log 2>/dev/null || true"],
        capture_output=True,
    )


def _check_prereqs(interface: str) -> None:
    if not shutil.which("dumpcap"):
        raise RuntimeError("dumpcap not found. Install Wireshark/tshark.")
    if subprocess.run(["dumpcap", "-D"], capture_output=True).returncode != 0:
        uname = ""
        try:
            uname = Path("/proc/version").read_text().lower()
        except Exception:
            pass
        if "microsoft" in uname:
            raise RuntimeError(
                "dumpcap permission denied on WSL. Fix with: "
                "sudo usermod -aG wireshark \"$USER\" && newgrp wireshark"
            )
        raise RuntimeError("dumpcap is not usable by current user. Run 'dumpcap -D' to verify permissions.")
    if subprocess.run(["docker", "exec", "suricata", "true"], capture_output=True).returncode != 0:
        raise RuntimeError("Suricata container not running (use: soc-lab stack start)")


def _reset_session() -> None:
    from core.elastic.client import client as es_client
    es = es_client()
    rows = es.options(ignore_status=[404]).cat.indices(index="suricata-*", format="json", h="index")
    for row in rows or []:
        idx = row.get("index", "")
        if idx:
            es.options(ignore_status=[404]).indices.delete(index=idx)
    for idx in ["elastalert2_alerts", "elastalert2_alerts_status", "elastalert2_alerts_silence"]:
        es.options(ignore_status=[404]).delete_by_query(index=idx, body={"query": {"match_all": {}}})
    subprocess.run(["docker", "restart", "elastalert2"], capture_output=True)
    subprocess.run(
        ["docker", "exec", "suricata", "sh", "-c",
         ": > /var/log/suricata/eve.json; : > /var/log/suricata/suricata.log"],
        capture_output=True,
    )
    _fix_suricata_log_ownership()


def _ensure_alert_aliases() -> None:
    from core.elastic.aliases import ensure_soc_alerts_alias

    ensure_soc_alerts_alias()


def _replay_chunk(name: str, pcap_dir: Path) -> bool:
    result = subprocess.run(
        ["docker", "exec", "suricata", "suricata",
         "-c", "/etc/suricata/suricata.yaml",
         "-r", f"/pcap/live/{name}",
         "--pidfile", "/var/run/suricata-replay.pid",
         "-l", "/var/log/suricata",
         "-k", "none"],
        capture_output=True, text=True,
    )
    _fix_suricata_log_ownership()
    return result.returncode == 0


def _get_doc_counts() -> dict[str, int]:
    try:
        from core.elastic.client import client as es_client
        es = es_client()
        suricata = es.count(index="suricata-*").get("count", 0)
        alerts = es.options(ignore_status=[404]).count(index="soc-alerts").get("count", 0)
        return {"suricata_docs": int(suricata), "soc_alerts_docs": int(alerts)}
    except Exception:
        return {}


def _update_session_stats(docs: dict[str, int]) -> None:
    sessions_file = repo_root() / ".soc-lab" / "capture-live-sessions.json"
    try:
        sessions: list = json.loads(sessions_file.read_text()) if sessions_file.exists() else []
        for s in sessions:
            if s.get("status") == "running":
                s.update(docs)
                break
        sessions_file.write_text(json.dumps(sessions, indent=2))
    except Exception:
        pass


def live(interface: str = "en0", rotation_secs: int = 10, *, keep: bool = False) -> None:
    _check_prereqs(interface)

    pcap_dir = (repo_root() / "data" / "pcap" / "live").resolve()
    pcap_dir_check = (repo_root() / "data" / "pcap" / "live").resolve()
    if str(pcap_dir) != str(pcap_dir_check):
        raise ValueError(f"Unsafe capture path resolved outside repo: {pcap_dir}")

    pcap_dir.mkdir(parents=True, exist_ok=True)
    if not os.access(pcap_dir, os.W_OK):
        raise PermissionError(
            f"Capture directory is not writable: {pcap_dir}. "
            "If it was created by sudo/root, fix it with: "
            f"sudo chown -R {os.getuid()}:{os.getgid()} {pcap_dir}"
        )

    # Clean up previous session files
    for f in pcap_dir.glob("capture_*.pcap"):
        f.unlink(missing_ok=True)
    for f in pcap_dir.glob("capture_*.pcapng"):
        f.unlink(missing_ok=True)
    queue_file = pcap_dir / ".queue"
    played_file = pcap_dir / ".played"
    queue_file.write_text("")
    played_file.write_text("")

    if not keep:
        _reset_session()

    _ensure_alert_aliases()

    queued: set[str] = set()
    played: set[str] = set()

    def enqueue(pcap: Path) -> None:
        name = pcap.name
        if name in played or name in queued:
            return
        if not pcap.exists():
            return
        queued.add(name)
        with open(queue_file, "a") as f:
            f.write(name + "\n")

    def process_one(current_pcap: Path | None) -> bool:
        lines = [ln.strip() for ln in queue_file.read_text().splitlines() if ln.strip()]
        if not lines:
            return False
        name = lines[0]
        pcap = pcap_dir / name
        if not pcap.exists() or pcap == current_pcap:
            return False
        if _replay_chunk(name, pcap_dir):
            played.add(name)
            queued.discard(name)
            with open(played_file, "a") as f:
                f.write(name + "\n")
            # Remove from queue file
            remaining = [ln for ln in lines[1:] if ln]
            queue_file.write_text("\n".join(remaining) + ("\n" if remaining else ""))
            docs = _get_doc_counts()
            if docs:
                _update_session_stats(docs)
            return True
        return False

    capture_proc = subprocess.Popen(
        ["dumpcap", "-q", "-i", interface,
         "-b", f"duration:{rotation_secs}",
         "-b", "files:50",
         "-w", str(pcap_dir / "capture.pcapng")],
    )

    current_pcap: Path | None = None
    backoff = 1

    def _cleanup(signum: int, frame: Any) -> None:
        print("\nStopping live capture...")
        capture_proc.terminate()
        capture_proc.wait()
        # Queue and process the last chunk
        if current_pcap is not None and current_pcap.exists():
            enqueue(current_pcap)
            process_one(None)
        sys.exit(0)

    signal.signal(signal.SIGINT, _cleanup)
    signal.signal(signal.SIGTERM, _cleanup)

    try:
        while capture_proc.poll() is None:
            chunks = sorted(pcap_dir.glob("capture_*.pcapng"), key=lambda p: p.stat().st_mtime)
            if chunks:
                current_pcap = chunks[-1]
                for chunk in chunks[:-1]:
                    enqueue(chunk)

            processed = False
            while True:
                if current_pcap is None:
                    break
                if not process_one(current_pcap):
                    break
                processed = True
                backoff = 1

            remaining = [ln.strip() for ln in queue_file.read_text().splitlines() if ln.strip()]
            if remaining and not processed:
                time.sleep(backoff)
                backoff = min(backoff * 2, 10)
            else:
                time.sleep(2)
    except KeyboardInterrupt:
        _cleanup(signal.SIGINT, None)
    finally:
        if capture_proc.poll() is None:
            capture_proc.terminate()
            capture_proc.wait()
