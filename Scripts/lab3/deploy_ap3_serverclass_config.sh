#!/usr/bin/env bash
#
# Configures the deployment server's serverclass.conf directly — the file
# behind the Forwarder Management UI's "New Server Class" wizard — instead
# of clicking through the UI. Creates all 5 serverclasses from the lab:
#
#   Internal_Forwarders     -> whitelist *if*, *mc1*  -> app: ap3_internal_forwarder_outputs
#   Intermediate_Forwarders -> whitelist *if*          -> apps: ap3_intermediate_forwarder_limits,
#                                                                ap3_all_intermediate_forwarder_pipelines,
#                                                                ap3_intermediate_forwarder_inputs
#   Remote_Forwarders       -> whitelist *uf*          -> apps: ap3_external_forwarder_outputs,
#                                                                ap3_sherlock_inputs
#   All_Indexers            -> whitelist *idx*         -> apps: ap3_indexer_volume_indexes,
#                                                                ap3_all_indexes, ap3_sherlock_props
#   All_Search_Heads        -> whitelist *mc*          -> apps: ap3_search_volume_indexes,
#                                                                ap3_all_indexes
#
# NOTE: the lab guide's literal text is whitelist "*-mc*", but serverclass
# whitelist entries match the client's OS-reported hostname (via `hostname`),
# not the lab's display name column ("Ap3-xxxx-mc1") — if the real hostname
# doesn't have a hyphen right before "mc", "*-mc*" won't match. "*mc*" is used
# instead: mc1 is the only host in this topology with "mc" anywhere in its
# name, so it can't accidentally match sh1/idx1/idx2/uf1-4/if1-2.
#
# Run this ON the search head (sh1), LAST, after all the app-builder scripts:
#   deploy_ap3_internal_forwarder_outputs.sh
#   deploy_ap3_intermediate_forwarder_apps.sh
#   deploy_ap3_external_forwarder_outputs.sh
#   deploy_ap3_volume_indexes.sh
#   deploy_ap3_all_indexes.sh
#   deploy_ap3_sherlock_routing.sh
# so the apps referenced below actually exist under etc/deployment-apps.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_ap3_serverclass_config.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

INTERNAL_FWD_OUTPUTS_APP="${INTERNAL_FWD_OUTPUTS_APP:-ap3_internal_forwarder_outputs}"
INTERMEDIATE_LIMITS_APP="${INTERMEDIATE_LIMITS_APP:-ap3_intermediate_forwarder_limits}"
INTERMEDIATE_PIPELINES_APP="${INTERMEDIATE_PIPELINES_APP:-ap3_all_intermediate_forwarder_pipelines}"
INTERMEDIATE_INPUTS_APP="${INTERMEDIATE_INPUTS_APP:-ap3_intermediate_forwarder_inputs}"
EXTERNAL_FWD_OUTPUTS_APP="${EXTERNAL_FWD_OUTPUTS_APP:-ap3_external_forwarder_outputs}"
SHERLOCK_INPUTS_APP="${SHERLOCK_INPUTS_APP:-ap3_sherlock_inputs}"
INDEXER_VOLUME_APP="${INDEXER_VOLUME_APP:-ap3_indexer_volume_indexes}"
SEARCH_VOLUME_APP="${SEARCH_VOLUME_APP:-ap3_search_volume_indexes}"
ALL_INDEXES_APP="${ALL_INDEXES_APP:-ap3_all_indexes}"
SHERLOCK_PROPS_APP="${SHERLOCK_PROPS_APP:-ap3_sherlock_props}"

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

echo "== ServerClass 1: Internal_Forwarders =="
ensure_stanza "$CONF" "[serverClass:Internal_Forwarders]" \
'[serverClass:Internal_Forwarders]
whitelist.0 = *if*
whitelist.1 = *mc1*
restartSplunkd = true'
ensure_stanza "$CONF" "[serverClass:Internal_Forwarders:app:${INTERNAL_FWD_OUTPUTS_APP}]" \
"[serverClass:Internal_Forwarders:app:${INTERNAL_FWD_OUTPUTS_APP}]
restartSplunkd = true"

