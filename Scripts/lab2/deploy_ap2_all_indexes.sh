#!/usr/bin/env bash
#
# Builds/updates the ap2_all_indexes app (from the org_all_indexes template)
# with a single "os" index, for the Splunk Add-on for Unix and Linux data.
#
# Run this ON the indexers (idx1, idx2) so the "os" index physically exists
# where the data lands:
#   sudo ./deploy_ap2_all_indexes.sh
#
# Optionally also set ALSO_DEPLOY_TO_DEPLOYMENT_APPS=true when running on the
# search head (sh1), to stage a copy under deployment-apps for the
# "All_Linux_Hosts" serverclass (attaching apps to a serverclass is a manual
# step in the Forwarder Management UI, not scripted here).
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-ap2_all_indexes}"

# Set true only when running this on the search head to stage a deployment-apps copy.
ALSO_DEPLOY_TO_DEPLOYMENT_APPS=false

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

ensure_stanza "$DEST_APP_PATH/local/indexes.conf" "[os]" \
'[os]
homePath   = $SPLUNK_DB/os/db
coldPath   = $SPLUNK_DB/os/colddb
thawedPath = $SPLUNK_DB/os/thaweddb'

ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

if [[ "$ALSO_DEPLOY_TO_DEPLOYMENT_APPS" == "true" ]]; then
    echo
    echo "== Mirroring app to $DEPLOYMENT_APPS_DIR/$NEW_APP_NAME =="
    mkdir -p "$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME"
    cp -a "$DEST_APP_PATH/." "$DEPLOYMENT_APPS_DIR/$NEW_APP_NAME/"
    echo "Mirrored. Attach this app to the 'All_Linux_Hosts' serverclass in the"
    echo "Forwarder Management UI to push it out (manual UI step)."
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
echo "Done. $NEW_APP_NAME created the 'os' index at $DEST_APP_PATH"
