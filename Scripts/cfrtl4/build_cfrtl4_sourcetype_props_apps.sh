#!/usr/bin/env bash
#
# Builds the 4 cfrtl4_sourcetype_*_props apps (each cloned from
# org_APP_TEMPLATE per the lab), one per sourcetype harvested from aio1:
#   volume-iops, edifecs, sshd_syslog, iis_onboarding
#
# Run harvest_aio1_sourcetypes.sh on aio1 FIRST to find each sourcetype's
# props.conf/transforms.conf content via btool, then paste it into the
# matching *_PROPS_CONTENT / *_TRANSFORMS_CONTENT variable below (leave a
# TRANSFORMS_CONTENT var empty if btool found no transforms for that
# sourcetype).
#
# Run this ON the search head (sh1) ONLY — sh1 is the Deployment Server (DS)
# in this lab. Written under etc/deployment-apps — pushed out to idx1/aio1
# via "all_indexers" AND to mc1 via "all_search_heads" (props/transforms are
# needed on both tiers; Splunk ignores whichever half a given instance
# doesn't need), see deploy_cfrtl4_serverclass_config.sh. sh1 itself needs
# these too but can't deploy to itself — mirror_cfrtl4_search_head_apps.sh
# handles that afterward.
#
# Idempotent: existing content is left untouched; re-running with an updated
# *_CONTENT variable will NOT overwrite an already-written file — edit the
# file directly on a re-run, or remove it first if you need to replace it.
#
#   sudo ./build_cfrtl4_sourcetype_props_apps.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

APP_PREFIX="${APP_PREFIX:-cfrtl4_sourcetype}"

# Paste the harvested [sourcetype] stanza(s) from btool for each. Leave a
# _TRANSFORMS_CONTENT var empty if that sourcetype has no transforms.
VOLUME_IOPS_PROPS_CONTENT="${VOLUME_IOPS_PROPS_CONTENT:-}"
VOLUME_IOPS_TRANSFORMS_CONTENT="${VOLUME_IOPS_TRANSFORMS_CONTENT:-}"

EDIFECS_PROPS_CONTENT="${EDIFECS_PROPS_CONTENT:-}"
EDIFECS_TRANSFORMS_CONTENT="${EDIFECS_TRANSFORMS_CONTENT:-}"

SSHD_SYSLOG_PROPS_CONTENT="${SSHD_SYSLOG_PROPS_CONTENT:-}"
SSHD_SYSLOG_TRANSFORMS_CONTENT="${SSHD_SYSLOG_TRANSFORMS_CONTENT:-}"

IIS_ONBOARDING_PROPS_CONTENT="${IIS_ONBOARDING_PROPS_CONTENT:-}"
IIS_ONBOARDING_TRANSFORMS_CONTENT="${IIS_ONBOARDING_TRANSFORMS_CONTENT:-}"
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

# build_sourcetype_app <suffix> <props-content> <transforms-content>
build_sourcetype_app() {
    local suffix="$1" props="$2" transforms="$3"
    local app="${APP_PREFIX}_${suffix}_props"
    local path="$DEPLOYMENT_APPS_DIR/$app"

    echo "== $app =="
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

    if [[ -n "$props" ]]; then
        if [[ ! -f "$path/local/props.conf" ]]; then
            printf '%s\n' "$props" > "$path/local/props.conf"
            echo "  wrote $path/local/props.conf"
        else
            echo "  $path/local/props.conf already exists — leaving as is"
        fi
    else
        echo "  no props content supplied yet for $suffix — skipping props.conf"
    fi

    if [[ -n "$transforms" ]]; then
        if [[ ! -f "$path/local/transforms.conf" ]]; then
            printf '%s\n' "$transforms" > "$path/local/transforms.conf"
            echo "  wrote $path/local/transforms.conf"
        else
            echo "  $path/local/transforms.conf already exists — leaving as is"
        fi
    else
        echo "  no transforms content supplied for $suffix — skipping transforms.conf"
    fi

    chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$path"
    echo
}

build_sourcetype_app "volume-iops"    "$VOLUME_IOPS_PROPS_CONTENT"    "$VOLUME_IOPS_TRANSFORMS_CONTENT"
build_sourcetype_app "edifecs"        "$EDIFECS_PROPS_CONTENT"        "$EDIFECS_TRANSFORMS_CONTENT"
build_sourcetype_app "sshd_syslog"    "$SSHD_SYSLOG_PROPS_CONTENT"    "$SSHD_SYSLOG_TRANSFORMS_CONTENT"
build_sourcetype_app "iis_onboarding" "$IIS_ONBOARDING_PROPS_CONTENT" "$IIS_ONBOARDING_TRANSFORMS_CONTENT"

echo "Done. Add all 4 ${APP_PREFIX}_*_props apps to BOTH 'all_indexers' and"
echo "'all_search_heads' serverclasses next (see deploy_cfrtl4_serverclass_config.sh)."
