#!/usr/bin/env bash
#
# Builds the ap3_internal_forwarder_outputs app (from the
# org_all_forwarder_outputs template), pointing the Intermediate Forwarders
# (if1, if2) at the Indexers.
#
# Run this ON the search head (sh1) ONLY. It writes the app under
# etc/deployment-apps (pushed out to if1/if2 later via the
# "Internal_Forwarders" serverclass — see deploy_ap3_serverclass_config.sh)
# AND under sh1's own etc/apps, then restarts Splunk on sh1 — the lab step
# "Copy the same forwarder outputs app to both the apps and deployment-apps
# folders on your search head" / "Restart Splunk ... on the Search Head",
# so the search head's own internal logs also flow to the indexing tier.
#
# Idempotent: existing stanzas are left untouched, only missing ones are
# added; the deployment-apps mirror is a plain overwrite-in-place copy.
#
#   sudo ./deploy_ap3_internal_forwarder_outputs.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-ap3_internal_forwarder_outputs}"

# Indexers to forward to, as host:9997.
INDEXERS=(
    "52.14.181.235:9997"
    "3.138.199.207:9997"
)

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
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

echo
echo "== Mirroring app to $DEPLOYMENT_APPS_DIR/$NEW_APP_NAME =="
mkdir -p "$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME"
cp -a "$DEST_APP_PATH/." "$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME/"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH" "$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME"

echo
echo "== Restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. $NEW_APP_NAME forwarding to: ${INDEXERS[*]}"
echo "Add it to the 'Internal_Forwarders' serverclass next (whitelist *if*, *mc1*)."
