#!/usr/bin/env python3
"""
Generate and validate an Elasticsearch ingest pipeline using a local LLM via Ollama.

Strategy:
  1. Header row detection  — if first CSV line looks like column names, use directly (no LLM)
  2. CSV detection         — if lines are consistently delimited, use csv processor + LLM for names
  3. Grok fallback         — for free-form text logs, ask LLM for a Grok pattern

Improvements over naive approach:
  - Temperature 0.2 for CSV (structured output, self-corrects across retries)
  - Auto numeric-type conversion (ports, bytes land as integers in ES)
  - Parsed-output feedback on retry (show LLM what ES actually extracted, not raw error)
  - Per-mode timeout (90s native GPU, 300s Docker CPU)

Usage: python3 scripts/pipeline_generator.py <samples_file> <pipeline_name> [<model>]
Exits 0 and prints pipeline JSON to stdout on success, 1 on failure.
"""

import os
import sys
import json
import re
import time
import urllib.request
import urllib.error
import yaml
from collections import Counter

ES_URL = "http://localhost:9200"
OLLAMA_URL = "http://localhost:11434"
MAX_RETRIES = 3
LLM_TIMEOUT = 300 if os.environ.get("OLLAMA_MODE") == "docker" else 90


# ── Ollama ────────────────────────────────────────────────────────────────────

def _stream_response(resp, tok_key_fn):
    """Stream Ollama API response, return (text, token_count, elapsed_s)."""
    response_text = ""
    token_count = 0
    t0 = time.time()
    deadline = t0 + LLM_TIMEOUT
    print("[pipeline-generator] Generating", end="", flush=True, file=sys.stderr)
    for line in resp:
        if time.time() > deadline:
            print(f" [{token_count} tok] TIMEOUT", file=sys.stderr)
            raise TimeoutError(
                f"LLM did not finish within {LLM_TIMEOUT}s — "
                f"model generated {token_count} tokens"
            )
        chunk = json.loads(line.decode())
        tok = tok_key_fn(chunk)
        response_text += tok
        if tok:
            token_count += 1
            if token_count % 50 == 0:
                print(f" {token_count}", end="", flush=True, file=sys.stderr)
        if chunk.get("done"):
            break
    elapsed = time.time() - t0
    print(f" [{token_count} tok, {elapsed:.1f}s]", file=sys.stderr)
    return response_text.strip()


