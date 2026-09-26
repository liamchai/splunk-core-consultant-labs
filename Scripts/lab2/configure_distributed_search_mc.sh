#!/usr/bin/env bash
#
# Adds distributed search peers to whichever Splunk instance this is run on.
#
# Per the lab: run this on the Monitoring Console (mc1) with PEERS = the 2
# indexers PLUS the search head.
#
# Idempotent: peers already registered are skipped.
#
# Run this ON the monitoring console, as root:
#   sudo ./configure_distributed_search_mc.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"

# Local admin credentials (this instance) — required, sent via env var, never
# as a CLI arg.
SPLUNK_ADMIN_USER="admin"
SPLUNK_ADMIN_PASSWORD="4hj2juj6"

# Credentials on the REMOTE peers being added. NOTE: `splunk add search-server`
# only accepts these as -remoteUsername/-remotePassword flags — the Splunk CLI
# has no env-var form for them, so unlike the local auth above, this value
# WILL be visible in `ps` output while the command runs.
REMOTE_USER="admin"
REMOTE_PASSWORD="4hj2juj6"
# Peers to add as distributed search peers, as host:mgmt-port — idx1 + idx2 + sh1.
PEERS=(
    "13.59.91.113:8089"
    "18.217.215.36:8089"
    "3.150.109.220:8089"
)
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[[ -n "$SPLUNK_ADMIN_USER" && -n "$SPLUNK_ADMIN_PASSWORD" ]] || {
    echo "ERROR: SPLUNK_ADMIN_USER / SPLUNK_ADMIN_PASSWORD must be set in this file." >&2
    exit 1
}
[[ -n "$REMOTE_USER" && -n "$REMOTE_PASSWORD" ]] || {
    echo "ERROR: REMOTE_USER / REMOTE_PASSWORD must be set in this file." >&2
    exit 1
}
[[ ${#PEERS[@]} -gt 0 ]] || { echo "ERROR: PEERS list is empty — fill it in." >&2; exit 1; }

splunk_cli() {
    sudo -u "$SPLUNK_USER" \
        env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
        "$SPLUNK_HOME/bin/splunk" "$@"
}

echo "== Configuring distributed search peers =="
EXISTING_PEERS="$(splunk_cli list search-server || true)"

for peer in "${PEERS[@]}"; do
    if grep -qF "$peer" <<<"$EXISTING_PEERS"; then
        echo "  $peer already a search peer — skipping"
        continue
    fi
    echo "  adding $peer as a search peer"
    splunk_cli add search-server -host "https://${peer}" \
        -remoteUsername "$REMOTE_USER" -remotePassword "$REMOTE_PASSWORD"
done

echo
echo "== Current search peers =="
splunk_cli list search-server

echo
echo "Done."
