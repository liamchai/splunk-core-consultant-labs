#!/usr/bin/env bash
#
# Connects the search head (sh1) to the indexer cluster, hand-copying two
# apps directly into sh1's own etc/apps (the lab doesn't route this through
# the Deployment Server — it just says "identify the appropriate
# configuration app... update it... restart Splunk on your search head"):
#
#   cfrtl5_cluster_search_base      (org_cluster_search_base) -> mode =
#                                     searchhead, manager_uri, pass4SymmKey
#   cfrtl5_cluster_forwarder_outputs (org_cluster_forwarder_outputs) -> so
#                                     sh1's own _internal/_audit data lands
#                                     on the cluster too (useACK/maxQueueSize
#                                     tuned for clustering, per the template)
#
# Run this ON the search head (sh1) ONLY, AFTER cm1 is a Cluster Manager
# with idx1/idx2 already joined (migrate_cfrtl5_indexer_to_cluster.sh).
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_cfrtl5_search_head_cluster.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

CLUSTER_SEARCH_BASE_APP="${CLUSTER_SEARCH_BASE_APP:-cfrtl5_cluster_search_base}"
CLUSTER_FORWARDER_OUTPUTS_APP="${CLUSTER_FORWARDER_OUTPUTS_APP:-cfrtl5_cluster_forwarder_outputs}"

# cm1's bare mgmt host:port. No trailing slash.
CLUSTER_MANAGER_URI="cm1-host-or-ip:8089"

# Shared secret between the manager and every peer/search-head. Must be
# IDENTICAL (plaintext) across cm1, idx1, idx2, and sh1 — export once per
# shell session:
#   export CLUSTER_PASS4SYMMKEY='...'
CLUSTER_PASS4SYMMKEY="${CLUSTER_PASS4SYMMKEY:?export CLUSTER_PASS4SYMMKEY first}"

# The clustered indexers this SH forwards its own internal data to.
INDEXERS=(
    "idx1-host-or-ip:9997"
    "idx2-host-or-ip:9997"
)

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$CLUSTER_MANAGER_URI" ]] || { echo "ERROR: CLUSTER_MANAGER_URI must be set." >&2; exit 1; }
[[ ${#INDEXERS[@]} -gt 0 ]] || { echo "ERROR: INDEXERS list is empty — fill it in." >&2; exit 1; }

SERVER_LIST="$(IFS=, ; echo "${INDEXERS[*]}")"

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

# build_base_app <app-path>
build_base_app() {
    local path="$1"
    mkdir -p "$path/local" "$path/metadata"
    ensure_stanza "$path/local/app.conf" "[install]" \
'[install]
state = enabled'
    ensure_stanza "$path/local/app.conf" "[package]" \
'[package]
check_for_updates = false'
    ensure_stanza "$path/local/app.conf" "[ui]" \
'[ui]
is_visible = false
is_manageable = false'
    ensure_stanza "$path/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'
}

echo "== $CLUSTER_SEARCH_BASE_APP: searchhead mode -> $CLUSTER_MANAGER_URI =="
SEARCH_BASE_PATH="$APPS_DIR/$CLUSTER_SEARCH_BASE_APP"
build_base_app "$SEARCH_BASE_PATH"
ensure_stanza "$SEARCH_BASE_PATH/local/server.conf" "[clustering]" \
"[clustering]
mode = searchhead
manager_uri = https://${CLUSTER_MANAGER_URI}
pass4SymmKey = ${CLUSTER_PASS4SYMMKEY}"

echo
echo "== $CLUSTER_FORWARDER_OUTPUTS_APP: forward to ${INDEXERS[*]} (cluster-tuned) =="
FWD_PATH="$APPS_DIR/$CLUSTER_FORWARDER_OUTPUTS_APP"
build_base_app "$FWD_PATH"
ensure_stanza "$FWD_PATH/local/outputs.conf" "[tcpout]" \
'[tcpout]
defaultGroup = primary_indexers
maxQueueSize = 7MB
useACK = true
forceTimebasedAutoLB = true
forwardedindex.2.whitelist = (_audit|_introspection|_internal)'
ensure_stanza "$FWD_PATH/local/outputs.conf" "[tcpout:primary_indexers]" \
"[tcpout:primary_indexers]
server = ${SERVER_LIST}"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$SEARCH_BASE_PATH" "$FWD_PATH"

echo
echo "== Restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. Check Settings -> Distributed Search -> Search Peers on sh1 — it"
echo "should now list idx1 and idx2 (via the cluster manager), and cm1's UI"
echo "should list sh1 as a search head against the cluster."
