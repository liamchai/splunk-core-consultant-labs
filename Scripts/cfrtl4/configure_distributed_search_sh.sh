#!/usr/bin/env bash
#
# Adds distributed search peers to whichever Splunk instance this is run on.
#
# Per the lab: run this on the Search Head (sh1) with PEERS = idx1 and
# aio1 (aio1 is being migrated to act as idx2).
# (Use configure_distributed_search_mc.sh on mc1 — it needs idx1, aio1, AND
# sh1 as peers.)
#
# Idempotent: peers already registered are skipped.
#
# Run this ON the search head, as root:
#   sudo ./configure_distributed_search_sh.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"

# Same admin username/password for every host in this lab, both for local
# auth and for the remote peers being added — export once per shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"

# `splunk add search-server` only accepts remote credentials as
# -remoteUsername/-remotePassword flags — no env-var form exists for them,
# so unlike the local auth above, this WILL be visible in `ps` output while
# the command runs. Defaults to the same admin creds set above. Per the lab:
# "The admin password for the existing node [aio1] is the same as the lab
# password for sccStudent" — so one set of creds covers both peers.
REMOTE_USER="${REMOTE_USER:-$SPLUNK_ADMIN_USER}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-$SPLUNK_ADMIN_PASSWORD}"

# Peers to add as distributed search peers, as host:mgmt-port — idx1 + aio1(idx2).
PEERS=(
    "idx1-host-or-ip:8089"
    "aio1-host-or-ip:8089"
)
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
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