def ollama_request(payload):
    """Generate API — for Grok (free-form text output)."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/generate",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return _stream_response(resp, lambda c: c.get("response", ""))


def ollama_chat_request(model, user_message, response_prefix="", stop_after_items=None, **options):
    """
    Chat API with optional response priming and early-stop.

    response_prefix: text prepended to assistant turn (forces model to start there).
    stop_after_items: if set, stop streaming once this many JSON array items are seen
                      (prevents model from generating excess 'ignored' entries).
    Returns (prefix + generated_text).
    """
    messages = [{"role": "user", "content": user_message}]
    if response_prefix:
        messages.append({"role": "assistant", "content": response_prefix})
    payload = {"model": model, "messages": messages, "stream": True, "options": options}
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/chat",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    response_text = ""
    token_count = 0
    t0 = time.time()
    deadline = t0 + LLM_TIMEOUT
    print("[pipeline-generator] Generating", end="", flush=True, file=sys.stderr)

    with urllib.request.urlopen(req, timeout=LLM_TIMEOUT + 10) as resp:
        for line in resp:
            if time.time() > deadline:
                print(f" [{token_count} tok] TIMEOUT", file=sys.stderr)
                raise TimeoutError(
                    f"LLM did not finish within {LLM_TIMEOUT}s — "
                    f"model generated {token_count} tokens"
                )
            chunk = json.loads(line.decode())
            tok = chunk.get("message", {}).get("content", "")
            response_text += tok
            if tok:
                token_count += 1
                if token_count % 50 == 0:
                    print(f" {token_count}", end="", flush=True, file=sys.stderr)
            if chunk.get("done"):
                break
            # Early stop: count '",' patterns to estimate items collected
            if stop_after_items and response_text.count('",') + response_text.count('"\\n') >= stop_after_items:
                print(f" [early-stop at ~{stop_after_items} items]", end="", flush=True, file=sys.stderr)
                break

    elapsed = time.time() - t0
    print(f" [{token_count} tok, {elapsed:.1f}s]", file=sys.stderr)
    return response_prefix + response_text.strip()


def unload_model(model):
    """Evict model from VRAM/RAM immediately after inference."""
    try:
        data = json.dumps({"model": model, "keep_alive": 0}).encode()
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/generate",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp.read()
        print("[pipeline-generator] Model unloaded from memory", file=sys.stderr)
    except Exception as e:
        print(f"[pipeline-generator] Warning: could not unload model: {e}", file=sys.stderr)


def detect_model(preferred=None):
    if preferred:
        return preferred
    req = urllib.request.Request(f"{OLLAMA_URL}/api/tags", method="GET")
    with urllib.request.urlopen(req, timeout=10) as resp:
        tags = json.load(resp)
    models = [m["name"] for m in tags.get("models", [])]
    # Best models for log parsing on 16 GB RAM (accuracy vs size sweet spot):
    # 7-8B range: fits in ~5 GB, leaves room for OS + containers
    priority = [
        "qwen2.5-coder:7b",   # best structured output, 4.7 GB
        "qwen3:8b",            # strong reasoning, 5.2 GB
        "qwen3.5",             # good all-rounder
        "llama3.1:8b",         # solid general, 4.9 GB
        "mistral:7b",          # fast, good instruction following, 4.1 GB
        "qwen2.5:7b",          # good at formats/ECS, 4.7 GB
        "gemma3:4b",           # Google, decent structured output, 3.1 GB
        "phi3.5",              # Microsoft, efficient, 2.2 GB
        "qwen2.5-coder:3b",    # fallback
        "llama3.2:3b",
        "qwen2.5:3b",
        "phi3:mini",
        "llama3.2:1b",
    ]
    for p in priority:
        if any(p in m for m in models):
            return next(m for m in models if p in m)
    return models[0] if models else None


# ── CSV detection ─────────────────────────────────────────────────────────────

def detect_csv(sample_lines, min_fields=5, consistency=0.8):
    """Return (sep, num_fields) if lines are consistently delimited, else (None, 0)."""
    for sep in (",", "\t", "|", ";"):
        counts = [len(line.split(sep)) for line in sample_lines if line.strip()]
        if not counts:
            continue
        num_fields, freq = Counter(counts).most_common(1)[0]
        if num_fields >= min_fields and freq / len(counts) >= consistency:
            return sep, num_fields
    return None, 0


def detect_header_row(first_line, sep, num_fields):
    """
    Return cleaned field names if the first line looks like a header row.
    Rejects lines that contain IPs, dates, hex values, or bare integers.
    """
    data_signals = [
        r"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}",  # IP address
        r"\d{4}[/-]\d{2}[/-]\d{2}",               # ISO/slash date
        r"^\d+$",                                   # bare integer
        r"^0x[0-9a-fA-F]+$",                        # hex
    ]
    fields = first_line.split(sep)
    if len(fields) != num_fields:
        return None
    names = []
    for val in fields:
        val = val.strip()
        if not val:
            names.append("ignored")
            continue
        for pat in data_signals:
            if re.search(pat, val):
                return None  # looks like data, not a header
        name = re.sub(r"[^a-z0-9_.]", "", val.lower().replace(" ", "_").replace("-", "_"))
        names.append(name or "ignored")
    return names


# ── Column analysis ───────────────────────────────────────────────────────────

def detect_timestamp_field(field_names, sample_lines, sep):
    """Return (field_name, example_value) for the first timestamp-looking column."""
    date_patterns = [
        r"\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2}",
        r"\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2}",
        r"\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}",
    ]
    for line in sample_lines[:5]:
        cols = line.split(sep)
        for i, val in enumerate(cols):
            if i >= len(field_names):
                break
            val = val.strip()
            if field_names[i] in ("ignored",):
                continue
            for pat in date_patterns:
                if re.search(pat, val):
                    return field_names[i], val
    return None, None


def detect_numeric_columns(field_names, sample_lines, sep):
    """Return dict of field_name -> ES type ('integer'|'float') for purely numeric columns."""
    columns = {i: [] for i in range(len(field_names))}
    for line in sample_lines:
        vals = line.split(sep)
        for i, v in enumerate(vals):
            if i < len(field_names):
                columns[i].append(v.strip())

    # Fields whose names suggest they shouldn't be converted even if values look numeric
    skip_patterns = re.compile(
        r"(ip|address|addr|mac|flags|flag|mask|version|protocol|transport|"
        r"action|status|category|type|name|zone|interface|user|country|"
        r"location|geo|hostname|host|domain|url|path|port_name|service|app)",
        re.IGNORECASE,
    )

    types = {}
    for i, name in enumerate(field_names):
        if name == "ignored" or not columns[i]:
            continue
        if skip_patterns.search(name):
            continue
        non_empty = [v for v in columns[i] if v]
        if not non_empty:
            continue
        try:
            [int(v) for v in non_empty]
            types[name] = "integer"
            continue
        except ValueError:
            pass
        try:
            [float(v) for v in non_empty]
            types[name] = "float"
        except ValueError:
            pass
    return types


def deduplicate_fields(field_names):
    """
    Rename duplicate field names (non-ignored) by appending _2, _3, etc.
    ES csv processor overwrites duplicate target fields — this preserves all data.
    """
    seen = {}
    result = []
    for name in field_names:
        if name == "ignored":
            result.append(name)
            continue
        if name not in seen:
            seen[name] = 1
            result.append(name)
        else:
            seen[name] += 1
            result.append(f"{name}_{seen[name]}")
    return result


# ── Simulate and get parsed output ────────────────────────────────────────────

def simulate_pipeline(pipeline, sample_lines):
    """
    Run ES _simulate. Returns (ok, errors, parsed_samples).
    parsed_samples: list of dicts showing what ES extracted (message field removed).
    """
    docs = [{"_source": {"message": line}} for line in sample_lines[:3]]
    payload = {"pipeline": pipeline, "docs": docs}
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{ES_URL}/_ingest/pipeline/_simulate",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        return False, body, []

    errors, parsed = [], []
    for doc in result.get("docs", []):
        err = doc.get("error") or doc.get("doc", {}).get("_ingest", {}).get("on_failure")
        if err:
            errors.append(str(err))
        src = doc.get("doc", {}).get("_source", {})
        if src.get("parse_error"):
            errors.append(str(src.get("parse_error")))
        src.pop("message", None)
        if src:
            parsed.append(src)

    if errors:
        return False, "; ".join(errors), parsed
    return True, None, parsed


def format_parsed_feedback(parsed_samples):
    """Format parsed output compactly for the retry prompt."""
    if not parsed_samples:
        return "(no parsed output available)"
    lines = []
    for i, doc in enumerate(parsed_samples[:2]):
        lines.append(f"Row {i+1}: " + ", ".join(f"{k}={json.dumps(v)}" for k, v in list(doc.items())[:12]))
    return "\n".join(lines)


# ── CSV pipeline builder ──────────────────────────────────────────────────────

def build_csv_pipeline(field_names, pipeline_name, sep, sample_lines):
    processors = []

    processors.append({
        "csv": {
            "field": "message",
            "target_fields": field_names,
            "separator": sep,
            "ignore_missing": False,
            "trim": True,
            "empty_value": "",
        }
    })

    # Timestamp → @timestamp
    ts_field, ts_example = detect_timestamp_field(field_names, sample_lines, sep)
    if ts_field and ts_field != "ignored":
        if re.match(r"\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}", ts_example):
            fmt = "yyyy/MM/dd HH:mm:ss"
        elif re.match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", ts_example):
            fmt = "ISO8601"
        elif re.match(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", ts_example):
            fmt = "yyyy-MM-dd HH:mm:ss"
        elif re.match(r"\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2}", ts_example):
            fmt = "dd/MMM/yyyy:HH:mm:ss Z"
        else:
            fmt = None
        if fmt:
            processors.append({
                "date": {"field": ts_field, "formats": [fmt],
                         "target_field": "@timestamp", "ignore_failure": True}
            })

    # Numeric type conversion — ports, bytes, counts land as integers not strings
    numeric_cols = detect_numeric_columns(field_names, sample_lines, sep)
    for field, typ in numeric_cols.items():
        processors.append({
            "convert": {"field": field, "type": typ,
                        "ignore_missing": True, "ignore_failure": True}
        })

    # Remove ignored fields (de-duped)
    seen, ignored_unique = set(), []
    for f in field_names:
        if f == "ignored" and f not in seen:
            seen.add(f)
            ignored_unique.append(f)
    if ignored_unique:
        processors.append({"remove": {"field": ignored_unique, "ignore_missing": True}})

    return {
        "description": f"LLM-generated CSV pipeline for {pipeline_name}",
        "processors": processors,
        "on_failure": [{"set": {"field": "error.message", "value": "{{ _ingest.on_failure_message }}"}}],
    }


# ── CSV LLM prompts ───────────────────────────────────────────────────────────

def format_columns(sample_lines, sep, max_rows=3):
    """Show diverse rows — prefer rows with fewest empty fields so the LLM
    sees actual values rather than empty strings for as many columns as possible."""
    candidates = [l.split(sep) for l in sample_lines if l.strip()]
    if not candidates:
        return ""
    # Score rows by number of non-empty fields (higher = more informative)
    scored = sorted(candidates, key=lambda r: sum(1 for v in r if v.strip()), reverse=True)
    rows = scored[:max_rows]
    num_cols = max(len(r) for r in rows)
    lines = []
    for col_idx in range(num_cols):
        vals = [f'"{r[col_idx].strip() if col_idx < len(r) else ""}"' for r in rows]
        lines.append(f"  col {col_idx:>3}: {', '.join(vals)}")
    return "\n".join(lines)


def csv_fields_prompt(sample_lines, num_fields, sep, previous_error=None, parsed_output=None):
    sep_name = {",": "comma", "\t": "tab", "|": "pipe", ";": "semicolon"}.get(sep, sep)
    column_view = format_columns(sample_lines, sep)
    raw_samples = "\n".join(sample_lines[:3])

    prompt = f"""You are an Elasticsearch ingest pipeline expert. Given these log lines, name each column with your best guess.

