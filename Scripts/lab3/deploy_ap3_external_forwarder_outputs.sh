#!/usr/bin/env bash
#
# Builds the ap3_external_forwarder_outputs app (from the
# org_all_forwarder_outputs template), pointing the External Universal
# Forwarders (uf1-4) at the Intermediate Forwarders (if1, if2) instead of
# the indexers directly.
#
# Run this ON the search head (sh1) ONLY. Written directly under
# etc/deployment-apps (sh1 doesn't run it itself) — push it out to uf1-4 via
# the "Remote_Forwarders" serverclass (whitelist *uf*), see
# deploy_ap3_serverclass_config.sh.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_ap3_external_forwarder_outputs.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-ap3_external_forwarder_outputs}"

# Intermediate forwarders to load-balance across, as host:9997.
INTERMEDIATE_FORWARDERS=(
    "3.128.160.56:9997"
    "18.221.213.31:9997"
)
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ ${#INTERMEDIATE_FORWARDERS[@]} -gt 0 ]] || {
    echo "ERROR: INTERMEDIATE_FORWARDERS list is empty — fill it in." >&2
    exit 1
}

SERVER_LIST="$(IFS=, ; echo "${INTERMEDIATE_FORWARDERS[*]}")"

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

# NOTE: defaultGroup points at [tcpout:intermediate_forwarders], NOT
# primary_indexers — this is what routes external forwarders to if1/if2
# instead of straight to the indexers.
ensure_stanza "$DEST_APP_PATH/local/outputs.conf" "[tcpout]" \
'[tcpout]
defaultGroup = intermediate_forwarders'

ensure_stanza "$DEST_APP_PATH/local/outputs.conf" "[tcpout:intermediate_forwarders]" \
"[tcpout:intermediate_forwarders]
server = ${SERVER_LIST}"

ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH"

echo
echo "Done. $NEW_APP_NAME load-balancing to: ${INTERMEDIATE_FORWARDERS[*]}"
echo "Add it to the 'Remote_Forwarders' serverclass next (whitelist *uf*)."
