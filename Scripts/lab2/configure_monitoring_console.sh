#!/usr/bin/env bash
#
# Switches this instance's Monitoring Console into distributed mode.
#
# Run this ON the Monitoring Console host (mc1), as root, AFTER you've run
# configure_distributed_search_mc.sh on mc1 to add idx1, idx2, and sh1 as
# search peers (distributed mode needs peers to have anything to monitor).
#
# Idempotent: if distributed mode is already set, this is a no-op.
#
#   sudo ./configure_monitoring_console.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

# Local admin credentials — required, sent via env var, never as a CLI arg.
SPLUNK_ADMIN_USER="admin"
SPLUNK_ADMIN_PASSWORD="4hj2juj6"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$SPLUNK_ADMIN_USER" && -n "$SPLUNK_ADMIN_PASSWORD" ]] || {
    echo "ERROR: SPLUNK_ADMIN_USER / SPLUNK_ADMIN_PASSWORD must be set in this file." >&2
    exit 1
}

CONF="$SPLUNK_HOME/etc/apps/splunk_monitoring_console/local/app.conf"

echo "== Switching Monitoring Console to distributed mode =="
mkdir -p "$(dirname "$CONF")"

if [[ -f "$CONF" ]] && grep -qE '^\s*config\s*=\s*distributed\s*$' "$CONF"; then
    echo "  $CONF already has config = distributed — leaving as is"
elif [[ -f "$CONF" ]] && grep -qxF '[settings]' "$CONF"; then
    if grep -qE '^\s*config\s*=' "$CONF"; then
        sed -i 's/^\s*config\s*=.*/config = distributed/' "$CONF"
        echo "  updated existing config= line to distributed in $CONF"
    else
        sed -i '/^\[settings\]/a config = distributed' "$CONF"
        echo "  added config = distributed under existing [settings] in $CONF"
    fi
else
    { [[ -s "$CONF" ]] && printf '\n'; printf '%s\n' '[settings]' 'config = distributed'; } >> "$CONF"
    echo "  created [settings] stanza with config = distributed in $CONF"
fi

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNK_HOME/etc/apps/splunk_monitoring_console"

echo
echo "== Restart Splunk =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. Monitoring Console is in distributed mode."
echo "Splunk auto-detects each peer's role (indexer / search head) from the peers"
echo "already added via configure_distributed_search_mc.sh; no manual role edits"
echo "are needed for this lab's simple topology."
echo
echo "NOTE: Lab 2 step 7 (\"configure forwarder monitoring in your Monitoring"
echo "Console\") is a Monitoring Console Setup UI wizard step, not a conf file —"
echo "do that manually in the DMC after peers are added."
