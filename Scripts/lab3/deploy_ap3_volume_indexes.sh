#!/usr/bin/env bash
#
# Builds the ap3_indexer_volume_indexes app (from the org_indexer_volume_indexes
# template), pointing the primary and summaries volumes at /opt/splunkdata,
# then makes an identical copy named ap3_search_volume_indexes (the lab keeps
# both pointed at the same location for this practice lab).
#
# Run this ON the search head (sh1) ONLY. Run prepare_splunkdata_dirs.sh on
# idx1, idx2, sh1, and mc1 first so the target directory actually exists.
#
# Both apps are written under etc/deployment-apps:
#   ap3_indexer_volume_indexes -> push to idx1/idx2 via "All_Indexers"
#   ap3_search_volume_indexes  -> push to mc1 via "All_Search_Heads"
# ap3_search_volume_indexes is ALSO copied into sh1's own etc/apps and
# splunkd is restarted there — the lab step "Add your ap3_search_volume_indexes
# app to the apps folder of your search head/deployment server instance and
# restart splunkd" (sh1 isn't a deployment client of itself, so it needs its
# own local copy).
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_ap3_volume_indexes.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

INDEXER_APP="${INDEXER_APP:-ap3_indexer_volume_indexes}"
SEARCH_APP="${SEARCH_APP:-ap3_search_volume_indexes}"
SPLUNKDATA_DIR="${SPLUNKDATA_DIR:-/opt/splunkdata}"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

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

INDEXER_APP_PATH="$DEPLOYMENT_APPS_DIR/$INDEXER_APP"

echo "== $INDEXER_APP: volumes -> $SPLUNKDATA_DIR =="
mkdir -p "$INDEXER_APP_PATH/local" "$INDEXER_APP_PATH/metadata"

ensure_stanza "$INDEXER_APP_PATH/local/app.conf" "[install]" \
'[install]
state = enabled'
ensure_stanza "$INDEXER_APP_PATH/local/app.conf" "[package]" \
'[package]
check_for_updates = false'
ensure_stanza "$INDEXER_APP_PATH/local/app.conf" "[ui]" \
'[ui]
is_visible = false
is_manageable = false'

ensure_stanza "$INDEXER_APP_PATH/local/indexes.conf" "[volume:primary]" \
"[volume:primary]
path = ${SPLUNKDATA_DIR}
maxVolumeDataSizeMB = 5000000"

# The template's "secondary" volume: relocates _splunk_summaries data to the
# same partition as the primary volume.
ensure_stanza "$INDEXER_APP_PATH/local/indexes.conf" "[volume:_splunk_summaries]" \
"[volume:_splunk_summaries]
path = ${SPLUNKDATA_DIR}
maxVolumeDataSizeMB = 100000"

ensure_stanza "$INDEXER_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

echo
echo "== Copying $INDEXER_APP -> $SEARCH_APP (same content per the lab) =="
SEARCH_APP_PATH="$DEPLOYMENT_APPS_DIR/$SEARCH_APP"
mkdir -p "$SEARCH_APP_PATH"
cp -a "$INDEXER_APP_PATH/." "$SEARCH_APP_PATH/"

echo
echo "== Also placing $SEARCH_APP directly in sh1's own apps folder =="
DEST_ON_SH="$APPS_DIR/$SEARCH_APP"
mkdir -p "$DEST_ON_SH"
cp -a "$SEARCH_APP_PATH/." "$DEST_ON_SH/"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$INDEXER_APP_PATH" "$SEARCH_APP_PATH" "$DEST_ON_SH"

echo
echo "== Restart Splunk (applies $SEARCH_APP on sh1) =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. Add $INDEXER_APP to 'All_Indexers' and $SEARCH_APP to"
echo "'All_Search_Heads' next (see deploy_ap3_serverclass_config.sh)."
