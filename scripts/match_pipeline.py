#!/usr/bin/env python3
"""
Match sample log lines to the best Elasticsearch ingest pipeline.

Algorithm:
  Phase 1 — Structural hints (regex on sample) → per-keyword boost scores.
             When hints fire, only hint-matched pipelines are scored.
             When no hints fire, all pipelines score but need a higher threshold.
  Phase 2 — Grok pre-score: simplified regex test of each pipeline's grok
             patterns against sample lines. Fast local filter before ES calls.
  Phase 3 — ES inline _simulate: runs the actual pipeline YAML against sample
             docs in ES. Scores by fields_extracted × success_rate.
             Two preprocessing steps make this work for Elastic integration pkgs:
               a) inject missing grok pattern definitions (GREEDYMULTILINE etc.)
               b) strip Fleet EPM template sub-pipeline refs {{ IngestPipeline }}
             The pipeline that extracts the most meaningful fields wins.

Usage:
  head -20 <logfile> | python3 match_pipeline.py <pipelines_dir> [<es_url>] [<top_n>]

Exits 0 and prints pipeline stem name on match; exits 1 on no match.
"""
import sys, os, re, json, copy, yaml
import urllib.request, urllib.error, urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

ES_URL  = "http://localhost:9200"
TOP_N   = 4
SIM_DOCS = 5

SIP_TOKENS = (
    "SIP/2.0", "INVITE ", "REGISTER ", "BYE ", "CANCEL ", "ACK ",
    "Via: SIP", "From: <sip:", "To: <sip:", "Call-ID:", "CSeq:",
)

# ── Structural hints ──────────────────────────────────────────────────────────
HINTS = [
    # Web servers — separate tomcat from generic HTTP since CLF is identical
    (r'"(?:GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH) .*HTTP/\d',   ['apache-access', 'nginx-access', 'iis-access'], 8),
    (r'Catalina\.|catalina\.out|tomcat',                          ['apache_tomcat'],                               9),
    # Firewalls / network gear
    (r'\bfilterlog\[\d+\]',                                       ['pfsense'],                                    10),
    (r'%ASA-\d+-\d+:',                                            ['cisco_asa'],                                  10),
    (r'%FTD-\d+-\d+:',                                            ['cisco_asa', 'cisco_ftd'],                     10),
    (r'%FWSM-\d+-\d+:',                                           ['cisco_asa'],                                  10),
    (r'\bdevid="?[A-Z0-9]+"?\b.*\btype=(?:traffic|utm)\b',       ['fortinet_fortigate-log'],                     10),
    (r'\blogid=\d+\b.*\btype=traffic\b',                          ['fortinet_fortigate-log'],                      9),
    (r'product="(?:FireWall|VPN)',                                 ['checkpoint-firewall'],                        10),
    (r'^1,\d{4}/\d{2}/\d{2}.*,(?:TRAFFIC|THREAT|SYSTEM|CONFIG),',['panw'],                                       10),
    # Cloud / infra
    (r'^\d+ \d{12} eni-[a-z0-9]+',                               ['aws-vpcflow'],                                10),
    (r'"eventVersion"\s*:\s*"',                                   ['cloudtrail'],                                  10),
    (r'\bvpc_id\b.*\bsubnet_id\b|\bproject_id\b.*\binstance_id\b',['gcp.*vpcflow'],                               8),
    # IDS / proxy
    (r'"event_type"\s*:\s*"(?:alert|flow|dns|http|tls|smtp|ssh)',  ['suricata-eve'],                              10),
    (r'^\d{10}\.\d{3}\s+\d+\s+\d{1,3}\.\d{1,3}',                ['squid-log'],                                   8),
    # Zeek
    (r'^#(?:separator|fields|path|types)\t',                      ['zeek'],                                       10),
    (r'"id\.orig_h"\s*:\s*"[^"]+".*"id\.resp_h"\s*:\s*"[^"]+".*"query"\s*:\s*"',
                                                                   ['zeek-dns'],                                   10),
    # Syslog
    (r'^\w{3}\s{1,2}\d{1,2} \d{2}:\d{2}:\d{2} \S+ \S+[\[:]',    ['system-syslog', 'syslog'],                    5),
    (r'^<\d+>(?:\d+ )?\d{4}-\d{2}-\d{2}T',                       ['system-syslog', 'syslog'],                    5),
    # Windows
    (r'"EventID":|"TimeCreated":',                                ['windows', 'winlogbeat'],                       8),
    (r'\bMSWINEVENTLOG\b|\bWinEvtLog\b',                         ['windows'],                                     8),
    # Misc
    (r'\b(?:ACCEPT|REJECT|DROP)\b.*\b(?:TCP|UDP|ICMP)\b',        ['iptables', 'ufw'],                             6),
    (r'"eventSource"\s*:\s*"[^"]+\.amazonaws\.com"',              ['cloudtrail'],                                  9),
    (r'\bkubernetes\.io\b|\bkubernetes\b.*\bnamespace\b',         ['kubernetes'],                                  7),
    (r'#Software: Microsoft Internet Information',                 ['iis'],                                        10),
    (r'^#Fields:\s+date\s+time\s+s-ip\s+cs-method\s+cs-uri-stem',
                                                                   ['iis-access'],                                 10),
    # App-style bracket logs: prefer no forced generic integration match
    (r'^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\]]+\]\s+\[[A-Z]+\]\s+\[[^\]]+\]\s+\[trace=',
                                                                    ['__custom_app__'],                              9),
    (r'^ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\s]+\s+lvl=[A-Z]+\s+svc=\S+\s+trace=',
                                                                    ['__custom_app__'],                              9),
    (r'^evt=[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\s]+\s+level=[A-Z]+\s+svc=\S+\s+trace=',
                                                                    ['__custom_app__'],                              9),
    (r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\s]+\s+node=\S+\s+svc=\S+\s+event=\S+\s+src=',
                                                                    ['__custom_app__'],                              9),
    (r'^HPOT\|ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[^|]+\|sensor=\S+\|evt=\S+\|src=',
                                                                    ['__custom_app__'],                              10),
    (r'^(?:[A-Za-z0-9_.-]+=\S+[\s,;|]){3,}[A-Za-z0-9_.-]+=\S+',
                                                                    ['__custom_app__'],                               9),
    (r'^[A-Z]+\|ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[^|]+\|',
                                                                    ['__custom_app__'],                              10),
    (r'^@MF\s+EVT=[A-Z]+\s+TS=\d{8}-\d{6}\b',
                                                                    ['__custom_app__'],                              10),
    (r'^<PRI=\d+>\s+\w+@\S+\s+ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T',
                                                                    ['__custom_app__'],                              10),
]

