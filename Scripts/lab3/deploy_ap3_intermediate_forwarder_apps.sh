#!/usr/bin/env bash
#
# Builds the three small "org_APP_TEMPLATE"-based apps that configure the
# Intermediate Forwarders (if1, if2) for load-balanced ingestion:
#
#   ap3_intermediate_forwarder_limits              -> local/limits.conf, no throughput cap
#   ap3_all_intermediate_forwarder_pipelines        -> local/server.conf, 2 ingestion pipelines
#   ap3_intermediate_forwarder_inputs               -> local/inputs.conf, splunktcp://9997 receiver
#
# Run this ON the search head (sh1) ONLY. All three are written directly
# under etc/deployment-apps (sh1 doesn't run them itself) — push them out to
# if1/if2 via the "Intermediate_Forwarders" serverclass (whitelist *if*), see
# deploy_ap3_serverclass_config.sh.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_ap3_intermediate_forwarder_apps.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

LIMITS_APP="${LIMITS_APP:-ap3_intermediate_forwarder_limits}"
PIPELINES_APP="${PIPELINES_APP:-ap3_all_intermediate_forwarder_pipelines}"
INPUTS_APP="${INPUTS_APP:-ap3_intermediate_forwarder_inputs}"
LISTEN_PORT="${LISTEN_PORT:-9997}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

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

echo "== $LIMITS_APP: no throughput limit =="
build_base_app "$LIMITS_APP"
ensure_stanza "$DEPLOYMENT_APPS_DIR/$LIMITS_APP/local/limits.conf" "[thruput]" \
'[thruput]
maxKBps = 0'

echo
echo "== $PIPELINES_APP: 2 parallel ingestion pipelines =="
build_base_app "$PIPELINES_APP"
ensure_stanza "$DEPLOYMENT_APPS_DIR/$PIPELINES_APP/local/server.conf" "[general]" \
'[general]
parallelIngestionPipelines = 2'

echo
echo "== $INPUTS_APP: receive from external forwarders on $LISTEN_PORT =="
build_base_app "$INPUTS_APP"
ensure_stanza "$DEPLOYMENT_APPS_DIR/$INPUTS_APP/local/inputs.conf" "[splunktcp://${LISTEN_PORT}]" \
"[splunktcp://${LISTEN_PORT}]"

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" \
    "$DEPLOYMENT_APPS_DIR/$LIMITS_APP" \
    "$DEPLOYMENT_APPS_DIR/$PIPELINES_APP" \
    "$DEPLOYMENT_APPS_DIR/$INPUTS_APP"

echo
echo "Done. Add $LIMITS_APP, $PIPELINES_APP, and $INPUTS_APP to the"
echo "'Intermediate_Forwarders' serverclass next (whitelist *if*)."
