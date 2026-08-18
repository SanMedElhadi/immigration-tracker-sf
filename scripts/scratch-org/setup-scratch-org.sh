#!/usr/bin/env bash
#
# One command from a clean clone to a working demo org.
#
#   ./scripts/setup-scratch-org.sh [options]
#
#   -a, --alias <name>      scratch org alias            (default: immigration-dev)
#   -d, --duration <days>   scratch org lifetime, 1-30   (default: 7)
#   -f, --definition <path> scratch org definition file  (default: config/project-scratch-def.json)
#   -v, --dev-hub <alias>   Dev Hub alias                (default: the CLI default)
#       --keep              reuse an existing org with this alias instead of recreating
#       --no-data           deploy and assign, but skip the demo data import
#       --no-open           do not open the org at the end
#
# Two steps cannot be scripted and are reported at the end:
#   1. Platform Cache trial capacity — Setup -> Platform Cache -> Request Trial
#      Capacity. Defaults to 0 MB and cannot be provisioned declaratively; it is
#      NOT a valid scratch org feature (design doc §11.2).
#   2. External Credential authentication — the Authenticate action is an
#      interactive browser flow. Metadata carries the credential, never the token,
#      so every fresh org needs a human before any Dropbox/SharePoint callout works.

set -euo pipefail

ALIAS="immigration-dev"
DURATION=7
DEF_FILE="config/project-scratch-def.json"
DEV_HUB=""
KEEP=false
IMPORT_DATA=true
OPEN_ORG=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--alias)      ALIAS="$2"; shift 2 ;;
    -d|--duration)   DURATION="$2"; shift 2 ;;
    -f|--definition) DEF_FILE="$2"; shift 2 ;;
    -v|--dev-hub)    DEV_HUB="$2"; shift 2 ;;
    --keep)          KEEP=true; shift ;;
    --no-data)       IMPORT_DATA=false; shift ;;
    --no-open)       OPEN_ORG=false; shift ;;
    -h|--help)       sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Run from the repository root no matter where the script was invoked from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HUB_FLAG=()
[[ -n "$DEV_HUB" ]] && HUB_FLAG=(--target-dev-hub "$DEV_HUB")

step()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
note()  { printf '    %s\n' "$1"; }
fail()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

START_TS=$SECONDS

# ---------------------------------------------------------------- preflight
step "Preflight"
command -v sf       >/dev/null 2>&1 || fail "Salesforce CLI (sf) not found on PATH."
command -v python3  >/dev/null 2>&1 || fail "python3 not found; check-storage.sh needs it."
[[ -f "$DEF_FILE" ]] || fail "scratch org definition not found: $DEF_FILE"
[[ -f "config/demo-data-plan.json" ]] || fail "config/demo-data-plan.json not found."

if ! sf org display "${HUB_FLAG[@]}" >/dev/null 2>&1; then
  if [[ -n "$DEV_HUB" ]]; then
    fail "Dev Hub '$DEV_HUB' is not authenticated. Run: sf org login web --set-default-dev-hub"
  fi
  sf config get target-dev-hub 2>/dev/null | grep -q . \
    || fail "No default Dev Hub. Run: sf org login web --set-default-dev-hub"
fi
note "sf $(sf --version | head -1 | awk '{print $NF}')"
note "definition: $DEF_FILE"

# ---------------------------------------------------------------- create org
if $KEEP && sf org display --target-org "$ALIAS" >/dev/null 2>&1; then
  step "Reusing existing org '$ALIAS' (--keep)"
else
  if sf org display --target-org "$ALIAS" >/dev/null 2>&1; then
    step "Deleting existing scratch org '$ALIAS'"
    sf org delete scratch --target-org "$ALIAS" --no-prompt || true
  fi
  step "Creating scratch org '$ALIAS' (${DURATION}d)"
  sf org create scratch \
      --definition-file "$DEF_FILE" \
      --alias "$ALIAS" \
      --duration-days "$DURATION" \
      --set-default \
      --wait 20 \
      "${HUB_FLAG[@]}" \
    || fail "Scratch org creation failed. Check Dev Hub limits: sf org list limits -o <devhub>"
fi

# Storage baseline before anything is loaded, so the delta is meaningful.
step "Storage before deploy"
./scripts/check-storage.sh -o "$ALIAS" -l "baseline" || true

# ---------------------------------------------------------------- deploy
step "Deploying source"
# Experience Cloud note: Network/ExperienceBundle metadata requires the site to
# already exist in the target org. Keep it .forceignore'd for scratch orgs, or
# create the site from a template before this line (design doc §11.2).
sf project deploy start --target-org "$ALIAS" --wait 30 \
  || fail "Deploy failed. If the error names a missing field, the permission sets have drifted from the org — see scripts/strip-field-permission.py"

# ---------------------------------------------------------------- permissions
step "Assigning permission sets"
./scripts/assign-permsets.sh -o "$ALIAS"

# ---------------------------------------------------------------- data
if $IMPORT_DATA; then
  step "Importing reference and demo data"
  sf data import tree --plan config/demo-data-plan.json --target-org "$ALIAS" \
    || fail "Data import failed. Records load parent-first; a reference error usually means the plan order changed."

  step "Verifying record counts"
  for obj in Authority__c Document_Type__c Application_Type__c Requirement__c \
             Immigration_Case__c Application__c Document__c Case_Team_Member__c; do
    n="$(sf data query --query "SELECT COUNT() FROM $obj" --target-org "$ALIAS" --json \
         | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["totalSize"])' 2>/dev/null || echo "?")"
    printf '    %-24s %s\n' "$obj" "$n"
  done
else
  step "Skipping data import (--no-data)"
fi

# ---------------------------------------------------------------- storage after
step "Storage after import"
./scripts/check-storage.sh -o "$ALIAS" -l "after import" \
  || note "Data storage is running low — trim the demo data before adding more."

# ---------------------------------------------------------------- manual steps
step "Manual steps that cannot be scripted"
cat <<'MANUAL'
    1. Platform Cache
       Setup -> Platform Cache -> Request Trial Capacity (10 MB).
       Defaults to 0 MB; not a valid scratch org feature. FxRateService should
       degrade to its Custom Metadata fallback until this is granted.

    2. External Credential authentication
       Setup -> Named Credentials -> External Credentials -> Principals ->
       (row menu) -> Authenticate.
       Metadata carries the credential but never the token, so this interactive
       step is required in every fresh org before any storage callout succeeds.
       Grant your user External Credential Principal Access on the permission set
       BEFORE authenticating, or the principal lands half-configured.

    3. Experience Cloud site
       If the site is .forceignore'd for scratch orgs, create it from the LWR
       template and then deploy the site metadata separately.
MANUAL

ELAPSED=$(( SECONDS - START_TS ))
step "Done in ${ELAPSED}s"
note "Org alias: $ALIAS"
$OPEN_ORG && sf org open --target-org "$ALIAS" >/dev/null 2>&1 && note "Opened in browser."
exit 0
