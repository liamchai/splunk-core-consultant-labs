#!/usr/bin/env bash
#
# ASSUMPTION (not spelled out verbatim in the lab guide, but required for the
# forwarder's data to actually arrive): ensures aio1 has a splunktcp
# receiving port open so the forwarder's outputs.conf (server = aio1:9997,
# see build_scci_maillog_apps.sh) has somewhere to land.
#
# Written directly under aio1's own etc/system/local — NOT etc/deployment-apps
# — because aio1 is the Deployment Server and cannot deploy configuration to
# itself; this is a local, one-host change applied directly.
#
# Run this ON aio1 ONLY.
#
# Idempotent: if the receiving port is already configured, this is a no-op.
#
#   sudo ./enable_scci_indexer_receiving.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
RECEIVING_PORT="${RECEIVING_PORT:-9997}"

# Same admin username/password used across this lab — export once per shell
# session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

CONF="$SPLUNK_HOME/etc/system/local/inputs.conf"
STANZA="[splunktcp://${RECEIVING_PORT}]"

echo "== Enabling splunktcp receiving on port $RECEIVING_PORT =="
mkdir -p "$(dirname "$CONF")"
if [[ -f "$CONF" ]] && grep -qxF "$STANZA" "$CONF"; then
    echo "  $STANZA already present in $CONF — leaving as is"
else
    { [[ -s "$CONF" ]] && printf '\n'; printf '%s\n' "$STANZA"; } >> "$CONF"
    echo "  added $STANZA to $CONF"
fi

echo
echo "== Fix ownership =="
chown "$SPLUNK_USER:$SPLUNK_GROUP" "$CONF"

echo
echo "== Restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. aio1 is now listening for forwarded data on port $RECEIVING_PORT."
