#!/usr/bin/env bash
#
# Builds the three template-derived apps that configure the indexing tier
# (idx1 and aio1/idx2):
#
#   cfrtl4_all_indexer_base      (org_all_indexer_base)      -> receiving port, no Splunkweb
#   cfrtl4_indexer_volume_indexes (org_indexer_volume_indexes) -> volume:primary path for indexers
#   cfrtl4_full_license_server   (org_full_license_server)    -> points at sh1 as license master
#
# Run this ON the search head (sh1) ONLY — sh1 is the Deployment Server (DS)
# in this lab. All three are written directly under etc/deployment-apps and
# pushed out to idx1/aio1 via the "all_indexers" serverclass — see
# deploy_cfrtl4_serverclass_config.sh.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./build_cfrtl4_indexer_apps.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

INDEXER_BASE_APP="${INDEXER_BASE_APP:-cfrtl4_all_indexer_base}"
INDEXER_VOLUME_APP="${INDEXER_VOLUME_APP:-cfrtl4_indexer_volume_indexes}"
LICENSE_SERVER_APP="${LICENSE_SERVER_APP:-cfrtl4_full_license_server}"

LISTEN_PORT="${LISTEN_PORT:-9997}"
# Where the indexers should store their data (used for the volume path).
INDEXER_VOLUME_PATH="${INDEXER_VOLUME_PATH:-/opt/splunk/var/lib/splunk}"
# sh1's bare mgmt host:port — sh1 is the license master for this lab.
LICENSE_MANAGER_URI="sh1-public-ip:8089"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$LICENSE_MANAGER_URI" ]] || { echo "ERROR: LICENSE_MANAGER_URI must be set." >&2; exit 1; }

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

# build_base_app <app-name>
build_base_app() {
    local app="$1" path="$DEPLOYMENT_APPS_DIR/$1"
    mkdir -p "$path/local" "$path/metadata"
    ensure_stanza "$path/local/app.conf" "[install]" \
'[install]
state = enabled'
    ensure_stanza "$path/local/app.conf" "[package]" \
'[package]
check_for_updates = false'
    ensure_stanza "$path/local/app.conf" "[ui]" \
'[ui]
is_visible = false
is_manageable = false'
    ensure_stanza "$path/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'
}

echo "== $INDEXER_BASE_APP: receiving port + baseline indexer settings =="
build_base_app "$INDEXER_BASE_APP"
ensure_stanza "$DEPLOYMENT_APPS_DIR/$INDEXER_BASE_APP/local/inputs.conf" "[splunktcp://${LISTEN_PORT}]" \
"[splunktcp://${LISTEN_PORT}]"
if [[ ! -f "$DEPLOYMENT_APPS_DIR/$INDEXER_BASE_APP/local/web.conf" ]]; then
    cat > "$DEPLOYMENT_APPS_DIR/$INDEXER_BASE_APP/local/web.conf" <<'EOF'
# Indexers don't need Splunkweb running.
[settings]
startwebserver = 0
EOF
    echo "  created $DEPLOYMENT_APPS_DIR/$INDEXER_BASE_APP/local/web.conf"
else
    echo "  $DEPLOYMENT_APPS_DIR/$INDEXER_BASE_APP/local/web.conf already exists — leaving as is"
fi

echo
echo "== $INDEXER_VOLUME_APP: volume:primary -> $INDEXER_VOLUME_PATH =="
build_base_app "$INDEXER_VOLUME_APP"
ensure_stanza "$DEPLOYMENT_APPS_DIR/$INDEXER_VOLUME_APP/local/indexes.conf" "[volume:primary]" \
"[volume:primary]
path = ${INDEXER_VOLUME_PATH}
maxVolumeDataSizeMB = 5000000"

echo
echo "== $LICENSE_SERVER_APP: license master -> $LICENSE_MANAGER_URI =="
build_base_app "$LICENSE_SERVER_APP"
ensure_stanza "$DEPLOYMENT_APPS_DIR/$LICENSE_SERVER_APP/local/server.conf" "[license]" \
"[license]
manager_uri = https://${LICENSE_MANAGER_URI}"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" \
    "$DEPLOYMENT_APPS_DIR/$INDEXER_BASE_APP" \
    "$DEPLOYMENT_APPS_DIR/$INDEXER_VOLUME_APP" \
    "$DEPLOYMENT_APPS_DIR/$LICENSE_SERVER_APP"

echo
echo "Done. Add $INDEXER_BASE_APP, $INDEXER_VOLUME_APP, and $LICENSE_SERVER_APP"
echo "to the 'all_indexers' serverclass next (see deploy_cfrtl4_serverclass_config.sh)."