# Pattern names not in ES 8 built-ins but used by Elastic integration pipelines.
# Injected into grok pattern_definitions before inline simulate so grok can compile.
_INJECT_PATTERNS = {
    "GREEDYMULTILINE":  r"(.|\n)*",
    "JAVACLASS":        r"(?:[a-zA-Z$_][a-zA-Z$_0-9]*\.)*[a-zA-Z$_][a-zA-Z$_0-9]*",
    "JAVALOGMESSAGE":   r".*",
    "WORD_":            r"\w+",
}

# ── Pipeline YAML preprocessing for inline simulate ───────────────────────────

def _patch_processors(processors):
    """
    Recursively preprocess processors for inline simulate:
      1. Inject missing grok pattern definitions.
      2. Strip Fleet EPM template sub-pipeline refs ({{ IngestPipeline "..." }}).
    Returns a new list (does not mutate input).
    """
    if not isinstance(processors, list):
        return processors
    result = []
    for proc in processors:
        if not isinstance(proc, dict):
            continue
        ptype = list(proc.keys())[0]
        pdata = proc[ptype]

        # Drop EPM template pipeline references — they fail in inline simulate
        if ptype == "pipeline" and isinstance(pdata, dict):
            if "{{" in str(pdata.get("name", "")):
                continue

        pdata = copy.deepcopy(pdata) if isinstance(pdata, dict) else pdata
        if isinstance(pdata, dict):
            # Inject missing grok patterns
            if ptype == "grok":
                pd = pdata.setdefault("pattern_definitions", {})
                for k, v in _INJECT_PATTERNS.items():
                    pd.setdefault(k, v)
            # Recurse into nested processor lists
            for key in ("processors", "on_failure"):
                if key in pdata:
                    pdata[key] = _patch_processors(pdata[key])

        result.append({ptype: pdata})
    return result


