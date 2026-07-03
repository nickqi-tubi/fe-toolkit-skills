#!/usr/bin/env bash
#
# query_web_vitals.sh - read core_dev.dsa.perf_web_vitals_daily via the
# Databricks CLI and return ranked / trended P75 Web Vitals rows.
#
# The Google Search Console Core Web Vitals report classifies URL groups by
# field-data P75, so this script ranks by P75 (not p50). The daily table stores
# one P75 per (ts, platform, device_type, metric_type, dimension_key); a true
# period P75 cannot be recovered from daily P75s, so the window aggregation uses
# a sample_count-weighted mean of the daily P75 as a documented approximation.
#
# Usage:
#   query_web_vitals.sh [--mode rank|trend] [--metric LCP|INP|CLS|FCP|TTFB]
#                       [--device mobile|desktop] [--route <ROUTE_ID>]
#                       [--days N] [--min-samples N] [--warehouse <id>]
#                       [--profile <name>] [--format tsv|json]
#
#   --mode    rank  (default) ranked targets over the window.
#             trend daily P75 + sample_count series (needs --metric, --device,
#                   --route) for before/after baselining.
#   --metric  filter to one metric_type (rank mode: optional; trend: required).
#   --device  filter to mobile|desktop (trend: required).
#   --route   filter to one ROUTE_ID / dimension_key (trend: required).
#   --days    look-back window in days (default 28 = 4 weekly-release cycles
#             and a multiple of 7 to cancel day-of-week seasonality; the data
#             is our own telemetry, so this is not tied to any GSC window).
#   --min-samples  rank mode: cumulative cold-navigate samples over the window
#             below which a cohort's weighted P75 is too noisy to trust as a
#             ranking signal, so it is flagged confidence=low (default 10000).
#             This is a ranking-reliability floor, not an experiment-runtime
#             estimate - whether a specific chosen target has enough daily
#             volume to reach a fast experiment verdict is judged later, with
#             full context, by the Step 3.5 "Traffic sufficiency" review.
#   --warehouse  SQL warehouse id; default = first RUNNING warehouse.
#   --profile Databricks CLI profile whose host is
#             https://tubi-dev.cloud.databricks.com. Default: auto-resolved by
#             host from `databricks auth profiles --output json`. Fails closed if
#             no profile matches that host.
#   --format  tsv (default, tab-separated with header) or json.
#
# Exit codes:
#   0 success            2 bad usage
#   3 no running warehouse / databricks CLI unusable / no tubi-dev profile
#   4 query failed
#
# Notes:
#   - rank mode skips the null device_type bucket; mobile and desktop are the
#     actionable, separately-implemented cohorts.
#   - rank score = max((w_p75 - good_threshold)/good_threshold, 0) * total_samples
#     so it is comparable across metrics with different units.
#   - rank mode adds a `confidence` column (ok|low): low means total_samples
#     over the window is under --min-samples, so the weighted P75 itself is
#     too noisy to rank on. It does not say anything about experiment
#     runtime for a chosen target - that judgment belongs to Step 3.5.

set -euo pipefail

TABLE="core_dev.dsa.perf_web_vitals_daily"

mode="rank"
metric=""
device=""
route=""
days="28"
warehouse=""
profile=""
format="tsv"
# Cumulative cold-navigate samples (over the window) below which a ranked
# cohort's weighted P75 is too noisy to trust as a ranking signal; such rows
# are flagged confidence=low. This is a ranking-reliability floor, not an
# experiment-runtime estimate (see Step 3.5 "Traffic sufficiency" for that).
min_samples="10000"

TUBI_DEV_HOST="https://tubi-dev.cloud.databricks.com"

die() { printf 'query_web_vitals.sh: %s\n' "$1" >&2; exit "${2:-2}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)      mode="${2:-}"; shift 2 ;;
    --metric)    metric="${2:-}"; shift 2 ;;
    --device)    device="${2:-}"; shift 2 ;;
    --route)     route="${2:-}"; shift 2 ;;
    --days)      days="${2:-}"; shift 2 ;;
    --min-samples) min_samples="${2:-}"; shift 2 ;;
    --warehouse) warehouse="${2:-}"; shift 2 ;;
    --profile)   profile="${2:-}"; shift 2 ;;
    --format)    format="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,54p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$mode" in rank|trend) ;; *) die "invalid --mode '$mode'" 2 ;; esac
