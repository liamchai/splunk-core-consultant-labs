#!/usr/bin/env bash
#
# Builds/updates the cfrtl5_manager_deploymentclient app (from the
# org_manager_deploymentclient template) directly on cm1, pointing it at
# mc1 (the Deployment Server in this lab) — but, UNLIKE a normal deployment
# client, staging received content in $SPLUNK_HOME/etc/manager-apps instead
# of etc/apps (repositoryLocation + serverRepositoryLocationPolicy =
# rejectAlways below), so cm1 can proxy it onward to idx1/idx2 via the
# cluster bundle instead of "running" it locally as an app.
#
# Run this ON the cluster master (cm1) ONLY, AFTER build_cfrtl5_cluster_manager_base.sh.
# Use the bare (public) IP for DEPLOYMENT_SERVER_URI below — don't rely on
# DNS in this environment.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_cfrtl5_manager_deploymentclient.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-cfrtl5_manager_deploymentclient}"

# mc1's bare public IP:8089 (mc1 acts as the Deployment Server in this lab).
DEPLOYMENT_SERVER_URI="mc1-public-ip:8089"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$DEPLOYMENT_SERVER_URI" ]] || {
    echo "ERROR: DEPLOYMENT_SERVER_URI must be set to mc1's bare IP:8089 (no protocol)." >&2
    exit 1
}

DEST_APP_PATH="$APPS_DIR/$NEW_APP_NAME"

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

echo "== Create/update $NEW_APP_NAME under $APPS_DIR =="
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

ensure_stanza "$DEST_APP_PATH/local/deploymentclient.conf" "[deployment-client]" \
'[deployment-client]
# phoneHomeIntervalInSecs = 600
repositoryLocation = $SPLUNK_HOME/etc/manager-apps
serverRepositoryLocationPolicy = rejectAlways'

# NOTE: targetUri must be a bare host:port, no protocol prefix.
ensure_stanza "$DEST_APP_PATH/local/deploymentclient.conf" "[target-broker:deploymentServer]" \
"[target-broker:deploymentServer]
targetUri = ${DEPLOYMENT_SERVER_URI}"

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
echo "== Verify deployment_client role took effect =="
grep ServerRoles "$SPLUNK_HOME/var/log/splunk/splunkd.log" | tail -5 || true

echo
echo "Done. cm1 now phones home to $DEPLOYMENT_SERVER_URI, stashing pushed apps"
echo "under etc/manager-apps (check with: ls \$SPLUNK_HOME/etc/manager-apps)."
echo "Confirm on mc1: Settings -> Forwarder Management -> Clients tab."