# ── Grok pre-score helpers ────────────────────────────────────────────────────
_GROK = {
    'IP': r'(?:\d{1,3}\.){3}\d{1,3}', 'IPV6': r'[0-9a-fA-F:]+',
    'IPORHOST': r'\S+', 'HOSTNAME': r'\S+', 'HOST': r'\S+',
    'NUMBER': r'\d+(?:\.\d+)?', 'POSINT': r'\d+', 'NONNEGINT': r'\d+',
    'WORD': r'\w+', 'DATA': r'.*?', 'GREEDYDATA': r'.*',
    'NOTSPACE': r'\S+', 'SPACE': r'\s+',
    'QS': r'"[^"]*"', 'QUOTEDSTRING': r'"[^"]*"',
    'HTTPDATE': r'\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4}',
    'TIMESTAMP_ISO8601': r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}',
    'TIME': r'\d{2}:\d{2}:\d{2}', 'INT': r'[+-]?\d+',
    'BASE16NUM': r'[0-9a-fA-F]+', 'UUID': r'[0-9a-fA-F-]{36}',
    'PATH': r'/\S*', 'URI': r'\S+', 'URIPATH': r'/\S*',
    'LOGLEVEL': r'\w+', 'PROG': r'[\w._/-]+',
    'SYSLOGPROG': r'[\w._/-]+(?:\[\d+\])?',
    'SYSLOGTIMESTAMP': r'\w{3}\s+\d{1,2}\s\d{2}:\d{2}:\d{2}',
    'SYSLOGHOST': r'\S+',
    'MONTHDAY': r'\d{1,2}', 'MONTH': r'\w{3}', 'YEAR': r'\d{4}',
    'ADDRESS_LIST': r'[\d., ]+',
    'GREEDYMULTILINE': r'.*',  # local approximation
}

def _grok_to_re(pattern):
    return re.sub(r'%\{([A-Z0-9_]+)(?::[^}]*)?\}',
                  lambda m: _GROK.get(m.group(1), r'\S+'), pattern)

def _extract_grok(processors, depth=0):
    if depth > 5:
        return []
    out = []
    for proc in (processors or []):
        if not isinstance(proc, dict):
            continue
        ptype = list(proc.keys())[0]
        pdata = proc[ptype]
        if not isinstance(pdata, dict):
            continue
        if ptype == 'grok':
            out.extend(pdata.get('patterns', []))
        for key in ('processors', 'on_failure'):
            out.extend(_extract_grok(pdata.get(key, []), depth + 1))
    return out

def _grok_rate(patterns, lines):
    best = 0.0
    for pat in patterns[:5]:
        try:
            rx = re.compile(_grok_to_re(pat), re.DOTALL)
            rate = sum(1 for l in lines if rx.search(l)) / len(lines)
            best = max(best, rate)
            if best >= 0.9:
                break
        except re.error:
            continue
    return best


# ── ES inline _simulate ───────────────────────────────────────────────────────
# Top-level keys always present regardless of parsing — don't count toward score
_BOILERPLATE = {"message", "@timestamp", "ecs", "_tmp", "_temp_", "tags", "error"}

