#!/usr/bin/env bash
#
# Builds the two apps that implement content-based index routing:
#
#   ap3_sherlock_props   (from org_APP_TEMPLATE) -> transforms.conf + props.conf
#                         that reroute events containing "Sherlock"/"Watson"/
#                         "Moriarty" out of the default "sherlock" sourcetype
#                         destination into their own indexes.
#   ap3_sherlock_inputs   (from org_dept_app_inputs) -> monitors /opt/data/*.log
#                         on the external forwarders, tagging events with
#                         sourcetype=sherlock and defaulting to index=novels.
#
# Run this ON the search head (sh1) ONLY. Written under etc/deployment-apps:
#   ap3_sherlock_props  -> push to idx1/idx2 via "All_Indexers"
#   ap3_sherlock_inputs -> push to uf1-4 via "Remote_Forwarders"
# Run deploy_ap3_all_indexes.sh first so the sherlock/watson/moriarty/novels
# indexes these route into already exist.
#
# Idempotent: existing stanzas are left untouched, only missing ones are added.
#
#   sudo ./deploy_ap3_sherlock_routing.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DEPLOYMENT_APPS_DIR="${DEPLOYMENT_APPS_DIR:-$SPLUNK_HOME/etc/deployment-apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

PROPS_APP="${PROPS_APP:-ap3_sherlock_props}"
INPUTS_APP="${INPUTS_APP:-ap3_sherlock_inputs}"
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

PROPS_APP_PATH="$DEPLOYMENT_APPS_DIR/$PROPS_APP"

echo "== $PROPS_APP: routing transforms + props =="
mkdir -p "$PROPS_APP_PATH/local" "$PROPS_APP_PATH/metadata"

ensure_stanza "$PROPS_APP_PATH/local/app.conf" "[install]" \
'[install]
state = enabled'
ensure_stanza "$PROPS_APP_PATH/local/app.conf" "[package]" \
'[package]
check_for_updates = false'
ensure_stanza "$PROPS_APP_PATH/local/app.conf" "[ui]" \
'[ui]
is_visible = false
is_manageable = false'

ensure_stanza "$PROPS_APP_PATH/local/transforms.conf" "[sherlock_routing]" \
'[sherlock_routing]
REGEX = Sherlock
DEST_KEY = _MetaData:Index
FORMAT = sherlock'

ensure_stanza "$PROPS_APP_PATH/local/transforms.conf" "[watson_routing]" \
'[watson_routing]
REGEX = Watson
DEST_KEY = _MetaData:Index
FORMAT = Watson'

ensure_stanza "$PROPS_APP_PATH/local/transforms.conf" "[moriarty_routing]" \
'[moriarty_routing]
REGEX = Moriarty
DEST_KEY = _MetaData:Index
FORMAT = Moriarty'

ensure_stanza "$PROPS_APP_PATH/local/props.conf" "[sherlock]" \
'[sherlock]
TRANSFORMS-routing=sherlock_routing, watson_routing, moriarty_routing'

ensure_stanza "$PROPS_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

INPUTS_APP_PATH="$DEPLOYMENT_APPS_DIR/$INPUTS_APP"

echo
echo "== $INPUTS_APP: monitor /opt/data on external forwarders =="
mkdir -p "$INPUTS_APP_PATH/local" "$INPUTS_APP_PATH/metadata"

ensure_stanza "$INPUTS_APP_PATH/local/app.conf" "[install]" \
'[install]
state = enabled'
ensure_stanza "$INPUTS_APP_PATH/local/app.conf" "[package]" \
'[package]
check_for_updates = false'
ensure_stanza "$INPUTS_APP_PATH/local/app.conf" "[ui]" \
'[ui]
is_visible = false
is_manageable = false'

ensure_stanza "$INPUTS_APP_PATH/local/inputs.conf" "[monitor:///opt/data/*.log]" \
'[monitor:///opt/data/*.log]
index = novels
sourcetype = sherlock
disabled = false'

ensure_stanza "$INPUTS_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$PROPS_APP_PATH" "$INPUTS_APP_PATH"

echo
echo "Done. Add $PROPS_APP to 'All_Indexers' and $INPUTS_APP to"
echo "'Remote_Forwarders' next (see deploy_ap3_serverclass_config.sh)."
