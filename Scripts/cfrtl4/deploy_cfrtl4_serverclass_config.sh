#!/usr/bin/env bash
#
# Configures the deployment server's serverclass.conf directly — the file
# behind the Forwarder Management UI's "Server Classes" tab — instead of
# clicking through the UI. Creates all 3 serverclasses from the lab:
#
#   all_hosts        -> whitelist *                    -> app: cfrtl4_all_deploymentclient
#   all_indexers     -> whitelist idx1, aio1            -> apps: cfrtl4_indexer_volume_indexes,
#                                                                 cfrtl4_all_indexes,
#                                                                 cfrtl4_all_indexer_base,
#                                                                 cfrtl4_sourcetype_*_props (x4),
#                                                                 cfrtl4_full_license_server
#   all_search_heads -> whitelist mc1                   -> apps: cfrtl4_all_search_base,
#                                                                 cfrtl4_all_forwarder_outputs,
#                                                                 cfrtl4_all_indexes,
#                                                                 cfrtl4_search_volume_indexes,
#                                                                 cfrtl4_sourcetype_*_props (x4)
#
# Unlike the ap2/ap3 labs, this topology has no convenient hostname pattern
# (aio1 doesn't match "idx*"), so all_indexers/all_search_heads use explicit
# per-host whitelist entries instead of wildcards — matching the lab's UI
# instructions to "Add the indexers (as clients) to this class, one by one".
# sh1 (the DS) is deliberately never listed as a client of any class — it
# can't deploy to itself; see mirror_cfrtl4_search_head_apps.sh for how its
# own copies of the all_search_heads apps get there instead.
#
# Run this ON the search head (sh1), LAST, after all the app-builder scripts:
#   build_cfrtl4_indexer_apps.sh
#   deploy_cfrtl4_all_indexes.sh
#   build_cfrtl4_search_apps.sh
#   build_cfrtl4_sourcetype_props_apps.sh
# so the apps referenced below actually exist under etc/deployment-apps.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_cfrtl4_serverclass_config.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

DEPLOYMENTCLIENT_APP="${DEPLOYMENTCLIENT_APP:-cfrtl4_all_deploymentclient}"
INDEXER_BASE_APP="${INDEXER_BASE_APP:-cfrtl4_all_indexer_base}"
INDEXER_VOLUME_APP="${INDEXER_VOLUME_APP:-cfrtl4_indexer_volume_indexes}"
LICENSE_SERVER_APP="${LICENSE_SERVER_APP:-cfrtl4_full_license_server}"
ALL_INDEXES_APP="${ALL_INDEXES_APP:-cfrtl4_all_indexes}"
SEARCH_BASE_APP="${SEARCH_BASE_APP:-cfrtl4_all_search_base}"
FORWARDER_OUTPUTS_APP="${FORWARDER_OUTPUTS_APP:-cfrtl4_all_forwarder_outputs}"
SEARCH_VOLUME_APP="${SEARCH_VOLUME_APP:-cfrtl4_search_volume_indexes}"
SOURCETYPE_PROPS_PREFIX="${SOURCETYPE_PROPS_PREFIX:-cfrtl4_sourcetype}"
SOURCETYPE_SUFFIXES=(volume-iops edifecs sshd_syslog iis_onboarding)

# Client hostnames/IPs as reported by each host's own `hostname` (whatever
# Splunk shows for them in Forwarder Management -> Clients), NOT the lab's
# display names.
IDX1_CLIENT_NAME="idx1-hostname-or-ip"
AIO1_CLIENT_NAME="aio1-hostname-or-ip"
MC1_CLIENT_NAME="mc1-hostname-or-ip"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

CONF="$SPLUNK_HOME/etc/system/local/serverclass.conf"

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

echo "== ServerClass 1: all_hosts (keeps the deployment client app itself current) =="
ensure_stanza "$CONF" "[serverClass:all_hosts]" \
'[serverClass:all_hosts]
whitelist.0 = *
restartSplunkd = false'
ensure_stanza "$CONF" "[serverClass:all_hosts:app:${DEPLOYMENTCLIENT_APP}]" \
"[serverClass:all_hosts:app:${DEPLOYMENTCLIENT_APP}]
restartSplunkd = true"

echo
echo "== ServerClass 2: all_indexers (idx1, aio1) =="
ensure_stanza "$CONF" "[serverClass:all_indexers]" \
"[serverClass:all_indexers]
whitelist.0 = ${IDX1_CLIENT_NAME}
whitelist.1 = ${AIO1_CLIENT_NAME}
restartSplunkd = true"
for app in "$INDEXER_VOLUME_APP" "$ALL_INDEXES_APP" "$INDEXER_BASE_APP" "$LICENSE_SERVER_APP"; do
    ensure_stanza "$CONF" "[serverClass:all_indexers:app:${app}]" \
"[serverClass:all_indexers:app:${app}]
restartSplunkd = true"
done
for suffix in "${SOURCETYPE_SUFFIXES[@]}"; do
    app="${SOURCETYPE_PROPS_PREFIX}_${suffix}_props"
    ensure_stanza "$CONF" "[serverClass:all_indexers:app:${app}]" \
"[serverClass:all_indexers:app:${app}]
restartSplunkd = true"
done

echo
echo "== ServerClass 3: all_search_heads (mc1) =="
ensure_stanza "$CONF" "[serverClass:all_search_heads]" \
"[serverClass:all_search_heads]
whitelist.0 = ${MC1_CLIENT_NAME}
restartSplunkd = true"
for app in "$SEARCH_BASE_APP" "$FORWARDER_OUTPUTS_APP" "$ALL_INDEXES_APP" "$SEARCH_VOLUME_APP"; do
    ensure_stanza "$CONF" "[serverClass:all_search_heads:app:${app}]" \
"[serverClass:all_search_heads:app:${app}]
restartSplunkd = true"
done
for suffix in "${SOURCETYPE_SUFFIXES[@]}"; do
    app="${SOURCETYPE_PROPS_PREFIX}_${suffix}_props"
    ensure_stanza "$CONF" "[serverClass:all_search_heads:app:${app}]" \
"[serverClass:all_search_heads:app:${app}]
restartSplunkd = true"
done

echo
echo "== Fix ownership =="
chown "$SPLUNK_USER:$SPLUNK_GROUP" "$CONF"

echo
echo "== Reload deployment server =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" reload deploy-server

echo
echo "Done. Deployment clients will pick up their serverclass apps on next"
echo "phone-home (or restart the client / lower phoneHomeIntervalInSecs)."
echo "Run mirror_cfrtl4_search_head_apps.sh next to get the all_search_heads"
echo "apps onto sh1 itself (it can't deploy to itself)."