def _simulate_inline(pipeline_path, sample_lines, es_url):
    """
    Simulate using preprocessed inline pipeline definition.
    Returns dict metrics for ranking, or None.
    """
    try:
        with open(pipeline_path) as f:
            pipeline_def = yaml.safe_load(f)
        if not isinstance(pipeline_def, dict):
            return None
    except Exception:
        return None

    # Preprocess: inject missing patterns + strip EPM template refs
    pipeline_def = dict(pipeline_def)
    pipeline_def["processors"] = _patch_processors(pipeline_def.get("processors", []))

    docs = [{"_source": {"message": l}} for l in sample_lines[:SIM_DOCS]]
    payload = json.dumps({"pipeline": pipeline_def, "docs": docs}).encode()
    url = f"{es_url}/_ingest/pipeline/_simulate"
    req = urllib.request.Request(url, data=payload,
                                 headers={"Content-Type": "application/json"},
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.load(resp)
    except Exception:
        return None

    all_docs = [d for d in result.get("docs", []) if isinstance(d, dict)]
    if not all_docs:
        return None

    total  = len(all_docs)
    errors = sum(1 for d in all_docs if "error" in d)
    good   = [d for d in all_docs if "error" not in d]
    if not good:
        return {"score": 0.0, "success_rate": 0.0, "errors": errors, "avg_fields": 0.0}

    avg_fields = sum(
        len([k for k in d.get("doc", {}).get("_source", {}).keys()
             if k not in _BOILERPLATE])
        for d in good
    ) / len(good)

    success_rate = (total - errors) / total
    return {
        "score": avg_fields * success_rate,
        "success_rate": success_rate,
        "errors": errors,
        "avg_fields": avg_fields,
    }


def _is_sip_like(sample_lines):
    text = "\n".join(sample_lines).upper()
    return any(tok.upper() in text for tok in SIP_TOKENS)


def _name_penalty(name, sample_lines):
    """Return numeric penalty for known over-broad mismatches."""
    n = name.lower().replace("_", "-")
    penalty = 0.0
    if "zeek-sip" in n and not _is_sip_like(sample_lines):
        penalty += 3.0
    return penalty


def _disallow_candidate(name, sample_lines):
    n = name.lower().replace("_", "-")
    if "zeek-sip" in n and not _is_sip_like(sample_lines):
        return True
    return False


def _accept_match(sim, has_hints):
    """Confidence gate to avoid false-positive pipeline picks."""
    score = sim.get("score", 0.0)
    rate = sim.get("success_rate", 0.0)
    avgf = sim.get("avg_fields", 0.0)
    errs = sim.get("errors", 999)

    min_score = 0.75 if has_hints else 2.5
    if score < min_score:
        return False
    if rate < 0.60:
        return False
    if avgf < 1.0:
        return False
    if errs > max(1, int(SIM_DOCS * 0.4)):
        return False
    return True


# ── Simulate a set of candidates and return (name, score) sorted best-first ───
def _run_simulate(candidates, sample, es_url):
    """candidates: list of (name, fpath). Returns {name: score}."""
    sim_results = {}
    with ThreadPoolExecutor(max_workers=min(8, len(candidates))) as pool:
        futures = {
            pool.submit(_simulate_inline, fpath, sample, es_url): name
            for name, fpath in candidates
        }
        for fut in as_completed(futures):
            name = futures[fut]
            score = fut.result()
            if score is not None:
                sim_results[name] = score
    return sim_results


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    # Optional --prefix <filter>: skip hints, only simulate prefix-matching pipelines
    args = sys.argv[1:]
    prefix_filter = None
    if "--prefix" in args:
        idx = args.index("--prefix")
        prefix_filter = args[idx + 1].lower()
        args = args[:idx] + args[idx + 2:]

    pipelines_dir = args[0] if len(args) > 0 else "."
    es_url        = args[1] if len(args) > 1 else ES_URL
    top_n         = int(args[2]) if len(args) > 2 else TOP_N

    sample = [l.rstrip() for l in sys.stdin if l.strip()][:20]
    if not sample:
        sys.exit(1)

    if prefix_filter:
        # ── Prefix mode: grep pipeline dir, simulate all matches ─────────────
        # Split filter into tokens so "zeek-dns" matches "zeek-dns.yml" and
        # "zeek" alone matches all zeek-*.yml files.
        tokens = [t for t in re.split(r'[-_.]', prefix_filter) if t]
        candidates = []
        for fname in sorted(os.listdir(pipelines_dir)):
            if not fname.endswith(".yml"):
                continue
            name     = fname[:-4]
            name_low = name.lower().replace("_", "-")
            # Include if the full normalized filter is a substring, or all tokens match
            if prefix_filter in name_low or all(t in name_low for t in tokens):
                candidates.append((name, os.path.join(pipelines_dir, fname)))

        if not candidates:
            sys.exit(1)

        if len(candidates) == 1:
            print(candidates[0][0])
            sys.exit(0)

        # Prefix mode pre-score (same spirit as auto mode): hints + grok rate.
        sample_text = "\n".join(sample)
        kw_boost = {}
        for pattern, keywords, boost in HINTS:
            if re.search(pattern, sample_text, re.MULTILINE | re.IGNORECASE):
                for kw in keywords:
                    kw_boost[kw] = max(kw_boost.get(kw, 0), boost)

        prefix_scored = []  # (score, name)
        for name, fpath in candidates:
            if _disallow_candidate(name, sample):
                continue
            boost = 0
            for kw, bv in kw_boost.items():
                try:
                    if re.search(kw, name, re.IGNORECASE):
                        boost = max(boost, bv)
                except re.error:
                    if kw in name:
                        boost = max(boost, bv)

            rate = 0.0
            try:
                with open(fpath) as f:
                    d = yaml.safe_load(f)
                if isinstance(d, dict):
                    pats = _extract_grok(d.get("processors", []))
                    rate = _grok_rate(pats, sample) if pats else 0.0
            except Exception:
                pass

            prefix_scored.append((rate * 10 + boost * 0.5, name))

        prefix_scored.sort(reverse=True)
        pre_rank = {name: i for i, (_, name) in enumerate(prefix_scored)}

        sim_results = _run_simulate(candidates, sample, es_url)

        if sim_results and any(v.get("score", 0) > 0 for v in sim_results.values()):
            best = max(sim_results,
                       key=lambda n: (sim_results[n].get("score", 0) - _name_penalty(n, sample), -sim_results[n].get("errors", 999), -pre_rank.get(n, 999)))
            if _accept_match(sim_results[best], has_hints=True):
                print(best)
                sys.exit(0)

        # Fallback: highest pre-score within the family.
        if prefix_scored:
            print(prefix_scored[0][1])
            sys.exit(0)

        # Final fallback: alphabetical first (candidates already sorted)
        print(candidates[0][0])
        sys.exit(0)

    # ── Auto mode: full 3-phase matching ─────────────────────────────────────
    sample_text = "\n".join(sample)

    # Phase 1: structural hints → keyword → max boost
    kw_boost = {}
    for pattern, keywords, boost in HINTS:
        if re.search(pattern, sample_text, re.MULTILINE | re.IGNORECASE):
            for kw in keywords:
                kw_boost[kw] = max(kw_boost.get(kw, 0), boost)

    has_hints = bool(kw_boost)

    # Phase 2: grok pre-score + hint boost → candidate list
    scored = []  # (total_score, name, file_path)
    for fname in os.listdir(pipelines_dir):
        if not fname.endswith(".yml"):
            continue
        name = fname[:-4]
        if _disallow_candidate(name, sample):
            continue

        boost = 0
        for kw, bv in kw_boost.items():
            try:
                if re.search(kw, name, re.IGNORECASE):
                    boost = max(boost, bv)
            except re.error:
                if kw in name:
                    boost = max(boost, bv)

        if has_hints and boost == 0:
            continue  # only consider hint-matched pipelines when hints fired

        fpath = os.path.join(pipelines_dir, fname)
        try:
            with open(fpath) as f:
                d = yaml.safe_load(f)
            if not isinstance(d, dict):
                continue
            patterns = _extract_grok(d.get("processors", []))
            rate = _grok_rate(patterns, sample) if patterns else 0.0
            total = rate * 10 + boost * 0.5
            if total > 0:
                scored.append((total, name, fpath))
        except Exception:
            continue

    if not scored:
        sys.exit(1)

    scored.sort(reverse=True)
    candidates = [(name, fpath) for _, name, fpath in scored[:top_n]]

    # Phase 3: inline ES _simulate — the authoritative validator
    sim_results = _run_simulate(candidates, sample, es_url)

    # Tie-break by pre-score rank when simulate scores are equal
    prescore_rank = {name: i for i, (_, name, _) in enumerate(scored)}
    if sim_results and any(v.get("score", 0) > 0 for v in sim_results.values()):
        ranking = sorted(
            sim_results.keys(),
            key=lambda n: (
                sim_results[n].get("score", 0) - _name_penalty(n, sample),
                -sim_results[n].get("errors", 999),
                -prescore_rank.get(n, 999),
            ),
            reverse=True,
        )
        best = ranking[0]
        best_adj = sim_results[best].get("score", 0) - _name_penalty(best, sample)
        second_adj = sim_results[ranking[1]].get("score", 0) - _name_penalty(ranking[1], sample) if len(ranking) > 1 else -999
        margin = best_adj - second_adj
        if _accept_match(sim_results[best], has_hints) and margin >= 0.35:
            print(best)
            sys.exit(0)

    # Fallback: grok+hint score when simulate can't discriminate
    best_score, best_name, _ = scored[0]
    threshold = 4.0 if has_hints else 9.0
    if best_score >= threshold:
        print(best_name)
        sys.exit(0)

    sys.exit(1)


if __name__ == "__main__":
    main()
