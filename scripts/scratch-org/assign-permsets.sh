#!/usr/bin/env bash
#
# Assign the immigration permission sets.
#
#   ./scripts/assign-permsets.sh [-o <org-alias>] [-u <username>] [--all]
#
# Default: assigns the two sets an admin actually needs to drive the demo.
#   Immigration_Case_Manager   full CRUD, sees restricted fields, and is the set
#                              that must hold External Credential Principal Access
#   Immigration_Config_Admin   CRUD on the four reference objects
#
# --all additionally assigns Immigration_Case_Reader and
# Immigration_Portal_Applicant. Those exist for negative-access testing and for
# portal users respectively — assigning both to yourself defeats the point of
# the sharing tests (KAN-209), so it is opt-in.

set -euo pipefail

ORG=""
USERNAME=""
ASSIGN_ALL=false

DEFAULT_SETS=(Immigration_Case_Manager Immigration_Config_Admin)
EXTRA_SETS=(Immigration_Case_Reader Immigration_Portal_Applicant)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--target-org) ORG="$2"; shift 2 ;;
    -u|--username)   USERNAME="$2"; shift 2 ;;
    --all)           ASSIGN_ALL=true; shift ;;
    -h|--help)       sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

FLAGS=()
[[ -n "$ORG" ]]      && FLAGS+=(--target-org "$ORG")
[[ -n "$USERNAME" ]] && FLAGS+=(--on-behalf-of "$USERNAME")

SETS=("${DEFAULT_SETS[@]}")
$ASSIGN_ALL && SETS+=("${EXTRA_SETS[@]}")

failed=()
for ps in "${SETS[@]}"; do
  printf '  assigning %-32s ' "$ps"
  # Re-running is harmless: an existing assignment reports an error we swallow.
  if out="$(sf org assign permset --name "$ps" "${FLAGS[@]}" 2>&1)"; then
    echo "ok"
  elif grep -qi 'duplicate\|already' <<<"$out"; then
    echo "already assigned"
  else
    echo "FAILED"
    echo "$out" | sed 's/^/      /'
    failed+=("$ps")
  fi
done

if (( ${#failed[@]} )); then
  echo
  echo "  Failed: ${failed[*]}"
  echo "  If the error names a missing permission set, deploy source first."
  exit 1
fi
