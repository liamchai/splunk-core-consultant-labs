#!/usr/bin/env bash
#
# Builds the cfrtl5_cluster_indexer_base app (from the org_cluster_indexer_base
# template) under etc/deployment-apps on the Deployment Server (mc1):
#
#   cfrtl5_cluster_indexer_base  -> mode = peer, receiving port, replication
#                                   port, repFactor = auto on [default]
#
# This is "the indexer class['s apps]" referenced by the lab: it gets
# attached to the all_indexers serverclass (idx1, idx2) AND, per the lab's
# "add the same apps that the indexer class has" step, mirrored onto the
# cluster_master serverclass (cm1) — see deploy_cfrtl5_serverclass_config.sh.
#
# NOTE: idx1/idx2 do NOT end up running this via the deployment client — the
# lab has them decouple from the DS entirely once they join the cluster (see
# migrate_cfrtl5_indexer_to_cluster.sh, which hand-copies this same stanza
# content directly into their own etc/apps). Building/serverclassing it here
# is still needed so cm1's deployment-client pull (repositoryLocation =
# manager-apps) has real content to fetch.
#
# Run this ON the Deployment Server (mc1) ONLY.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./build_cfrtl5_cluster_indexer_apps.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

CLUSTER_INDEXER_BASE_APP="${CLUSTER_INDEXER_BASE_APP:-cfrtl5_cluster_indexer_base}"

# cm1's bare mgmt host:port — filled in once cm1 is installed (step 0) and
# reachable. No trailing slash (see the lab's troubleshooting note).
CLUSTER_MANAGER_URI="cm1-host-or-ip:8089"

# Shared secret between the manager and every peer/search-head. Must be
# IDENTICAL (plaintext) across cm1, idx1, idx2, and sh1 — export once per
# shell session:
#   export CLUSTER_PASS4SYMMKEY='...'
CLUSTER_PASS4SYMMKEY="${CLUSTER_PASS4SYMMKEY:?export CLUSTER_PASS4SYMMKEY first}"

RECEIVING_PORT="${RECEIVING_PORT:-9997}"
REPLICATION_PORT="${REPLICATION_PORT:-9887}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$CLUSTER_MANAGER_URI" ]] || { echo "ERROR: CLUSTER_MANAGER_URI must be set." >&2; exit 1; }

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

# build_base_app <app-name>
build_base_app() {
    local app="$1" path="$DEPLOYMENT_APPS_DIR/$1"
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

echo "== $CLUSTER_INDEXER_BASE_APP: peer mode + receiving/replication ports =="
build_base_app "$CLUSTER_INDEXER_BASE_APP"
APP_PATH="$DEPLOYMENT_APPS_DIR/$CLUSTER_INDEXER_BASE_APP"

ensure_stanza "$APP_PATH/local/server.conf" "[clustering]" \
"[clustering]
mode = peer
manager_uri = https://${CLUSTER_MANAGER_URI}
pass4SymmKey = ${CLUSTER_PASS4SYMMKEY}"
ensure_stanza "$APP_PATH/local/server.conf" "[replication_port://${REPLICATION_PORT}]" \
"[replication_port://${REPLICATION_PORT}]
disabled = false"

ensure_stanza "$APP_PATH/local/inputs.conf" "[splunktcp://${RECEIVING_PORT}]" \
"[splunktcp://${RECEIVING_PORT}]"

ensure_stanza "$APP_PATH/local/indexes.conf" "[default]" \
'[default]
repFactor = auto'

if [[ ! -f "$APP_PATH/local/web.conf" ]]; then
    cat > "$APP_PATH/local/web.conf" <<'EOF'
# Clustered indexers don't need Splunkweb running; also, their config is
# managed by the cluster manager's bundle push, not a local admin.
[settings]
startwebserver = false
EOF
    echo "  created $APP_PATH/local/web.conf"
else
    echo "  $APP_PATH/local/web.conf already exists — leaving as is"
fi

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$APP_PATH"

echo
echo "Done. $CLUSTER_INDEXER_BASE_APP staged in deployment-apps."
echo "Add it to the 'all_indexers' AND 'cluster_master' serverclasses next"
echo "(see deploy_cfrtl5_serverclass_config.sh), then hand-copy this same"
echo "content onto idx1/idx2 directly (migrate_cfrtl5_indexer_to_cluster.sh)."
