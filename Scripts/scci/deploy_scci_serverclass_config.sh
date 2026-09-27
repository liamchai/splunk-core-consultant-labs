#!/usr/bin/env bash
#
# Configures the deployment server's serverclass.conf directly — the file
# behind the Forwarder Management UI's "New Server Class" wizard — instead
# of clicking through the UI. Creates the single serverclass from the lab:
#
#   scci_forwarders -> whitelist fwd1 -> apps: scci_maillog_inputs,
#                                               scci_all_forwarder_outputs,
#                                               scci_all_deploymentclient
#
# Per the lab: "include a whitelist statement to match your forwarder
# instance as the only entry to the class... changes to conf and/or
# outputs.conf require a restart of the node, so you should direct the app
# to restart Splunkd when it is deployed... keep the deployment client
# configuration up to date by assigning the customized
# org_all_deploymentclient app to the server class as well."
#
# Run this ON aio1, LAST, after:
#   build_scci_deploymentclient_app.sh
#   build_scci_maillog_apps.sh
# so the apps referenced below actually exist under etc/deployment-apps.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_scci_serverclass_config.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

SERVERCLASS_NAME="${SERVERCLASS_NAME:-scci_forwarders}"
DEPLOYMENTCLIENT_APP="${DEPLOYMENTCLIENT_APP:-scci_all_deploymentclient}"
INPUTS_APP="${INPUTS_APP:-scci_maillog_inputs}"
FORWARDER_OUTPUTS_APP="${FORWARDER_OUTPUTS_APP:-scci_all_forwarder_outputs}"

# The forwarder's client hostname/IP as reported by its own `hostname` (what
# Splunk shows for it in Forwarder Management -> Clients), NOT a lab display
# name.
FWD1_CLIENT_NAME="fwd1-hostname-or-ip"

# Same admin username/password used across this lab — export once per shell
# session:
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

echo "== ServerClass: $SERVERCLASS_NAME ($FWD1_CLIENT_NAME) =="
ensure_stanza "$CONF" "[serverClass:${SERVERCLASS_NAME}]" \
"[serverClass:${SERVERCLASS_NAME}]
whitelist.0 = ${FWD1_CLIENT_NAME}
restartSplunkd = true"

for app in "$INPUTS_APP" "$FORWARDER_OUTPUTS_APP" "$DEPLOYMENTCLIENT_APP"; do
    ensure_stanza "$CONF" "[serverClass:${SERVERCLASS_NAME}:app:${app}]" \
"[serverClass:${SERVERCLASS_NAME}:app:${app}]
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
echo "Done. The forwarder will pick up its apps on next phone-home (or"
echo "restart the client / lower phoneHomeIntervalInSecs to speed that up)."
echo "Check with: index=_internal | stats count by host   (expect fwd1)"
echo "            index=maildata | stats count by host    (expect fwd1, after a moment)"
