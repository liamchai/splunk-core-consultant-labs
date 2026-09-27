#!/usr/bin/env bash
#
# Builds the cfrtl4_all_indexes app (from the org_all_indexes template),
# including the "onboarding" index harvested from aio1 (see
# harvest_aio1_sourcetypes.sh — run that FIRST and paste its indexes.conf
# stanza into ONBOARDING_INDEX_STANZA below before running this).
#
# Run this ON the search head (sh1) ONLY — sh1 is the Deployment Server (DS)
# in this lab. Written under etc/deployment-apps — pushed out to idx1/aio1
# via "all_indexers" AND to mc1 via "all_search_heads" (this app is shared by
# both roles per the lab), see deploy_cfrtl4_serverclass_config.sh. Because
# sh1 (the DS) can't deploy to itself, this app is ALSO copied directly into
# sh1's own etc/apps by mirror_cfrtl4_search_head_apps.sh — run that after
# the serverclasses are set up.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_cfrtl4_all_indexes.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-cfrtl4_all_indexes}"

# Paste the [onboarding] stanza harvested via btool from aio1 here (homePath/
# coldPath updated to reference volume:primary per the lab's step 5). Leave
# empty to skip until you've run harvest_aio1_sourcetypes.sh.
ONBOARDING_INDEX_STANZA="${ONBOARDING_INDEX_STANZA:-}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

DEST_APP_PATH="$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME"

# ensure_stanza <file> <stanza-header> <block>
ensure_stanza() {
    local file="$1" stanza="$2" block="$3"
    mkdir -p "$(dirname "$file")"
    if [[ ! -f "$file" ]]; then
        printf '%s\n' "$block" > "$file"
        echo "  created $file (added $stanza)"
    elif grep -qxF "$stanza" "$file"; then
        echo "  $stanza already present in $file — leaving as is"
    else
        { printf '\n'; printf '%s\n' "$block"; } >> "$file"
        echo "  appended $stanza to $file"
    fi
}

echo "== Create/update $NEW_APP_NAME under $DEPLOYMENT_APPS_DIR =="
mkdir -p "$DEST_APP_PATH/local" "$DEST_APP_PATH/metadata"

ensure_stanza "$DEST_APP_PATH/local/app.conf" "[install]" \
'[install]
state = enabled'
ensure_stanza "$DEST_APP_PATH/local/app.conf" "[package]" \
'[package]
check_for_updates = false'
ensure_stanza "$DEST_APP_PATH/local/app.conf" "[ui]" \
'[ui]
is_visible = false
is_manageable = false'

if [[ -n "$ONBOARDING_INDEX_STANZA" ]]; then
    ensure_stanza "$DEST_APP_PATH/local/indexes.conf" "[onboarding]" "$ONBOARDING_INDEX_STANZA"
else
    echo "  ONBOARDING_INDEX_STANZA is empty — skipping [onboarding] index for now."
    echo "  Run harvest_aio1_sourcetypes.sh on aio1, then re-run this with"
    echo "  ONBOARDING_INDEX_STANZA set (or edit this script directly)."
fi

ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH"

echo
echo "Done. $NEW_APP_NAME staged in deployment-apps."
echo "Add it to BOTH 'all_indexers' and 'all_search_heads' serverclasses next."
