#!/usr/bin/env bash
#
# Builds/updates the scci_all_deploymentclient app directly on the forwarder
# instance (fwd1), pointing it at aio1 — the all-in-one instance, which acts
# as this lab's Deployment Server (DS) as well as its only indexer.
#
# Per the lab: "Copy this modified deploymentclient app to the forwarder
# instance" — this is the bootstrap "touch the host once" step. Use aio1's
# bare (public) IP for DEPLOYMENT_SERVER_URI below — don't rely on DNS in
# this environment.
#
# Run this ON the forwarder (fwd1) ONLY. If the forwarder was installed with
# install_uf.sh, its SPLUNK_HOME is /opt/splunkforwarder — export that first:
#   export SPLUNK_HOME=/opt/splunkforwarder
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_scci_deploymentclient.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-scci_all_deploymentclient}"

# aio1's bare public IP:8089 (aio1 acts as both the Deployment Server and the
# indexer in this lab).
DEPLOYMENT_SERVER_URI="aio1-public-ip:8089"

# Splunk admin credentials for THIS instance — export once per shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$DEPLOYMENT_SERVER_URI" ]] || {
    echo "ERROR: DEPLOYMENT_SERVER_URI must be set to aio1's bare IP:8089 (no protocol)." >&2
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
if [[ -d "$DEST_APP_PATH" ]]; then
    echo "$DEST_APP_PATH already exists — will only add missing stanzas."
else
    mkdir -p "$DEST_APP_PATH/local" "$DEST_APP_PATH/metadata"
    echo "Created $DEST_APP_PATH"
fi

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
# phoneHomeIntervalInSecs = 600'

ensure_stanza "$DEST_APP_PATH/local/deploymentclient.conf" "[target-broker:deploymentServer]" \
"[target-broker:deploymentServer]
targetUri = ${DEPLOYMENT_SERVER_URI}"

if [[ ! -f "$DEST_APP_PATH/local/server.conf" ]]; then
    cat > "$DEST_APP_PATH/local/server.conf" <<'EOF'
[deployment]
#pass4SymmKey = new_shared_secret
EOF
    echo "  created $DEST_APP_PATH/local/server.conf"
else
    echo "  $DEST_APP_PATH/local/server.conf already exists — leaving as is"
fi

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
echo "Done. $NEW_APP_NAME up to date at $DEST_APP_PATH — this host now phones"
echo "home to deployment server $DEPLOYMENT_SERVER_URI."
echo "Confirm on aio1: Settings -> Forwarder Management -> Clients tab."
