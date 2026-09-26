#!/usr/bin/env bash
#
# Creates (or updates) the ap1_all_indexer_base app directly on a Splunk
# indexer (no scp needed) by writing the org_all_indexer_base template's
# .conf files in place, then validates, fixes ownership, restarts Splunk,
# and checks the receiving port.
#
# Idempotent: if the app or its .conf files already exist, existing stanzas
# are left untouched and only missing stanzas are appended.
#
# Run this ON the indexer, as root:
#   sudo ./deploy_ap1_all_indexer_base.sh
#
set -euo pipefail

# ---- configuration (override via env vars) --------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
NEW_APP_NAME="${NEW_APP_NAME:-ap1_all_indexer_base}"
LISTEN_PORT="${LISTEN_PORT:-9997}"

# Splunk admin credentials — required. Used to authenticate `splunk restart`
# and `splunk display listen` via env vars (never passed as CLI args, so the
# password doesn't show up in `ps`).
SPLUNK_ADMIN_USER="admin"
SPLUNK_ADMIN_PASSWORD="325rgmh8"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$SPLUNK_ADMIN_USER" && -n "$SPLUNK_ADMIN_PASSWORD" ]] || {
    echo "ERROR: SPLUNK_ADMIN_USER / SPLUNK_ADMIN_PASSWORD must be set in this file." >&2
    exit 1
}

DEST_APP_PATH="$APPS_DIR/$NEW_APP_NAME"

# ensure_stanza <file> <stanza-header> <block>
# Creates <file> with <block> if it doesn't exist. If it exists, appends
# <block> only when <stanza-header> isn't already present.
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

echo "== Step 3/4: create/update $NEW_APP_NAME under $APPS_DIR =="
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

# web.conf ships with no active stanza (just guidance comments) — only write
# it if it doesn't exist yet; never touch an existing one.
if [[ ! -f "$DEST_APP_PATH/local/web.conf" ]]; then
    mkdir -p "$DEST_APP_PATH/local"
    cat > "$DEST_APP_PATH/local/web.conf" <<'EOF'

# In larger environments, where there are more than, say, three indexers,
# it's common to disable the Splunk UI. This helps avoid configuration issues
# caused by logging in to the UI to do something directly via the manager,
# as well as saving some system resources.

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
echo "== Step 5: review .conf settings that are enabled/uncommented =="
while IFS= read -r -d '' conf; do
    echo "--- ${conf#"$DEST_APP_PATH"/} ---"
    grep -vE '^\s*(#.*)?$' "$conf" || echo "  (nothing active — everything is commented out)"
    echo
done < <(find "$DEST_APP_PATH" -type f -name '*.conf' -print0 | sort -z)

echo "Review the above. Ctrl+C now if a setting needs editing before Splunk starts using it."
echo

echo "== Step 6: fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH"
echo "Owned by $SPLUNK_USER:$SPLUNK_GROUP"

echo
echo "== Step 7: restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "== Step 8: check receiver status (port $LISTEN_PORT) =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" display listen

echo
echo "Done. $NEW_APP_NAME up to date at $DEST_APP_PATH"
