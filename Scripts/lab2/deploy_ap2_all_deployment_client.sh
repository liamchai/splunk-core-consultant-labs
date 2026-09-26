#!/usr/bin/env bash
#
# Builds/updates the ap2_all_deployment_client app (from the
# org_all_deploymentclient template) directly on a Splunk instance, pointing
# it at the search head, which acts as the Lab 2 deployment server.
#
# Run this ON every node EXCEPT the search head:
#   - Monitoring Console (mc1)
#   - Indexers (idx1, idx2)
#   - Universal Forwarder (uf1) — set SPLUNK_HOME=/opt/splunkforwarder below
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_ap2_all_deployment_client.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
# On the universal forwarder this is /opt/splunkforwarder, not /opt/splunk.
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-ap2_all_deployment_client}"

# The search head's mgmt host:port (sh1 acts as the deployment server).
DEPLOYMENT_SERVER_URI="3.150.109.220:8089"

# Splunk admin credentials for THIS instance — required, sent via env var,
# never as a CLI arg.
SPLUNK_ADMIN_USER="admin"
SPLUNK_ADMIN_PASSWORD="4hj2juj6"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$SPLUNK_ADMIN_USER" && -n "$SPLUNK_ADMIN_PASSWORD" ]] || {
    echo "ERROR: SPLUNK_ADMIN_USER / SPLUNK_ADMIN_PASSWORD must be set in this file." >&2
    exit 1
}
[[ -n "$DEPLOYMENT_SERVER_URI" ]] || {
    echo "ERROR: DEPLOYMENT_SERVER_URI must be set to sh1's host:8089." >&2
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
# Set the phoneHome at the end of the PS engagement
# 10 minutes
# phoneHomeIntervalInSecs = 600'

ensure_stanza "$DEST_APP_PATH/local/deploymentclient.conf" "[target-broker:deploymentServer]" \
"[target-broker:deploymentServer]
targetUri = ${DEPLOYMENT_SERVER_URI}"

# server.conf ships with no active stanza (an optional, commented pass4SymmKey)
# — only write it if it doesn't exist yet; never touch an existing one.
if [[ ! -f "$DEST_APP_PATH/local/server.conf" ]]; then
    cat > "$DEST_APP_PATH/local/server.conf" <<'EOF'
[deployment]
# This sets a new shared secret between the DS and the client. This helps
# prevent downloading apps from rogue Deployment Servers.
# See also org_ds_secure_server
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
echo "Owned by $SPLUNK_USER:$SPLUNK_GROUP"

echo
echo "== Restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. $NEW_APP_NAME up to date at $DEST_APP_PATH — this host now phones"
echo "home to deployment server $DEPLOYMENT_SERVER_URI."
