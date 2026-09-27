#!/usr/bin/env bash
#
# Builds/updates the cfrtl4_all_deploymentclient app (from the
# org_all_deploymentclient template) directly on a Splunk instance, pointing
# it at the search head, which acts as this lab's Deployment Server (DS).
#
# Run this ON every node EXCEPT the search head, to "touch the host once"
# and establish the deployment client / server relationship:
#   - idx1 (new indexer)
#   - mc1 (monitoring console)
#   - aio1 (the original all-in-one host, once it's being migrated — see
#     prepare_aio1_migration.sh, which calls this same logic after stopping
#     Splunk there)
#
# Use the bare (public) IP for DEPLOYMENT_SERVER_URI below — don't rely on
# DNS in this environment.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_cfrtl4_deploymentclient.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-cfrtl4_all_deploymentclient}"

# The search head's bare public IP:8089 (sh1 acts as the Deployment Server).
DEPLOYMENT_SERVER_URI="sh1-public-ip:8089"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$DEPLOYMENT_SERVER_URI" ]] || {
    echo "ERROR: DEPLOYMENT_SERVER_URI must be set to sh1's bare IP:8089 (no protocol)." >&2
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

# NOTE: targetUri must be a bare host:port, no protocol prefix (see the lab's
# troubleshooting note — btool should show no "https://" here).
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
echo "Confirm on sh1: Settings -> Forwarder Management -> Clients tab."
