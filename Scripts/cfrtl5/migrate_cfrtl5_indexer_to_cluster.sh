#!/usr/bin/env bash
#
# Migrates a stand-alone indexer (idx1 or idx2) into a clustered peer.
# Combines the lab's "Migrate the Stand-alone Indexers" steps:
#   1. Decouple from the Deployment Server (stop Splunk FIRST, then remove
#      the deployment-client app — removing it while Splunk is running can
#      have it refreshed back from local cache before the restart, per the
#      lab's caution note).
#   2. Hand-copy the cfrtl5_cluster_indexer_base content (same stanzas as
#      build_cfrtl5_cluster_indexer_apps.sh) directly into etc/apps, with
#      manager_uri/pass4SymmKey/replication port filled in.
#   3. Restart and wait for it to join the cluster.
#
# Run this ON idx1, then again ON idx2 (repeat — same script, same env vars,
# just re-run per host).
#
# Idempotent-ish: safe to re-run; Splunk is stopped/started every run.
#
#   sudo ./migrate_cfrtl5_indexer_to_cluster.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

CLUSTER_INDEXER_BASE_APP="${CLUSTER_INDEXER_BASE_APP:-cfrtl5_cluster_indexer_base}"

# The name of the pre-existing deployment-client app to remove from this
# indexer (whatever this environment's earlier setup called it) — edit if
# your pre-existing infra used a different name.
DEPLOYMENTCLIENT_APP="${DEPLOYMENTCLIENT_APP:-cfrtl5_all_deploymentclient}"

# cm1's bare mgmt host:port. No trailing slash (see the lab's troubleshooting
# note — this is likely a bare IP, not the "cfrtl5-*" display name).
CLUSTER_MANAGER_URI="cm1-host-or-ip:8089"

# Shared secret between the manager and every peer/search-head. Must be
# IDENTICAL (plaintext) across cm1, idx1, idx2, and sh1 — export once per
# shell session:
#   export CLUSTER_PASS4SYMMKEY='...'
CLUSTER_PASS4SYMMKEY="${CLUSTER_PASS4SYMMKEY:?export CLUSTER_PASS4SYMMKEY first}"

RECEIVING_PORT="${RECEIVING_PORT:-9997}"
# Per the lab: "Use 9887 for your indexer replication port."
REPLICATION_PORT="${REPLICATION_PORT:-9887}"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
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

echo "== Stop Splunk (before touching deployment-client-managed apps) =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" stop

echo
echo "== Decouple from the Deployment Server =="
DC_APP_PATH="$APPS_DIR/$DEPLOYMENTCLIENT_APP"
if [[ -d "$DC_APP_PATH" ]]; then
    rm -rf "$DC_APP_PATH"
    echo "  removed $DC_APP_PATH"
else
    echo "  $DC_APP_PATH not found — already decoupled, or DEPLOYMENTCLIENT_APP name doesn't match this env"
fi

echo
echo "== Install $CLUSTER_INDEXER_BASE_APP directly (hand-copy, not via DS) =="
APP_PATH="$APPS_DIR/$CLUSTER_INDEXER_BASE_APP"
mkdir -p "$APP_PATH/local" "$APP_PATH/metadata"

ensure_stanza "$APP_PATH/local/app.conf" "[install]" \
'[install]
state = enabled'
ensure_stanza "$APP_PATH/local/app.conf" "[package]" \
'[package]
check_for_updates = false'
ensure_stanza "$APP_PATH/local/app.conf" "[ui]" \
'[ui]
is_visible = false
is_manageable = false'

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
[settings]
startwebserver = false
EOF
    echo "  created $APP_PATH/local/web.conf"
else
    echo "  $APP_PATH/local/web.conf already exists — leaving as is"
fi

ensure_stanza "$APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$APPS_DIR"

echo
echo "== Start Splunk and wait for cluster join =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" start

echo
echo "Done. Check the Cluster Manager's UI (Settings -> Indexer Clustering)"
echo "to confirm this peer joined. Repeat this whole script on the other indexer."
