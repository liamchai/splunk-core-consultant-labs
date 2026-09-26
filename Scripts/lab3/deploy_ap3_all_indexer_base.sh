#!/usr/bin/env bash
#
# Creates (or updates) the ap3_all_indexer_base app directly on a Splunk
# indexer by writing the org_all_indexer_base template's .conf files in
# place, then validates, fixes ownership, restarts Splunk, and checks the
# receiving port.
#
# Same as Lab 1/2's indexer step, renamed with the ap3_ prefix.
#
# Idempotent: if the app or its .conf files already exist, existing stanzas
# are left untouched and only missing stanzas are appended.
#
# Run this ON each indexer (idx1, idx2), as root:
#   sudo ./deploy_ap3_all_indexer_base.sh
#
set -euo pipefail

# ---- configuration (override via env vars) --------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-ap3_all_indexer_base}"
LISTEN_PORT="${LISTEN_PORT:-9997}"

# Splunk admin credentials — same username/password for every host in this
# lab. Export once per shell session before running any lab3 script:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

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

ensure_stanza "$DEST_APP_PATH/local/indexes.conf" "[default]" \
'[default]
# Enable the newer compression format introduced in Splunk 7.2
#journalCompression = zstd

# Enables various performance and space-saving improvements for tsidx files
# Set level 3 for Splunk 7.2 and higher or level 4 for Splunk 8.1 and higher
#tsidxWritingLevel = 3'

ensure_stanza "$DEST_APP_PATH/local/inputs.conf" "[splunktcp://${LISTEN_PORT}]" \
"[splunktcp://${LISTEN_PORT}]
# [splunktcp-ssl://9996]

# SSL SETTINGS
# [SSL]
# rootCA = \$SPLUNK_HOME/etc/auth/cacert.pem
# serverCert = \$SPLUNK_HOME/etc/auth/server.pem
# password = password
# requireClientCert = false
# If using compressed = true, it must be set on the forwarder outputs as well.
# compressed = true"

if [[ ! -f "$DEST_APP_PATH/local/web.conf" ]]; then
    mkdir -p "$DEST_APP_PATH/local"
    cat > "$DEST_APP_PATH/local/web.conf" <<'EOF'

# In larger environments, where there are more than, say, three indexers,
# it's common to disable the Splunk UI.

# [settings]
# startwebserver = 0
EOF
    echo "  created $DEST_APP_PATH/local/web.conf"
else
    echo "  $DEST_APP_PATH/local/web.conf already exists — leaving as is"
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
echo "== Check receiver status (port $LISTEN_PORT) =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" display listen

echo
echo "Done. $NEW_APP_NAME up to date at $DEST_APP_PATH"
