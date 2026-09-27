#!/usr/bin/env bash
#
# Builds the "email_data" app (the lab has you create this via Manage Apps ->
# Create app in the GUI; this does the equivalent directly on disk) and
# writes the "mail_dashboard" Simple XML dashboard into it, covering the
# lab's checklist 1a-1i:
#
#   1a  Messages discarded (count)                  -> single value
#   1b  Messages delivered (stat=Sent) by hour       -> line chart
#   1c  Messages successfully delivered (count)      -> single value
#   1d  Non-"Sent" recipients: qid, from, size        -> table
#   1e  Average sending delay by hour                -> line chart
#   1f  Top 10 senders by message count              -> bar chart
#   1g  Top 10 recipients by message count           -> bar chart
#   1h  Top 10 senders by message size               -> column chart
#   1i  Top 10 recipients by message size (stitched  -> column chart
#       across the "size" event and the "to" event via the shared qid)
#
# Panel layout follows the lab's sketch (1c/1a, 1b/1d, 1e, 1f/1g, 1h/1i).
#
# ASSUMPTIONS (verify once real data is flowing, per the lab's "Meet your
# data" sendmail-style sample): "stat", "from", "to", "size", and "delay" are
# assumed to be auto key=value-extracted by Splunk directly from the raw
# sendmail log line (e.g. "... stat=Sent ... delay=00:00:01 ...") — these are
# NOT added to props.conf here. "qid", "pid", and "milter_action" are the
# custom EXTRACT-* fields built in
# build_scci_sourcetype_email_log_props.sh. If the real sample's field names
# differ, fix them there (index-time/props) rather than in this dashboard.
#
# Run this ON aio1 ONLY (it's a search-side app, and aio1 is also the search
# head in this single-instance lab).
#
# Idempotent: won't overwrite an existing mail_dashboard.xml — remove it
# first (or edit it directly) to replace.
#
#   sudo ./build_scci_email_dashboard.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="${APPS_DIR:-$SPLUNK_HOME/etc/apps}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
APP_NAME="${APP_NAME:-email_data}"
DASHBOARD_NAME="${DASHBOARD_NAME:-mail_dashboard}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

DEST_APP_PATH="$APPS_DIR/$APP_NAME"
VIEWS_DIR="$DEST_APP_PATH/default/data/ui/views"

echo "== $APP_NAME app scaffolding =="
mkdir -p "$DEST_APP_PATH/default" "$DEST_APP_PATH/metadata" "$VIEWS_DIR"

if [[ ! -f "$DEST_APP_PATH/default/app.conf" ]]; then
    cat > "$DEST_APP_PATH/default/app.conf" <<'EOF'
[install]
state = enabled

[package]
check_for_updates = false

[ui]
is_visible = true
label = Email Data
EOF
    echo "  created $DEST_APP_PATH/default/app.conf"
else
    echo "  $DEST_APP_PATH/default/app.conf already exists — leaving as is"
fi

if [[ ! -f "$DEST_APP_PATH/metadata/local.meta" ]]; then
    cat > "$DEST_APP_PATH/metadata/local.meta" <<'EOF'
[]
access = read : [ * ], write : [ admin ]
export = system
EOF
    echo "  created $DEST_APP_PATH/metadata/local.meta"
else
    echo "  $DEST_APP_PATH/metadata/local.meta already exists — leaving as is"
fi

DASHBOARD_FILE="$VIEWS_DIR/${DASHBOARD_NAME}.xml"
if [[ -f "$DASHBOARD_FILE" ]]; then
    echo "  $DASHBOARD_FILE already exists — leaving as is (remove it first to replace)"
else
    cat > "$DASHBOARD_FILE" <<'EOF'
<dashboard version="1.1">
  <label>Mail Dashboard</label>
  <row>
    <panel>
      <title>1c. Messages Successfully Delivered</title>
      <single>
        <search>
          <query>index=maildata stat=Sent | stats count</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
      </single>
    </panel>
    <panel>
      <title>1a. Messages Discarded</title>
      <single>
        <search>
          <query>index=maildata milter_action=discard | stats count</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
      </single>
    </panel>
  </row>
  <row>
    <panel>
      <title>1b. Messages Delivered by Hour</title>
      <chart>
        <search>
          <query>index=maildata stat=Sent | timechart span=1h count</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
        <option name="charting.chart">line</option>
      </chart>
    </panel>
    <panel>
      <title>1d. Non-Delivered Recipients (qid, from, size)</title>
      <table>
        <search>
          <query>index=maildata stat=* NOT stat=Sent | table qid from size</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
      </table>
    </panel>
  </row>
  <row>
    <panel>
      <title>1e. Average Sending Delay by Hour</title>
      <chart>
        <search>
          <query>index=maildata delay=* | eval delay_sec=(tonumber(substr(delay,1,2))*3600)+(tonumber(substr(delay,4,2))*60)+tonumber(substr(delay,7,2)) | timechart span=1h avg(delay_sec) as avg_delay_sec</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
        <option name="charting.chart">line</option>
      </chart>
    </panel>
  </row>
  <row>
    <panel>
      <title>1f. Top 10 Senders by Message Count</title>
      <chart>
        <search>
          <query>index=maildata from=* | top limit=10 from</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
        <option name="charting.chart">bar</option>
      </chart>
    </panel>
    <panel>
      <title>1g. Top 10 Recipients by Message Count</title>
      <chart>
        <search>
          <query>index=maildata to=* | top limit=10 to</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
        <option name="charting.chart">bar</option>
      </chart>
    </panel>
  </row>
  <row>
    <panel>
      <title>1h. Top 10 Senders by Message Size</title>
      <chart>
        <search>
          <query>index=maildata from=* size=* | stats sum(size) as total_size by from | sort -total_size | head 10</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
        <option name="charting.chart">column</option>
      </chart>
    </panel>
    <panel>
      <title>1i. Top 10 Recipients by Message Size</title>
      <chart>
        <search>
          <query>index=maildata qid=* (size=* OR to=*) | stats first(size) as size first(to) as to by qid | stats sum(size) as total_size by to | sort -total_size | head 10</query>
          <earliest>0</earliest>
          <latest>now</latest>
        </search>
        <option name="charting.chart">column</option>
      </chart>
    </panel>
  </row>
</dashboard>
EOF
    echo "  created $DASHBOARD_FILE"
fi

echo
echo "== Fix ownership =="
chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$DEST_APP_PATH"

echo
echo "Done. Dashboard available at Apps -> Email Data -> Mail Dashboard once"
echo "Splunk picks up the new app (a restart, or wait for the next app scan,"
echo "picks this up — no serverclass involved, this is local to aio1)."