Sample log lines:
{raw_samples}

The log is {sep_name}-separated with exactly {num_fields} columns (col 0 to col {num_fields - 1}).

Column values from sample rows:
{column_view}

Return a JSON array of exactly {num_fields} field names — one per column, col 0 first.

Rules:
- Use ECS fields where they fit: source.ip, destination.ip, source.port, destination.port, network.transport, network.bytes, event.action, event.outcome, http.request.method, user.name, observer.hostname, rule.name
- For unrecognized fields use descriptive snake_case: log_type, session_id, elapsed_time, receive_time, serial_number
- Each name must be UNIQUE — no duplicates
- "ignored" only for truly empty/placeholder columns
- Return ONLY the JSON array — no explanation, no markdown
- Array MUST have exactly {num_fields} elements"""
    if parsed_output and previous_error:
        prompt += f"""

Previous attempt produced this parsed output:
{parsed_output}

That failed because: {previous_error}
Fix field names where the value clearly does not match the name."""
    elif previous_error:
        prompt += f"\n\nPrevious attempt failed: {previous_error}\nReturn only the corrected JSON array."
    return prompt


def extract_json_array(raw, expected_count):
    text = raw.strip()
    if "```" in text:
        inside, in_block = [], False
        for line in text.split("\n"):
            if line.startswith("```"):
                in_block = not in_block
                continue
            if in_block:
                inside.append(line)
        text = "\n".join(inside).strip()

    # 1. Complete array
    m = re.search(r"\[.*?\]", text, re.DOTALL)
    if m:
        try:
            arr = json.loads(m.group())
            if isinstance(arr, list):
                arr = arr[:expected_count]
                while len(arr) < expected_count:
                    arr.append("ignored")
                return arr
        except json.JSONDecodeError:
            pass

    # 2. Partial array (model hit token limit before closing ']')
    start = text.find("[")
    if start != -1:
        partial = text[start:].rstrip().rstrip(",").rstrip()
        try:
            arr = json.loads(partial + "]")
            if isinstance(arr, list) and arr:
                arr = arr[:expected_count]
                while len(arr) < expected_count:
                    arr.append("ignored")
                return arr
        except json.JSONDecodeError:
            pass

        # 3. Last resort: extract quoted strings from partial text
        strings = re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', text[start:])
        if len(strings) >= expected_count // 2:
            strings = strings[:expected_count]
            while len(strings) < expected_count:
                strings.append("ignored")
            return strings

    return None


# ── Grok pipeline ─────────────────────────────────────────────────────────────

def grok_prompt(sample_lines, previous_error=None, parsed_output=None):
    lines_text = "\n".join(sample_lines)
    prompt = f"""You are an Elasticsearch Grok pattern expert. Generate a single Grok pattern that parses these log lines.

