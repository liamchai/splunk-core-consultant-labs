#!/usr/bin/env bash
#
# Hand-copies the cfrtl5_cluster_manager_base app (from the
# org_cluster_manager_base template) directly into cm1's OWN
# $SPLUNK_HOME/etc/apps — per the template's own note: "This file would have
# to be hand-copied to the etc/apps directory of the cluster manager." This
# is what turns cm1 into a Cluster Manager (mode = manager) with the given
# replication_factor/search_factor.
#
# NOT deployed via the Deployment Server — the manager's OWN clustering role
# config lives directly in its etc/apps, distinct from the etc/manager-apps
# content it proxies onward to peers (see
# deploy_cfrtl5_manager_deploymentclient.sh for that separate mechanism).
#
# Run this ON the cluster master (cm1) ONLY, AFTER install_splunk.sh:
#
#   sudo ./build_cfrtl5_cluster_manager_base.sh
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
# Restarts Splunk every run so the clustering role takes effect.
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

CLUSTER_MANAGER_BASE_APP="${CLUSTER_MANAGER_BASE_APP:-cfrtl5_cluster_manager_base}"

# Only 2 indexer nodes in this lab (idx1, idx2) — per the lab's "pay special
# attention to replication_factor; you will only have two indexer nodes
# available", set both factors to 2 so every bucket is fully replicated.
REPLICATION_FACTOR="${REPLICATION_FACTOR:-2}"
SEARCH_FACTOR="${SEARCH_FACTOR:-2}"

# Shared secret between the manager and every peer/search-head. Must be
# IDENTICAL (plaintext) across cm1, idx1, idx2, and sh1 — export once per
# shell session:
#   export CLUSTER_PASS4SYMMKEY='...'
CLUSTER_PASS4SYMMKEY="${CLUSTER_PASS4SYMMKEY:?export CLUSTER_PASS4SYMMKEY first}"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

DEST_APP_PATH="$APPS_DIR/$CLUSTER_MANAGER_BASE_APP"

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

echo "== Create/update $CLUSTER_MANAGER_BASE_APP under $APPS_DIR =="
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

ensure_stanza "$DEST_APP_PATH/local/server.conf" "[clustering]" \
"[clustering]
mode = manager
replication_factor = ${REPLICATION_FACTOR}
search_factor = ${SEARCH_FACTOR}
pass4SymmKey = ${CLUSTER_PASS4SYMMKEY}"

ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH"

echo
echo "== Restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "== Verify Cluster Manager mode =="
sudo -u "$SPLUNK_USER" "$SPLUNK_HOME/bin/splunk" btool server list clustering --debug || true

echo
echo "Done. cm1 is now a Cluster Manager (replication_factor=$REPLICATION_FACTOR,"
echo "search_factor=$SEARCH_FACTOR). Its GUI should report Cluster Master mode"
echo "with no peers configured yet."
