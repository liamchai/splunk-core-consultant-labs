#!/usr/bin/env bash
#
# Builds/updates the ap2_all_forwarder_outputs app (from the
# org_all_forwarder_outputs template), pointing it at the indexing tier.
#
# Run this ON:
#   - the Universal Forwarder (uf1): leave ALSO_DEPLOY_TO_DEPLOYMENT_APPS=false
#     (set SPLUNK_HOME=/opt/splunkforwarder below)
#   - the Search Head (sh1): set ALSO_DEPLOY_TO_DEPLOYMENT_APPS=true, per the
#     lab step "The same forwarder outputs app should be copied to both the
#     apps and deployment-apps folders on your search head."
#
# Idempotent: existing stanzas are left untouched, only missing ones are
# added; the deployment-apps mirror is a plain overwrite-in-place copy, safe
# to re-run.
#
#   sudo ./deploy_ap2_all_forwarder_outputs.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
# On the universal forwarder this is /opt/splunkforwarder, not /opt/splunk.
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-ap2_all_forwarder_outputs}"

# Set true when running on the search head (sh1); leave false on the UF.
ALSO_DEPLOY_TO_DEPLOYMENT_APPS=true

# Indexers to forward to, as host:9997.
INDEXERS=(
    "18.217.215.36:9997"
    "13.59.91.113:9997"
)

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
[[ ${#INDEXERS[@]} -gt 0 ]] || { echo "ERROR: INDEXERS list is empty — fill it in." >&2; exit 1; }

SERVER_LIST="$(IFS=, ; echo "${INDEXERS[*]}")"

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

# limits.conf ships with no active stanza — only write if missing.
if [[ ! -f "$DEST_APP_PATH/local/limits.conf" ]]; then
    cat > "$DEST_APP_PATH/local/limits.conf" <<'EOF'
# By default a universal or light forwarder is limited to 256kB/s
# Either set a different limit in kB/s, or set the value to zero to
# have no limit.
# Note that a full speed UF can overwhelm a single indexer.

# [thruput]
# maxKBps = 0
EOF
    echo "  created $DEST_APP_PATH/local/limits.conf"
else
    echo "  $DEST_APP_PATH/local/limits.conf already exists — leaving as is"
fi

ensure_stanza "$DEST_APP_PATH/local/outputs.conf" "[tcpout]" \
'[tcpout]
defaultGroup = primary_indexers'

ensure_stanza "$DEST_APP_PATH/local/outputs.conf" "[tcpout:primary_indexers]" \
"[tcpout:primary_indexers]
server = ${SERVER_LIST}"

ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

if [[ "$ALSO_DEPLOY_TO_DEPLOYMENT_APPS" == "true" ]]; then
    echo
    echo "== Mirroring app to $DEPLOYMENT_APPS_DIR/$NEW_APP_NAME =="
    mkdir -p "$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME"
    cp -a "$DEST_APP_PATH/." "$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME/"
    echo "Mirrored. Attach this app to a serverclass in the Forwarder Management UI"
    echo "to push it to deployment clients (manual UI step, not scripted here)."
fi

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH"
[[ "$ALSO_DEPLOY_TO_DEPLOYMENT_APPS" == "true" ]] && \
    chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME"
echo "Owned by $SPLUNK_USER:$SPLUNK_GROUP"

echo
echo "== Restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. $NEW_APP_NAME forwarding to: ${INDEXERS[*]}"
