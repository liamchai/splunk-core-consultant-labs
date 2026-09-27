#!/usr/bin/env bash
#
# Builds the two template-derived apps that get the forwarder collecting and
# shipping the mail log sample:
#
#   scci_maillog_inputs          (org_APP_TEMPLATE, seeded from
#                                  org_dept_app_inputs per the lab) -> monitor
#                                  stanza for /var/log/mail, index=maildata,
#                                  sourcetype=email_log
#   scci_all_forwarder_outputs   (org_all_forwarder_outputs)        -> single
#                                  tcpout target: aio1:9997
#
# Run this ON aio1 (the all-in-one instance, which is ALSO this lab's
# Deployment Server) ONLY. Written directly under etc/deployment-apps —
# pushed out to the forwarder via the "scci_forwarders" serverclass, see
# deploy_scci_serverclass_config.sh.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./build_scci_maillog_apps.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

INPUTS_APP="${INPUTS_APP:-scci_maillog_inputs}"
FORWARDER_OUTPUTS_APP="${FORWARDER_OUTPUTS_APP:-scci_all_forwarder_outputs}"

# Where the sample maillog data lives on the forwarder — per the lab's
# "Meet your data" table.
MONITOR_PATH="${MONITOR_PATH:-/var/log/mail}"
DEST_INDEX="${DEST_INDEX:-maildata}"
DEST_SOURCETYPE="${DEST_SOURCETYPE:-email_log}"

# aio1's bare host-or-ip:9997 — aio1 is the only indexer in this lab (see
# enable_scci_indexer_receiving.sh for opening this port on aio1 itself).
AIO1_RECEIVING_URI="aio1-host-or-ip:9997"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$AIO1_RECEIVING_URI" ]] || { echo "ERROR: AIO1_RECEIVING_URI must be set." >&2; exit 1; }

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

echo "== $INPUTS_APP: monitor $MONITOR_PATH -> index=$DEST_INDEX sourcetype=$DEST_SOURCETYPE =="
build_base_app "$INPUTS_APP"
ensure_stanza "$DEPLOYMENT_APPS_DIR/$INPUTS_APP/local/inputs.conf" "[monitor://${MONITOR_PATH}]" \
"[monitor://${MONITOR_PATH}]
index = ${DEST_INDEX}
sourcetype = ${DEST_SOURCETYPE}
disabled = false"

echo
echo "== $FORWARDER_OUTPUTS_APP: forward to $AIO1_RECEIVING_URI =="
build_base_app "$FORWARDER_OUTPUTS_APP"
ensure_stanza "$DEPLOYMENT_APPS_DIR/$FORWARDER_OUTPUTS_APP/local/outputs.conf" "[tcpout]" \
'[tcpout]
defaultGroup = primary_indexers'
ensure_stanza "$DEPLOYMENT_APPS_DIR/$FORWARDER_OUTPUTS_APP/local/outputs.conf" "[tcpout:primary_indexers]" \
"[tcpout:primary_indexers]
server = ${AIO1_RECEIVING_URI}"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" \
    "$DEPLOYMENT_APPS_DIR/$INPUTS_APP" \
    "$DEPLOYMENT_APPS_DIR/$FORWARDER_OUTPUTS_APP"

echo
echo "Done. Add $INPUTS_APP and $FORWARDER_OUTPUTS_APP to the"
echo "'scci_forwarders' serverclass next (see deploy_scci_serverclass_config.sh)."