Rules:
- Standard Grok pattern names only: GREEDYDATA, TIMESTAMP_ISO8601, IP, IPORHOST, NUMBER, WORD, NOTSPACE, DATA, URIPATH, QS
- Format: %{{PATTERN_NAME:field_name}} for named captures
- Return ONLY the raw Grok pattern string — no explanation, no markdown, no quotes
- Pattern must match ALL sample lines

Sample lines:
{lines_text}"""
    if parsed_output and previous_error:
        prompt += f"""

Previous attempt produced this parsed output:
{parsed_output}

That failed because: {previous_error}
Fix the pattern so it correctly parses all lines."""
    elif previous_error:
        prompt += f"\n\nPrevious attempt failed: {previous_error}\nReturn only the corrected Grok string."
    prompt += "\n\nGrok pattern:"
    return prompt


def extract_grok_pattern(raw):
    text = raw.strip()
    if "```" in text:
        inside, in_block = [], False
        for line in text.split("\n"):
            if line.startswith("```"):
                in_block = not in_block
                continue
            if in_block:
                inside.append(line)
        text = "\n".join(inside).strip()
    for line in text.split("\n"):
        line = line.strip()
        if "%{" in line:
            return line
    return text.split("\n")[0].strip()


def build_grok_pipeline(pattern, pipeline_name):
    return {
        "description": f"LLM-generated Grok pipeline for {pipeline_name}",
        "processors": [{"grok": {"field": "message", "patterns": [pattern]}}],
        "on_failure": [{"set": {"field": "parse_error", "value": "{{_ingest.on_failure_message}}"}}],
    }


def detect_bracket_app(sample_lines):
    """Detect logs like: [ts] [LEVEL] [service] [trace=id] message"""
    rx = re.compile(r"^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\]]+\]\s+\[[A-Z]+\]\s+\[[^\]]+\]\s+\[trace=[^\]]+\]\s+.+$")
    window = sample_lines[:5] if len(sample_lines) >= 5 else sample_lines
    return bool(window) and all(rx.match(l) for l in window)


def build_bracket_app_pipeline(pipeline_name):
    pattern = (
        r"^\[%{TIMESTAMP_ISO8601:timestamp}\]\s+"
        r"\[%{LOGLEVEL:loglevel}\]\s+"
        r"\[%{DATA:service}\]\s+"
        r"\[trace=%{DATA:trace}\]\s+"
        r"%{GREEDYDATA:app.message}$"
    )
    return {
        "description": f"LLM-generated bracket-app pipeline for {pipeline_name}",
        "processors": [
            {"grok": {"field": "message", "patterns": [pattern]}},
            {
                "date": {
                    "field": "timestamp",
                    "target_field": "@timestamp",
                    "formats": ["ISO8601"],
                    "ignore_failure": True,
                }
            },
        ],
        "on_failure": [{"set": {"field": "parse_error", "value": "{{_ingest.on_failure_message}}"}}],
    }


def detect_kv_lines(sample_lines):
    """Detect timestamp + key=value style lines with mostly consistent shape."""
    if not sample_lines:
        return False
    ts_prefix = 0
    kv_rich = 0
    ts_re = re.compile(r'^\d{4}-\d{2}-\d{2}T\S+\s+')
    for line in sample_lines:
        if ts_re.search(line):
            ts_prefix += 1
        # at least 4 key=value tokens means likely KV app log
        if len(re.findall(r'\b[\w.-]+=\S+', line)) >= 4:
            kv_rich += 1
    need = max(2, int(len(sample_lines) * 0.6))
    return ts_prefix >= need and kv_rich >= need


def build_kv_pipeline(pipeline_name):
    """Build deterministic parser for ISO8601 + whitespace key=value pairs."""
    return {
        "description": f"Deterministic KV pipeline for {pipeline_name}",
        "processors": [
            {"dissect": {"field": "message", "pattern": "%{timestamp} %{kvpairs}"}},
            {"date": {"field": "timestamp", "formats": ["ISO8601"], "ignore_failure": True}},
            {
                "kv": {
                    "field": "kvpairs",
                    "field_split": " ",
                    "value_split": "=",
                    "trim_key": " \t\"",
                    "trim_value": " \t\"",
                    "ignore_failure": True,
                }
            },
            {"remove": {"field": "kvpairs", "ignore_missing": True}},
            {"convert": {"field": "qty", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "priority", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "latency_ms", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "ms", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "tokens_in", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "tokens_out", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "toks_in", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "toks_out", "type": "long", "ignore_failure": True}},
            {"set": {"field": "event.original", "copy_from": "message", "ignore_failure": True}},
        ],
        "on_failure": [{"set": {"field": "parse_error", "value": "{{_ingest.on_failure_message}}"}}],
    }


def detect_evt_kv_lines(sample_lines):
    if not sample_lines:
        return False
    good = 0
    for line in sample_lines:
        if line.startswith("evt=") and len(re.findall(r'\b[\w.-]+=\S+', line)) >= 5:
            good += 1
    return good >= max(2, int(len(sample_lines) * 0.6))


def build_evt_kv_pipeline(pipeline_name):
    return {
        "description": f"Deterministic evt= KV pipeline for {pipeline_name}",
        "processors": [
            {
                "kv": {
                    "field": "message",
                    "field_split": " ",
                    "value_split": "=",
                    "trim_key": " \t\"",
                    "trim_value": " \t\"",
                    "ignore_failure": True,
                }
            },
            {"date": {"field": "evt", "formats": ["ISO8601"], "target_field": "@timestamp", "ignore_failure": True}},
            {"set": {"field": "event.created", "copy_from": "evt", "ignore_failure": True}},
            {"convert": {"field": "ms", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "tokens_in", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "tokens_out", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "toks_in", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "toks_out", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "risk", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "findings", "type": "long", "ignore_failure": True}},
            {"convert": {"field": "files", "type": "long", "ignore_failure": True}},
            {"set": {"field": "event.original", "copy_from": "message", "ignore_failure": True}},
        ],
        "on_failure": [{"set": {"field": "parse_error", "value": "{{_ingest.on_failure_message}}"}}],
    }


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 3:
        print("Usage: pipeline_generator.py <samples_file> <pipeline_name> [<model>]", file=sys.stderr)
        sys.exit(1)

    samples_file = sys.argv[1]
    pipeline_name = sys.argv[2]
    model_hint = sys.argv[3] if len(sys.argv) > 3 else None

    with open(samples_file) as f:
        sample_lines = [l.rstrip() for l in f if l.strip()][:20]

    if not sample_lines:
        print("No sample lines found.", file=sys.stderr)
        sys.exit(1)

    try:
        model = detect_model(model_hint)
    except Exception as e:
        print(f"Cannot reach Ollama: {e}", file=sys.stderr)
        sys.exit(1)

    if not model:
        print("No models available in Ollama.", file=sys.stderr)
        sys.exit(1)

    print(f"[pipeline-generator] Using model: {model} (timeout: {LLM_TIMEOUT}s)", file=sys.stderr)

    # Deterministic fast-path for common app logs with bracket fields.
    if detect_bracket_app(sample_lines):
        print("[pipeline-generator] Detected bracket-app format — using deterministic parser", file=sys.stderr)
        pipeline = build_bracket_app_pipeline(pipeline_name)
        ok, error, _ = simulate_pipeline(pipeline, sample_lines)
        if ok:
            print(yaml.dump(pipeline, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")
            sys.exit(0)
        print(f"[pipeline-generator] Deterministic parser failed: {error} — falling back", file=sys.stderr)

    # Deterministic fast-path for timestamp + key=value app logs.
    if detect_kv_lines(sample_lines):
        print("[pipeline-generator] Detected timestamp KV format — using deterministic parser", file=sys.stderr)
        pipeline = build_kv_pipeline(pipeline_name)
        ok, error, _ = simulate_pipeline(pipeline, sample_lines)
        if ok:
            print(yaml.dump(pipeline, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")
            sys.exit(0)
        print(f"[pipeline-generator] KV parser failed: {error} — falling back", file=sys.stderr)

    if detect_evt_kv_lines(sample_lines):
        print("[pipeline-generator] Detected evt= KV format — using deterministic parser", file=sys.stderr)
        pipeline = build_evt_kv_pipeline(pipeline_name)
        ok, error, _ = simulate_pipeline(pipeline, sample_lines)
        if ok:
            print(yaml.dump(pipeline, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")
            sys.exit(0)
        print(f"[pipeline-generator] evt= KV parser failed: {error} — falling back", file=sys.stderr)

    sep, num_fields = detect_csv(sample_lines)

    if sep:
        sep_name = {",": "CSV", "\t": "TSV", "|": "pipe-delimited", ";": "semicolon-delimited"}.get(sep, "delimited")
        print(f"[pipeline-generator] Detected {sep_name} ({num_fields} fields)", file=sys.stderr)

        # Header row — skip LLM entirely if first line looks like column names
        header_names = detect_header_row(sample_lines[0], sep, num_fields)
        if header_names:
            print("[pipeline-generator] Header row detected — using column names directly (no LLM needed)", file=sys.stderr)
            pipeline = build_csv_pipeline(header_names, pipeline_name, sep, sample_lines[1:])
            ok, error, _ = simulate_pipeline(pipeline, sample_lines[1:])
            if ok:
                print(yaml.dump(pipeline, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")
                sys.exit(0)
            print(f"[pipeline-generator] Header-based pipeline failed: {error} — falling back to LLM", file=sys.stderr)

        last_error = None
        last_parsed = None
        for attempt in range(1, MAX_RETRIES + 1):
            print(f"[pipeline-generator] Attempt {attempt}/{MAX_RETRIES}...", file=sys.stderr)
            prompt = csv_fields_prompt(sample_lines, num_fields, sep, last_error, last_parsed)

            try:
                # Chat API + response priming: force model to start with '[' so it
                # generates the array immediately instead of preamble text.
                # stop_after_items: exit stream once we have enough items — the model
                # tends to keep generating "ignored" entries past num_fields forever.
                raw = ollama_chat_request(
                    model, prompt,
                    response_prefix="[",
                    stop_after_items=num_fields,
                    temperature=0.2,
                    num_predict=1500,
                )
            except Exception as e:
                print(f"[pipeline-generator] LLM request failed: {e}", file=sys.stderr)
                last_error = str(e)
                continue

            field_names = extract_json_array(raw, num_fields)
            if not field_names:
                last_error = "Could not extract a JSON array from LLM response"
                print(f"[pipeline-generator] {last_error}", file=sys.stderr)
                continue

            # Rename duplicate field names (non-ignored) so no data is silently lost
            field_names = deduplicate_fields(field_names)
            print(f"[pipeline-generator] Fields: {field_names}", file=sys.stderr)

            pipeline = build_csv_pipeline(field_names, pipeline_name, sep, sample_lines)

            # Improvement 4: get parsed output for smarter retry feedback
            ok, error, parsed = simulate_pipeline(pipeline, sample_lines)
            if ok:
                unload_model(model)
                print(yaml.dump(pipeline, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")
                sys.exit(0)

            print(f"[pipeline-generator] Validation failed: {error}", file=sys.stderr)
            last_error = error
            last_parsed = format_parsed_feedback(parsed) if parsed else None

    else:
        print("[pipeline-generator] Using Grok pattern approach", file=sys.stderr)

        last_error = None
        last_parsed = None
        for attempt in range(1, MAX_RETRIES + 1):
            print(f"[pipeline-generator] Attempt {attempt}/{MAX_RETRIES}...", file=sys.stderr)
            prompt = grok_prompt(sample_lines, last_error, last_parsed)

            try:
                raw = ollama_request({"model": model, "prompt": prompt, "stream": True,
                                     "options": {"num_predict": 300}})
            except Exception as e:
                print(f"[pipeline-generator] LLM request failed: {e}", file=sys.stderr)
                last_error = str(e)
                continue

            pattern = extract_grok_pattern(raw)
            if not pattern:
                last_error = "Empty pattern returned"
                continue

            print(f"[pipeline-generator] Pattern: {pattern}", file=sys.stderr)
            pipeline = build_grok_pipeline(pattern, pipeline_name)
            ok, error, parsed = simulate_pipeline(pipeline, sample_lines)

            if ok:
                unload_model(model)
                print(yaml.dump(pipeline, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")
                sys.exit(0)

            print(f"[pipeline-generator] Validation failed: {error}", file=sys.stderr)
            last_error = error
            last_parsed = format_parsed_feedback(parsed) if parsed else None

    print(f"[pipeline-generator] Failed after {MAX_RETRIES} attempts.", file=sys.stderr)
    unload_model(model)
    sys.exit(1)


if __name__ == "__main__":
    main()
