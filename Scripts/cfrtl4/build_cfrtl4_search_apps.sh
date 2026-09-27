#!/usr/bin/env bash
#
# Builds the three template-derived apps that configure the search tier
# (mc1, and sh1 itself via the manual mirror step):
#
#   cfrtl4_all_search_base      (org_all_search_base)      -> custom roles, optional web SSL
#                                (LDAP auth is skipped — "not used in this environment" per the lab)
#   cfrtl4_all_forwarder_outputs (org_all_forwarder_outputs) -> indexer list (idx1, aio1)
#   cfrtl4_search_volume_indexes (org_search_volume_indexes) -> volume:primary/secondary, no limit
#
# Run this ON the search head (sh1) ONLY — sh1 is the Deployment Server (DS)
# in this lab. All three are written directly under etc/deployment-apps and
# pushed out to mc1 via the "all_search_heads" serverclass — see
# deploy_cfrtl4_serverclass_config.sh. sh1 itself needs these too but can't
# deploy to itself; mirror_cfrtl4_search_head_apps.sh handles that afterward.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./build_cfrtl4_search_apps.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

SEARCH_BASE_APP="${SEARCH_BASE_APP:-cfrtl4_all_search_base}"
FORWARDER_OUTPUTS_APP="${FORWARDER_OUTPUTS_APP:-cfrtl4_all_forwarder_outputs}"
SEARCH_VOLUME_APP="${SEARCH_VOLUME_APP:-cfrtl4_search_volume_indexes}"

# Indexers to forward to (and that search from the SH will fan out to), as
# host:9997 — idx1 + aio1(idx2).
INDEXERS=(
    "idx1-host-or-ip:9997"
    "aio1-host-or-ip:9997"
)

# Set true to enable HTTPS for Splunk Web on hosts this app is applied to.
ENABLE_SPLUNKWEB_SSL="${ENABLE_SPLUNKWEB_SSL:-false}"

# Search-head-side volume path — no maxVolumeDataSizeMB, since the SH isn't
# indexing locally (this only needs to satisfy the "volume:primary" /
# "volume:secondary" references in cfrtl4_all_indexes).
SEARCH_VOLUME_PATH="${SEARCH_VOLUME_PATH:-/opt/splunk/var/lib/splunk}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ ${#INDEXERS[@]} -gt 0 ]] || { echo "ERROR: INDEXERS list is empty — fill it in." >&2; exit 1; }

SERVER_LIST="$(IFS=, ; echo "${INDEXERS[*]}")"

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

echo "== $SEARCH_BASE_APP: custom roles + optional web SSL =="
build_base_app "$SEARCH_BASE_APP"
SEARCH_BASE_PATH="$DEPLOYMENT_APPS_DIR/$SEARCH_BASE_APP"

# LDAP (authentication.conf) intentionally skipped — "not used in this
# environment" per the lab guide.

ensure_stanza "$SEARCH_BASE_PATH/local/authorize.conf" "[role_cfrtl4_custom]" \
'[role_cfrtl4_custom]
cumulativeRTSrchJobsQuota = 0
cumulativeSrchJobsQuota = 0
srchJobsQuota = 3
importRoles = user
srchIndexesAllowed = main;onboarding
srchIndexesDefault = onboarding
srchTimeWin = 7days'

ensure_stanza "$SEARCH_BASE_PATH/local/authorize.conf" "[role_cfrtl4_network]" \
'[role_cfrtl4_network]
cumulativeRTSrchJobsQuota = 0
cumulativeSrchJobsQuota = 0
importRoles = power;user
rtJobsQuota = 1
srchJobsQuota = 5
srchIndexesAllowed = *
srchIndexesDefault = main
srchTimeWin = 30days'

ensure_stanza "$SEARCH_BASE_PATH/local/authorize.conf" "[role_cfrtl4_admin]" \
'[role_cfrtl4_admin]
cumulativeRTSrchJobsQuota = 0
cumulativeSrchJobsQuota = 0
admin_all_objects = enabled
srchIndexesAllowed = *;_*
srchIndexesDefault = main
srchTimeWin = 0'

if [[ "$ENABLE_SPLUNKWEB_SSL" == "true" ]]; then
    ensure_stanza "$SEARCH_BASE_PATH/local/web.conf" "[settings]" \
'[settings]
enableSplunkWebSSL = true'
else
    echo "  ENABLE_SPLUNKWEB_SSL=false — leaving web.conf SSL setting untouched"
fi

echo
echo "== $FORWARDER_OUTPUTS_APP: forward to ${INDEXERS[*]} =="
build_base_app "$FORWARDER_OUTPUTS_APP"
FWD_PATH="$DEPLOYMENT_APPS_DIR/$FORWARDER_OUTPUTS_APP"
ensure_stanza "$FWD_PATH/local/outputs.conf" "[tcpout]" \
'[tcpout]
defaultGroup = primary_indexers'
ensure_stanza "$FWD_PATH/local/outputs.conf" "[tcpout:primary_indexers]" \
"[tcpout:primary_indexers]
server = ${SERVER_LIST}"

echo
echo "== $SEARCH_VOLUME_APP: volume:primary/secondary -> $SEARCH_VOLUME_PATH (no limit) =="
build_base_app "$SEARCH_VOLUME_APP"
VOL_PATH="$DEPLOYMENT_APPS_DIR/$SEARCH_VOLUME_APP"
ensure_stanza "$VOL_PATH/local/indexes.conf" "[volume:primary]" \
"[volume:primary]
path = ${SEARCH_VOLUME_PATH}"
ensure_stanza "$VOL_PATH/local/indexes.conf" "[volume:secondary]" \
"[volume:secondary]
path = ${SEARCH_VOLUME_PATH}"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" \
    "$DEPLOYMENT_APPS_DIR/$SEARCH_BASE_APP" \
    "$DEPLOYMENT_APPS_DIR/$FORWARDER_OUTPUTS_APP" \
    "$DEPLOYMENT_APPS_DIR/$SEARCH_VOLUME_APP"

echo
echo "Done. Add $SEARCH_BASE_APP, $FORWARDER_OUTPUTS_APP, and $SEARCH_VOLUME_APP"
echo "to the 'all_search_heads' serverclass next (see deploy_cfrtl4_serverclass_config.sh)."
