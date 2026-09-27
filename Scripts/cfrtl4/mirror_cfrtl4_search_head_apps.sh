#!/usr/bin/env bash
#
# Copies every app attached to the "all_search_heads" serverclass directly
# into sh1's own etc/apps and restarts Splunk there — the lab step "The
# search head also requires these apps but as it is the deployment server it
# cannot deploy to itself. Copy the apps to the etc/apps folder of your
# search head."
#
# Run this ON the search head (sh1) ONLY, AFTER build_cfrtl4_search_apps.sh,
# deploy_cfrtl4_all_indexes.sh, and build_cfrtl4_sourcetype_props_apps.sh
# have populated etc/deployment-apps.
#
# Idempotent: cp -a overwrites in place, safe to re-run.
#
#   sudo ./mirror_cfrtl4_search_head_apps.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

SEARCH_BASE_APP="${SEARCH_BASE_APP:-cfrtl4_all_search_base}"
FORWARDER_OUTPUTS_APP="${FORWARDER_OUTPUTS_APP:-cfrtl4_all_forwarder_outputs}"
ALL_INDEXES_APP="${ALL_INDEXES_APP:-cfrtl4_all_indexes}"
SEARCH_VOLUME_APP="${SEARCH_VOLUME_APP:-cfrtl4_search_volume_indexes}"
SOURCETYPE_PROPS_PREFIX="${SOURCETYPE_PROPS_PREFIX:-cfrtl4_sourcetype}"
SOURCETYPE_SUFFIXES=(volume-iops edifecs sshd_syslog iis_onboarding)

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

APPS=("$SEARCH_BASE_APP" "$FORWARDER_OUTPUTS_APP" "$ALL_INDEXES_APP" "$SEARCH_VOLUME_APP")
for suffix in "${SOURCETYPE_SUFFIXES[@]}"; do
    APPS+=("${SOURCETYPE_PROPS_PREFIX}_${suffix}_props")
done

for app in "${APPS[@]}"; do
    SRC="$DEPLOYMENT_APPS_DIR/$app"
    DST="$APPS_DIR/$app"
    if [[ ! -d "$SRC" ]]; then
        echo "  SKIP $app — not found under $DEPLOYMENT_APPS_DIR (build it first)"
        continue
    fi
    mkdir -p "$DST"
    cp -a "$SRC/." "$DST/"
    chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DST"
    echo "  mirrored $app -> $DST"
done

echo
echo "== Restart Splunk (applies mirrored apps on sh1) =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" restart

echo
echo "Done. sh1 now has its own local copies of the all_search_heads apps."
