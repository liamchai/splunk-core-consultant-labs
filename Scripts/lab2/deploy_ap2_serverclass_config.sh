#!/usr/bin/env bash
#
# Configures the deployment server's serverclass.conf directly — the file
# behind the Forwarder Management UI's "New Server Class" wizard — instead
# of clicking through the UI. Creates both serverclasses from the lab:
#
#   All_Forwarders   -> whitelist *uf1, *mc1        -> app: ap2_all_forwarder_outputs
#   All_Linux_Hosts  -> whitelist *, linux-x86_64   -> apps: Splunk_TA_nix, ap2_all_indexes
#
# Run this ON the search head (sh1), AFTER:
#   - deploy_ap2_all_forwarder_outputs.sh (with ALSO_DEPLOY_TO_DEPLOYMENT_APPS=true)
#   - deploy_ap2_splunk_ta_nix.sh
#   - deploy_ap2_all_indexes.sh (mirrored into deployment-apps on sh1)
# so the apps referenced below actually exist under etc/deployment-apps.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_ap2_serverclass_config.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

FORWARDER_OUTPUTS_APP="${FORWARDER_OUTPUTS_APP:-ap2_all_forwarder_outputs}"
NIX_TA_APP="${NIX_TA_APP:-Splunk_TA_nix}"
INDEXES_APP="${INDEXES_APP:-ap2_all_indexes}"

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

echo "== ServerClass 1: All_Forwarders =="
ensure_stanza "$CONF" "[serverClass:All_Forwarders]" \
'[serverClass:All_Forwarders]
whitelist.0 = *uf1
whitelist.1 = *mc1
restartSplunkd = true'

ensure_stanza "$CONF" "[serverClass:All_Forwarders:app:${FORWARDER_OUTPUTS_APP}]" \
"[serverClass:All_Forwarders:app:${FORWARDER_OUTPUTS_APP}]
restartSplunkd = true"

echo
echo "== ServerClass 2: All_Linux_Hosts =="
ensure_stanza "$CONF" "[serverClass:All_Linux_Hosts]" \
'[serverClass:All_Linux_Hosts]
whitelist.0 = *
machineTypesFilter = linux-x86_64
restartSplunkd = true'

ensure_stanza "$CONF" "[serverClass:All_Linux_Hosts:app:${NIX_TA_APP}]" \
"[serverClass:All_Linux_Hosts:app:${NIX_TA_APP}]
restartSplunkd = true"

ensure_stanza "$CONF" "[serverClass:All_Linux_Hosts:app:${INDEXES_APP}]" \
"[serverClass:All_Linux_Hosts:app:${INDEXES_APP}]
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
echo "phone-home (or restart the client / lower phoneHomeIntervalInSecs to"
echo "speed that up)."
echo
echo "Check with: from the search head, run"
echo "  index=_internal | stats count by host      (expect all 5 hosts)"
echo "  index=os | stats count by host              (expect all 5 hosts)"