case "$format" in tsv|json) ;; *) die "invalid --format '$format'" 2 ;; esac
[[ "$days" =~ ^[0-9]+$ ]] || die "--days must be a positive integer" 2
[[ "$min_samples" =~ ^[0-9]+$ ]] || die "--min-samples must be a non-negative integer" 2

command -v databricks >/dev/null 2>&1 || die "databricks CLI not found; install it and run 'databricks auth login --host ${TUBI_DEV_HOST}'" 3
command -v python3 >/dev/null 2>&1 || die "python3 not found (needed to build/parse the request)" 3

# --- resolve a Databricks CLI profile bound to the tubi-dev workspace --------
# The CLI otherwise falls back to the default profile / DATABRICKS_* env vars,
# which may point at a different workspace even after /fe-toolkit:auth reports
# tubi-dev healthy. Match by host, not by profile name (name is user-chosen);
# fail closed if nothing matches. Explicit --profile is also host-validated —
# a manually-passed profile is still refused if it does not point at tubi-dev.
profile="$(TUBI_DEV_HOST="$TUBI_DEV_HOST" REQ_PROFILE="$profile" python3 - <<'PY' 2>/dev/null
import json, os, subprocess, sys
target = os.environ["TUBI_DEV_HOST"].rstrip("/")
requested = os.environ.get("REQ_PROFILE") or ""
out = subprocess.run(
    ["databricks", "auth", "profiles", "--output", "json"],
    capture_output=True, text=True,
)
if out.returncode != 0:
    sys.exit(1)
try:
    profiles = json.loads(out.stdout).get("profiles", []) or []
except json.JSONDecodeError:
    sys.exit(1)
candidates = [
    p for p in profiles
    if p.get("host", "").rstrip("/") == target and p.get("valid")
]
if requested:
    for p in candidates:
        if p.get("name") == requested:
            print(p["name"])
            sys.exit(0)
    sys.exit(2)  # explicit profile does not match tubi-dev host or is invalid
elif candidates:
    print(candidates[0]["name"])
PY
)" || true

if [[ -z "$profile" ]]; then
  die "no valid Databricks CLI profile for ${TUBI_DEV_HOST}; run: databricks auth login --host ${TUBI_DEV_HOST}" 3
fi

# Uppercase metric, lowercase device, for forgiving input.
metric="$(printf '%s' "$metric" | tr '[:lower:]' '[:upper:]')"
device="$(printf '%s' "$device" | tr '[:upper:]' '[:lower:]')"

if [[ -n "$metric" ]]; then
  case "$metric" in LCP|INP|CLS|FCP|TTFB) ;; *) die "invalid --metric '$metric'" 2 ;; esac
fi
if [[ -n "$device" ]]; then
  case "$device" in mobile|desktop) ;; *) die "invalid --device '$device'" 2 ;; esac
fi
# A ROUTE_ID is an alphanumeric token (H, MD, TS1, OTH, ...). Reject anything
# else: --route is interpolated into the SQL string, so an unvalidated value
# (e.g. "H' OR 1=1 --") would be a SQL-injection vector.
if [[ -n "$route" ]]; then
  [[ "$route" =~ ^[A-Za-z0-9]+$ ]] || die "invalid --route '$route' (expected an alphanumeric ROUTE_ID)" 2
fi

if [[ "$mode" == "trend" ]]; then
  [[ -n "$metric" && -n "$device" && -n "$route" ]] \
    || die "trend mode requires --metric, --device and --route" 2
fi

# --- resolve a RUNNING warehouse -------------------------------------------
if [[ -z "$warehouse" ]]; then
  warehouse="$(databricks warehouses list -p "$profile" 2>/dev/null \
    | awk 'NR>1 && $NF=="RUNNING" {print $1; exit}')"
  [[ -n "$warehouse" ]] || die "no RUNNING SQL warehouse found on profile '$profile'; pass --warehouse <id> or start one in Databricks" 3
fi

# --- build SQL --------------------------------------------------------------
filters="platform = 'web' AND ts >= date_sub(current_date(), ${days})"
[[ -n "$metric" ]] && filters="${filters} AND metric_type = '${metric}'"
[[ -n "$device" ]] && filters="${filters} AND device_type = '${device}'"
[[ -n "$route"  ]] && filters="${filters} AND dimension_key = '${route}'"

