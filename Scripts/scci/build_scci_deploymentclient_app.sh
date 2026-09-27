#!/usr/bin/env bash
#
# Builds the scci_all_deploymentclient app (from the org_all_deploymentclient
# template, "scci" replacing the "org" prefix) directly under
# etc/deployment-apps on aio1 — the all-in-one instance, which is ALSO this
# lab's Deployment Server (DS).
#
# Per the lab: "Copy this same app to the deployment server itself... For
# the deployment server, apps awaiting deployment live within
# /opt/splunk/etc/deployment-apps" — this keeps a DS-managed copy of the
# deployment client app so its targetUri can be refreshed centrally later,
# even though the forwarder's FIRST copy is bootstrapped directly (see
# deploy_scci_deploymentclient.sh, run on the forwarder itself).
#
# Run this ON aio1 ONLY.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./build_scci_deploymentclient_app.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-scci_all_deploymentclient}"

# aio1's own bare (public) IP:8089 — aio1 is both the DS and the indexer in
# this lab. Don't rely on DNS in this environment.
DEPLOYMENT_SERVER_URI="aio1-public-ip:8089"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$DEPLOYMENT_SERVER_URI" ]] || {
    echo "ERROR: DEPLOYMENT_SERVER_URI must be set to aio1's bare IP:8089 (no protocol)." >&2
    exit 1
}

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
echo "Done. $NEW_APP_NAME staged in deployment-apps on aio1."
echo "Run deploy_scci_deploymentclient.sh on the forwarder to bootstrap the"
echo "connection, then add $NEW_APP_NAME to the 'scci_forwarders' serverclass"
echo "(see deploy_scci_serverclass_config.sh) to keep it centrally managed."
