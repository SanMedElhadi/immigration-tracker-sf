#!/usr/bin/env bash
#
# Report data and file storage for an org.
#
# A Developer Edition org has roughly 5 MB of DATA storage and 20 MB of FILE
# storage. Data storage — records — is the binding constraint for this project;
# external file storage (design doc §10.1) relieves the file limit but does
# nothing for records.
#
#   ./scripts/check-storage.sh [-o <org-alias>] [-l <label>]
#
# Exits non-zero if data storage remaining drops below WARN_THRESHOLD_PCT.

set -euo pipefail

ORG=""
LABEL="storage"
WARN_THRESHOLD_PCT=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--target-org) ORG="$2"; shift 2 ;;
    -l|--label)      LABEL="$2"; shift 2 ;;
    -h|--help)       sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ORG_FLAG=()
[[ -n "$ORG" ]] && ORG_FLAG=(--target-org "$ORG")

# `sf org list limits` exposes DataStorageMB and FileStorageMB as Max/Remaining.
# Storage Usage in Setup shows the same numbers; this is the scriptable route.
JSON="$(sf org list limits "${ORG_FLAG[@]}" --json)"

# The JSON is passed as an argument, not on stdin: stdin is already carrying the
# Python program itself via the heredoc, and two redirections cannot coexist.
python3 - "$LABEL" "$WARN_THRESHOLD_PCT" "$JSON" <<'PY'
import json, sys

label = sys.argv[1]
threshold = float(sys.argv[2])
payload = json.loads(sys.argv[3])
limits = {row["name"]: row for row in payload.get("result", [])}

status = 0
print("\n  %s" % label)
print("  %-16s %10s %10s %10s %7s" % ("limit", "max", "used", "remaining", "used%"))
print("  " + "-" * 57)

for name, unit in (("DataStorageMB", "MB"), ("FileStorageMB", "MB")):
    row = limits.get(name)
    if not row:
        print("  %-16s  (not reported by this org)" % name)
        continue
    mx, rem = float(row["max"]), float(row["remaining"])
    used = mx - rem
    pct = (used / mx * 100) if mx else 0
    print("  %-16s %8.1f%s %8.1f%s %8.1f%s %6.1f%%" % (name, mx, unit, used, unit, rem, unit, pct))
    if name == "DataStorageMB" and mx and (rem / mx * 100) < threshold:
        print("\n  WARNING: less than %.0f%% of DATA storage remains." % threshold)
        print("  Records — not files — are the binding constraint in a DE org.")
        status = 1

print()
sys.exit(status)
PY