if [[ "$mode" == "rank" ]]; then
  sql="WITH win AS (
  SELECT device_type, metric_type, dimension_key, p75, sample_count
  FROM ${TABLE}
  WHERE ${filters} AND device_type IN ('mobile','desktop')
),
agg AS (
  SELECT device_type, metric_type, dimension_key,
         SUM(p75 * sample_count) / NULLIF(SUM(sample_count), 0) AS w_p75,
         SUM(sample_count) AS total_samples,
         COUNT(*) AS days_present
  FROM win
  GROUP BY device_type, metric_type, dimension_key
),
scored AS (
  SELECT *,
    CASE metric_type WHEN 'LCP' THEN 2500 WHEN 'INP' THEN 200 WHEN 'CLS' THEN 0.1
                     WHEN 'FCP' THEN 1800 WHEN 'TTFB' THEN 800 END AS good_thr,
    CASE metric_type WHEN 'LCP' THEN 4000 WHEN 'INP' THEN 500 WHEN 'CLS' THEN 0.25
                     WHEN 'FCP' THEN 3000 WHEN 'TTFB' THEN 1800 END AS poor_thr
  FROM agg
)
SELECT device_type, metric_type, dimension_key,
       ROUND(w_p75, 3) AS w_p75,
       total_samples, days_present,
       CASE WHEN w_p75 <= good_thr THEN 'good'
            WHEN w_p75 <= poor_thr THEN 'needs-improvement'
            ELSE 'poor' END AS status,
       ROUND(GREATEST((w_p75 - good_thr) / good_thr, 0) * total_samples, 1) AS score,
       CASE WHEN total_samples < ${min_samples} THEN 'low' ELSE 'ok' END AS confidence
FROM scored
ORDER BY score DESC, total_samples DESC
LIMIT 200"
else
  sql="SELECT ts, device_type, metric_type, dimension_key,
       ROUND(p75, 3) AS p75, sample_count
FROM ${TABLE}
WHERE ${filters}
ORDER BY ts"
fi

# --- submit + poll ----------------------------------------------------------
# Use temp files (not pipes) to hand data to the inline python: `python3 -`
# reads its *script* from stdin via the heredoc, so stdin cannot also carry
# data. argv file paths sidestep that entirely.
payload_file="$(mktemp -t wvq_req.XXXXXX.json)"
resp_file="$(mktemp -t wvq_resp.XXXXXX.json)"
trap 'rm -f "$payload_file" "$resp_file"' EXIT

WAREHOUSE_ID="$warehouse" SQL_TEXT="$sql" python3 - "$payload_file" <<'PY'
import json, os, sys
json.dump({
    "warehouse_id": os.environ["WAREHOUSE_ID"],
    "statement": os.environ["SQL_TEXT"],
    "wait_timeout": "50s",
    "on_wait_timeout": "CONTINUE",
    "disposition": "INLINE",
    "format": "JSON_ARRAY",
}, open(sys.argv[1], "w"))
PY

databricks api post -p "$profile" /api/2.0/sql/statements --json "@${payload_file}" > "$resp_file" 2>/dev/null \
  || die "statement submit failed (databricks api post returned non-zero)" 4

# Poll in place until the statement reaches a terminal state.
DATABRICKS_PROFILE="$profile" python3 - "$resp_file" <<'PY'
import json, os, subprocess, sys, time
f = sys.argv[1]
profile = os.environ["DATABRICKS_PROFILE"]
resp = json.load(open(f))

def state(r): return r.get("status", {}).get("state", "")

sid = resp.get("statement_id")
deadline = time.time() + 180
while state(resp) in ("PENDING", "RUNNING") and sid and time.time() < deadline:
    time.sleep(2)
    out = subprocess.run(
        ["databricks", "api", "get", "-p", profile, f"/api/2.0/sql/statements/{sid}"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        break
    resp = json.loads(out.stdout)

json.dump(resp, open(f, "w"))
PY

# --- format output ----------------------------------------------------------
FMT="$format" python3 - "$resp_file" <<'PY'
import json, os, sys
resp = json.load(open(sys.argv[1]))
st = resp.get("status", {}).get("state", "")
if st != "SUCCEEDED":
    err = resp.get("status", {}).get("error", {}).get("message", "")
    sys.stderr.write(f"query_web_vitals.sh: statement state={st} {err}\n")
    sys.exit(4)

cols = [c["name"] for c in resp.get("manifest", {}).get("schema", {}).get("columns", [])]
rows = resp.get("result", {}).get("data_array", []) or []

if os.environ.get("FMT") == "json":
    print(json.dumps([dict(zip(cols, r)) for r in rows], indent=2))
else:
    print("\t".join(cols))
    for r in rows:
        print("\t".join("" if v is None else str(v) for v in r))
PY
