#!/usr/bin/env bash
#
# Builds the scci_sourcetype_email_log_props app (cloned from
# org_APP_TEMPLATE per the lab) holding BOTH the index-time onboarding
# settings (TIME_PREFIX/TIME_FORMAT/MAX_TIMESTAMP_LOOKAHEAD/LINE_BREAKER/
# SHOULD_LINEMERGE/TRUNCATE) AND the search-time field extractions
# (pid, qid, milter_action, spam_pct) for the "email_log" sourcetype — the
# lab explicitly says both sets of settings belong in the same app.
#
# Written DIRECTLY under aio1's own etc/apps — NOT etc/deployment-apps —
# because "this app must be placed on the host that parses the data. In this
# kind of setup, the indexer (all-in-one) instance bears this
# responsibility," and aio1 (the DS) cannot deploy configuration to itself.
#
# Run this ON aio1 ONLY.
#
# *** IMPORTANT — verify before running ***
# The PROPS_CONTENT default below is a BEST-GUESS starting point based on a
# typical syslog-style sendmail/milter log line, e.g.:
#   Sep 10 08:23:11 mailhost sm-mta[12345]: q2G1H0Wc002825: Milter: data, discard
#   Sep 10 08:24:02 mailhost sm-mta[12345]: q2G1H0Wc002825: milter add header: probability of spam is 87
# The lab expects YOU to inspect the actual gzipped sample files under
# /var/log/mail on the forwarder (gzip -dc maillog-smtp2.1.gz | more) and
# confirm/adjust TIME_FORMAT and the EXTRACT-* regexes against the real data
# before relying on this. Override PROPS_CONTENT (or edit this script) if the
# real format differs.
#
# Idempotent: existing content is left untouched; re-running with an updated
# PROPS_CONTENT will NOT overwrite an already-written file — edit the file
# directly on a re-run, or remove it first if you need to replace it.
#
#   sudo ./build_scci_sourcetype_email_log_props.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
APP_NAME="${APP_NAME:-scci_sourcetype_email_log_props}"

PROPS_CONTENT="${PROPS_CONTENT:-[email_log]
TIME_PREFIX = ^
TIME_FORMAT = %b %d %H:%M:%S
MAX_TIMESTAMP_LOOKAHEAD = 15
LINE_BREAKER = ([\r\n]+)
SHOULD_LINEMERGE = false
TRUNCATE = 10000
EXTRACT-pid_qid = sm-mta\[(?<pid>\d+)\]:\s+(?<qid>\w{14}):
EXTRACT-milter_action = Milter:\s+\w+,\s+(?<milter_action>\w+)
EXTRACT-spam_pct = probability of spam is (?<spam_pct>\d+)}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

DEST_APP_PATH="$APPS_DIR/$APP_NAME"

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

echo "== $APP_NAME =="
mkdir -p "$DEST_APP_PATH/local" "$DEST_APP_PATH/metadata"

ensure_stanza "$DEST_APP_PATH/local/app.conf" "[install]" \
'[install]
state = enabled'
ensure_stanza "$DEST_APP_PATH/local/app.conf" "[package]" \
'[package]
check_for_updates = false'
ensure_stanza "$DEST_APP_PATH/local/app.conf" "[ui]" \
'[ui]
is_visible = false
is_manageable = false'
ensure_stanza "$DEST_APP_PATH/metadata/local.meta" "[]" \
'[]
access = read : [ * ], write : [ admin ]
export = system'

if [[ ! -f "$DEST_APP_PATH/local/props.conf" ]]; then
    printf '%s\n' "$PROPS_CONTENT" > "$DEST_APP_PATH/local/props.conf"
    echo "  wrote $DEST_APP_PATH/local/props.conf"
else
    echo "  $DEST_APP_PATH/local/props.conf already exists — leaving as is"
    echo "  (edit it directly, or remove it first, to apply an updated PROPS_CONTENT)"
fi

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH"

echo
echo "Done. $APP_NAME installed directly on aio1 at $DEST_APP_PATH."
echo "Restart Splunk on aio1 (index-time properties require it):"
echo "  sudo -u $SPLUNK_USER env SPLUNK_USERNAME=\$SPLUNK_ADMIN_USER SPLUNK_PASSWORD=\$SPLUNK_ADMIN_PASSWORD $SPLUNK_HOME/bin/splunk restart"
