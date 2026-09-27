#!/usr/bin/env bash
#
# Discovery helper — NOT idempotent, NOT a deploy script. Run this ON aio1 to
# find, via btool, where the GUI wrote the settings for:
#   - the "onboarding" index
#   - the volume-iops, edifecs, sshd_syslog, and iis_onboarding sourcetypes
#
# It just prints btool's debug output (which shows the FILE each setting
# came from, plus the stanza content) so you can copy the relevant stanzas
# into:
#   - ONBOARDING_INDEX_STANZA in deploy_cfrtl4_all_indexes.sh (run on sh1)
#   - the *_PROPS_CONTENT / *_TRANSFORMS_CONTENT vars in
#     build_cfrtl4_sourcetype_props_apps.sh (run on sh1)
#
# Run this ON aio1, as root or the splunk user:
#   sudo ./harvest_aio1_sourcetypes.sh
#
set -euo pipefail

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SOURCETYPES=(volume-iops edifecs sshd_syslog iis_onboarding)

btool_cli() {
    sudo -u "$SPLUNK_USER" "$SPLUNK_HOME/bin/splunk" "$@"
}

echo "############################################################"
echo "# indexes.conf — look for the 'onboarding' stanza and its file"
echo "############################################################"
btool_cli btool indexes list onboarding --debug || \
    echo "(no 'onboarding' stanza found via btool — check the index name)"

for st in "${SOURCETYPES[@]}"; do
    echo
    echo "############################################################"
    echo "# props.conf — sourcetype: $st"
    echo "############################################################"
    btool_cli btool props list "$st" --debug || \
        echo "(no props stanza found for $st)"

    echo
    echo "############################################################"
    echo "# transforms.conf referenced by $st (if any) — look at the"
    echo "# TRANSFORMS-* / REPORT-* keys above, then look each one up:"
    echo "#   splunk btool transforms list <name> --debug"
    echo "############################################################"
done

echo
echo "Done. For each TRANSFORMS-*/REPORT-* class name printed above, run:"
echo "  sudo -u $SPLUNK_USER $SPLUNK_HOME/bin/splunk btool transforms list <name> --debug"
echo "to get its transforms.conf stanza and originating file."
echo
echo "The --debug output's leading path (before the stanza) tells you which"
echo "file to look at directly, and — per the lab's 'Make the Single Instance"
echo "a Deployment Client' step — which non-.conf-renamed file to remove/"
echo "rename later so the DS-pushed copies take over cleanly."
