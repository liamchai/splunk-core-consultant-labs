#!/usr/bin/env bash
#
# Migrates the original all-in-one host (aio1) into a deployment client that
# will become "idx2". Combines the lab's two aio1-specific sections:
#   "Reclaim Settings from an Existing Node" (serverName rename — the props/
#   transforms harvesting itself is done separately via
#   harvest_aio1_sourcetypes.sh, since that's a read-only discovery step, not
#   a change to aio1)
#   "Make the Single Instance a Deployment Client"
#
# Run this ON aio1, as root, AFTER:
#   - harvest_aio1_sourcetypes.sh has been run (you've captured what you need)
#   - the harvested content has been folded into cfrtl4_all_indexes and the
#     cfrtl4_sourcetype_*_props apps on sh1
#   - those apps + the "all_indexers" serverclass are live on sh1
#
# Idempotent-ish: safe to re-run, but STALE_CONF_FILES are only ever renamed
# once (already-renamed files are skipped) and Splunk is restarted every run.
#
#   sudo ./prepare_aio1_migration.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

# New serverName for this host, e.g. cfrtl4_1234_idx2 — must be unique
# across the deployment (per the lab: "<your_name>_idx2").
NEW_SERVER_NAME="cfrtl4_CHANGEME_idx2"

# The stale props.conf/transforms.conf files identified via
# harvest_aio1_sourcetypes.sh's --debug output (the ones the GUI wrote,
# now superseded by the DS-pushed cfrtl4_sourcetype_*_props apps). Renamed
# to <name>.conf.bak rather than deleted, per the lab ("Remove (or rename,
# to something not ending in .conf)").
STALE_CONF_FILES=(
    # "/opt/splunk/etc/apps/search/local/props.conf"
    # "/opt/splunk/etc/apps/search/local/transforms.conf"
)

# The search head's bare public IP:8089 (sh1 acts as the Deployment Server) —
# same as DEPLOYMENT_SERVER_URI in deploy_cfrtl4_deploymentclient.sh.
DEPLOYMENT_SERVER_URI="sh1-public-ip:8089"
NEW_APP_NAME="${NEW_APP_NAME:-cfrtl4_all_deploymentclient}"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ "$NEW_SERVER_NAME" != "cfrtl4_CHANGEME_idx2" ]] || {
    echo "ERROR: edit NEW_SERVER_NAME at the top of this script first." >&2
    exit 1
}

SERVER_CONF="$SPLUNK_HOME/etc/system/local/server.conf"

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

echo "== Setting serverName = $NEW_SERVER_NAME in $SERVER_CONF =="
mkdir -p "$(dirname "$SERVER_CONF")"
if [[ -f "$SERVER_CONF" ]] && grep -qE '^\s*serverName\s*=' "$SERVER_CONF"; then
    sed -i "s/^\s*serverName\s*=.*/serverName = ${NEW_SERVER_NAME}/" "$SERVER_CONF"
    echo "  updated existing serverName= line"
elif [[ -f "$SERVER_CONF" ]] && grep -qxF '[general]' "$SERVER_CONF"; then
    sed -i "/^\[general\]/a serverName = ${NEW_SERVER_NAME}" "$SERVER_CONF"
    echo "  added serverName under existing [general]"
else
    { [[ -s "$SERVER_CONF" ]] && printf '\n'; printf '%s\n' '[general]' "serverName = ${NEW_SERVER_NAME}"; } >> "$SERVER_CONF"
    echo "  created [general] stanza with serverName"
fi

echo
echo "== Stop Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" stop

echo
echo "== Retire stale props/transforms files superseded by the DS =="
if [[ ${#STALE_CONF_FILES[@]} -eq 0 ]]; then
    echo "  STALE_CONF_FILES is empty — nothing to rename. Fill it in using"
    echo "  harvest_aio1_sourcetypes.sh's --debug output if there are GUI-written"
    echo "  props/transforms files that would otherwise conflict with the"
    echo "  DS-pushed cfrtl4_sourcetype_*_props apps."
else
    for f in "${STALE_CONF_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            mv "$f" "${f}.bak"
            echo "  renamed $f -> ${f}.bak"
        elif [[ -f "${f}.bak" ]]; then
            echo "  ${f}.bak already renamed — skipping"
        else
            echo "  $f not found — skipping"
        fi
    done
fi

echo
echo "== Install $NEW_APP_NAME (deployment client app) =="
DEST_APP_PATH="$APPS_DIR/$NEW_APP_NAME"
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
fi
ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNK_HOME/etc/system/local" "$DEST_APP_PATH"

echo
echo "== Restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. aio1 is now serverName=$NEW_SERVER_NAME and a deployment client of"
echo "$DEPLOYMENT_SERVER_URI. Confirm on sh1: Settings -> Forwarder Management"
echo "-> Clients, then add aio1 to the 'all_indexers' serverclass if not"
echo "already listed in deploy_cfrtl4_serverclass_config.sh's AIO1_CLIENT_NAME."
