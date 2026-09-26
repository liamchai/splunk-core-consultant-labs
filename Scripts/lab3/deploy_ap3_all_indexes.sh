#!/usr/bin/env bash
#
# Builds the ap3_all_indexes app (from the org_all_indexes template) with the
# four Sherlock Holmes indexes required for content-based routing.
#
# Run this ON the search head (sh1) ONLY. Written under etc/deployment-apps —
# push it out via BOTH "All_Search_Heads" and "All_Indexers" serverclasses,
# see deploy_ap3_serverclass_config.sh. Run deploy_ap3_volume_indexes.sh
# first so the "volume:primary" reference here resolves once deployed
# alongside ap3_indexer_volume_indexes / ap3_search_volume_indexes.
#
# ALSO copies itself into sh1's own etc/apps and restarts splunkd there: sh1
# is never a deployment client of itself, and "All_Search_Heads" only
# whitelists "*-mc*" (matches mc1, not sh1), so sh1 would otherwise never
# receive this app — the "novels" (etc.) indexes wouldn't be defined locally
# on the search head.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_ap3_all_indexes.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-ap3_all_indexes}"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
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

# CUSTOMER INDEXES — per the lab's four content-routing destinations.
ensure_stanza "$DEST_APP_PATH/local/indexes.conf" "[sherlock]" \
'[sherlock]
homePath = volume:primary/sherlock/db
coldPath = volume:primary/sherlock/colddb
thawedPath = $SPLUNK_DB/sherlock/thaweddb'

ensure_stanza "$DEST_APP_PATH/local/indexes.conf" "[watson]" \
'[watson]
homePath = volume:primary/watson/db
coldPath = volume:primary/watson/colddb
thawedPath = $SPLUNK_DB/watson/thaweddb'

ensure_stanza "$DEST_APP_PATH/local/indexes.conf" "[moriarty]" \
'[moriarty]
homePath = volume:primary/moriarty/db
coldPath = volume:primary/moriarty/colddb
thawedPath = $SPLUNK_DB/moriarty/thaweddb'

ensure_stanza "$DEST_APP_PATH/local/indexes.conf" "[novels]" \
'[novels]
homePath = volume:primary/novels/db
coldPath = volume:primary/novels/colddb
thawedPath = $SPLUNK_DB/novels/thaweddb'

ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

echo
echo "== Also placing $NEW_APP_NAME directly in sh1's own apps folder =="
DEST_ON_SH="$APPS_DIR/$NEW_APP_NAME"
mkdir -p "$DEST_ON_SH"
cp -a "$DEST_APP_PATH/." "$DEST_ON_SH/"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH" "$DEST_ON_SH"

echo
echo "== Restart Splunk (applies $NEW_APP_NAME on sh1) =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. $NEW_APP_NAME created sherlock/watson/moriarty/novels indexes,"
echo "applied locally on sh1, and staged in deployment-apps."
echo "Add it to BOTH 'All_Search_Heads' and 'All_Indexers' serverclasses next."