echo
echo "== ServerClass 2: Intermediate_Forwarders =="
ensure_stanza "$CONF" "[serverClass:Intermediate_Forwarders]" \
'[serverClass:Intermediate_Forwarders]
whitelist.0 = *if*
restartSplunkd = true'
ensure_stanza "$CONF" "[serverClass:Intermediate_Forwarders:app:${INTERMEDIATE_LIMITS_APP}]" \
"[serverClass:Intermediate_Forwarders:app:${INTERMEDIATE_LIMITS_APP}]
restartSplunkd = true"
ensure_stanza "$CONF" "[serverClass:Intermediate_Forwarders:app:${INTERMEDIATE_PIPELINES_APP}]" \
"[serverClass:Intermediate_Forwarders:app:${INTERMEDIATE_PIPELINES_APP}]
restartSplunkd = true"
ensure_stanza "$CONF" "[serverClass:Intermediate_Forwarders:app:${INTERMEDIATE_INPUTS_APP}]" \
"[serverClass:Intermediate_Forwarders:app:${INTERMEDIATE_INPUTS_APP}]
restartSplunkd = true"

echo
echo "== ServerClass 3: Remote_Forwarders =="
ensure_stanza "$CONF" "[serverClass:Remote_Forwarders]" \
'[serverClass:Remote_Forwarders]
whitelist.0 = *uf*
restartSplunkd = true'
ensure_stanza "$CONF" "[serverClass:Remote_Forwarders:app:${EXTERNAL_FWD_OUTPUTS_APP}]" \
"[serverClass:Remote_Forwarders:app:${EXTERNAL_FWD_OUTPUTS_APP}]
restartSplunkd = true"
ensure_stanza "$CONF" "[serverClass:Remote_Forwarders:app:${SHERLOCK_INPUTS_APP}]" \
"[serverClass:Remote_Forwarders:app:${SHERLOCK_INPUTS_APP}]
restartSplunkd = true"

echo
echo "== ServerClass 4: All_Indexers =="
ensure_stanza "$CONF" "[serverClass:All_Indexers]" \
'[serverClass:All_Indexers]
whitelist.0 = *idx*
restartSplunkd = true'
ensure_stanza "$CONF" "[serverClass:All_Indexers:app:${INDEXER_VOLUME_APP}]" \
"[serverClass:All_Indexers:app:${INDEXER_VOLUME_APP}]
restartSplunkd = true"
ensure_stanza "$CONF" "[serverClass:All_Indexers:app:${ALL_INDEXES_APP}]" \
"[serverClass:All_Indexers:app:${ALL_INDEXES_APP}]
restartSplunkd = true"
ensure_stanza "$CONF" "[serverClass:All_Indexers:app:${SHERLOCK_PROPS_APP}]" \
"[serverClass:All_Indexers:app:${SHERLOCK_PROPS_APP}]
restartSplunkd = true"

echo
echo "== ServerClass 5: All_Search_Heads =="
ensure_stanza "$CONF" "[serverClass:All_Search_Heads]" \
'[serverClass:All_Search_Heads]
whitelist.0 = *mc*
restartSplunkd = true'
ensure_stanza "$CONF" "[serverClass:All_Search_Heads:app:${SEARCH_VOLUME_APP}]" \
"[serverClass:All_Search_Heads:app:${SEARCH_VOLUME_APP}]
restartSplunkd = true"
ensure_stanza "$CONF" "[serverClass:All_Search_Heads:app:${ALL_INDEXES_APP}]" \
"[serverClass:All_Search_Heads:app:${ALL_INDEXES_APP}]
restartSplunkd = true"

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
echo
echo "Check with, from the search head:"
echo "  index=_internal | stats count by host   (expect all 6, then all 10 hosts)"
echo "  index=* | stats count by index          (expect sherlock/watson/moriarty/novels)"
echo "  index=* | stats count by host           (expect all 10 hosts)"
