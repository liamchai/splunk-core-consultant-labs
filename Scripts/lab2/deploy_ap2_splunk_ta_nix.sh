#!/usr/bin/env bash
#
# Installs the Splunk Add-on for Unix and Linux (Splunk_TA_nix) from a local
# tarball and enables the inputs the lab asks for, plus routes its data to
# the "os" index.
#
# You must download the tarball yourself first — Splunkbase requires a
# logged-in browser session, so this one step can't be scripted. Get it from
# https://splunkbase.splunk.com/app/833 and stage it on this host, then point
# TA_TARBALL_PATH below at it.
#
# Run this ON the search head (sh1):
#   sudo ./deploy_ap2_splunk_ta_nix.sh
# It builds the app under etc/apps AND mirrors it into etc/deployment-apps
# (lab step: "Put the app into both the apps and deployment-apps folders on
# your search head"). The deployment-apps copy is what gets pushed to the
# indexers/mc/uf via the "All_Linux_Hosts" serverclass — see
# deploy_ap2_serverclass_config.sh.
#
# Idempotent: `splunk install app` is safe to re-run (updates in place), and
# inputs.conf stanzas already present are left untouched.
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

# Splunkbase's canonical folder name for this add-on — don't rename it, the
# lab doesn't ask you to.
APP_NAME="Splunk_TA_nix"

# Path to the tarball you downloaded from Splunkbase.
TA_TARBALL_PATH="/opt/splunk-add-on-for-unix-and-linux.tgz"

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

DEST_APP_PATH="$APPS_DIR/$APP_NAME"

splunk_cli() {
    sudo -u "$SPLUNK_USER" \
        env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
        "$SPLUNK_HOME/bin/splunk" "$@"
}

echo "== Install/update $APP_NAME from tarball =="
if [[ -d "$DEST_APP_PATH" ]]; then
    echo "  $DEST_APP_PATH already exists — skipping install, will only touch local/inputs.conf."
else
    [[ -f "$TA_TARBALL_PATH" ]] || {
        echo "ERROR: $TA_TARBALL_PATH not found." >&2
        echo "Download the Splunk Add-on for Unix and Linux from Splunkbase" >&2
        echo "(https://splunkbase.splunk.com/app/833), stage it on this host, and" >&2
        echo "set TA_TARBALL_PATH at the top of this script." >&2
        exit 1
    }
    splunk_cli install app "$TA_TARBALL_PATH" -update 1
fi

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

echo
echo "== Enable required inputs in local/inputs.conf =="
INPUT_STANZAS=(
    "script://./bin/vmstat.sh"
    "script://./bin/iostat.sh"
    "script://./bin/ps.sh"
    "script://./bin/top.sh"
    "script://./bin/netstat.sh"
    "script://./bin/bandwidth.sh"
    "script://./bin/protocol.sh"
    "script://./bin/openPorts.sh"
    "script://./bin/time.sh"
    "script://./bin/lsof.sh"
    "script://./bin/df.sh"
    "script://./bin/who.sh"
    "script://./bin/usersWithLoginPrivs.sh"
    "script://./bin/lastlog.sh"
    "script://./bin/interfaces.sh"
    "script://./bin/cpu.sh"
    "script://./bin/rlog.sh"
    "script://./bin/package.sh"
    "script://./bin/hardware.sh"
    "monitor:///var/log"
)

INPUTS_CONF="$DEST_APP_PATH/local/inputs.conf"
for stanza in "${INPUT_STANZAS[@]}"; do
    ensure_stanza "$INPUTS_CONF" "[$stanza]" \
"[$stanza]
disabled = false"
done

ensure_stanza "$INPUTS_CONF" "[default]" \
'[default]
index = os'

if [[ ! -f "$DEST_APP_PATH/metadata/local.meta" ]]; then
    ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'
fi

echo
echo "== Mirroring app to $DEPLOYMENT_APPS_DIR/$APP_NAME =="
mkdir -p "$DEPLOYMENT_APPS_DIR/$APP_NAME"
cp -a "$DEST_APP_PATH/." "$DEPLOYMENT_APPS_DIR/$APP_NAME/"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH" "$DEPLOYMENT_APPS_DIR/$APP_NAME"

echo
echo "== Restart Splunk =="
splunk_cli restart

echo
echo "Done. $APP_NAME installed with required inputs enabled, index=os, and"
echo "mirrored into deployment-apps. Run deploy_ap2_serverclass_config.sh next"
echo "to push it out via the deployment server."
