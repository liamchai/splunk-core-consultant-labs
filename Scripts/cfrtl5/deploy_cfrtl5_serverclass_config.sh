#!/usr/bin/env bash
#
# Configures the deployment server's serverclass.conf directly — the file
# behind the Forwarder Management UI's "Server Classes" tab — instead of
# clicking through the UI. Run this ON the Deployment Server (mc1).
#
#   all_indexers   -> whitelist idx1, idx2   -> app: cfrtl5_cluster_indexer_base
#   cluster_master -> whitelist cm1          -> app: cfrtl5_cluster_indexer_base
#                                                (same app as all_indexers, per
#                                                the lab's "add the same apps
#                                                that the indexer class has")
#                                                with stateOnClient = noop —
#                                                the lab's step 8, since cm1
#                                                only proxies this content
#                                                onward via the cluster bundle
#                                                rather than "running" it
#                                                locally as an app.
#   all_hosts      -> blacklist cm1          -> cm1 gets its config from the
#                                                cluster_master class (and its
#                                                own manager-apps deployment
#                                                client, see
#                                                deploy_cfrtl5_manager_deploymentclient.sh)
#                                                instead, per the lab's step 9.
#
# This assumes an 'all_hosts' serverclass already exists from earlier setup
# of this environment (this script creates a minimal one if not, but does
# not try to guess what else it should contain).
#
# Run this ON the Deployment Server (mc1), LAST, after
# build_cfrtl5_cluster_indexer_apps.sh so the app referenced below actually
# exists under etc/deployment-apps:
#
#   sudo ./deploy_cfrtl5_serverclass_config.sh
#
# Idempotent: existing stanzas are left untouched, only missing ones are added
# (the all_hosts blacklist entry is inserted into the existing stanza if it's
# missing, without disturbing anything else already there).
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"

CLUSTER_INDEXER_BASE_APP="${CLUSTER_INDEXER_BASE_APP:-cfrtl5_cluster_indexer_base}"

# Client hostnames/IPs as reported by each host's own `hostname` (whatever
# Splunk shows for them in Forwarder Management -> Clients), NOT the lab's
# display names.
IDX1_CLIENT_NAME="idx1-hostname-or-ip"
IDX2_CLIENT_NAME="idx2-hostname-or-ip"
CM1_CLIENT_NAME="cm1-hostname-or-ip"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

CONF="$SPLUNK_HOME/etc/system/local/serverclass.conf"

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

# ensure_blacklisted <file> <serverclass-stanza> <host>
# Adds "blacklist.N = <host>" to an existing stanza (at the next free index),
# or creates the stanza (whitelist * + the blacklist entry) if missing.
# Idempotent: does nothing if <host> is already blacklisted in that stanza.
ensure_blacklisted() {
    local file="$1" stanza="$2" host="$3"
    mkdir -p "$(dirname "$file")"
    touch "$file"

    if ! grep -qxF "$stanza" "$file"; then
        { printf '\n'; printf '%s\n' "$stanza" "whitelist.0 = *" "blacklist.0 = ${host}"; } >> "$file"
        echo "  created $stanza with whitelist.0 = * and blacklist.0 = ${host}"
        return
    fi

    local block
    block="$(awk -v stanza="$stanza" '
        $0 == stanza { in_stanza = 1; next }
        /^\[/ { in_stanza = 0 }
        in_stanza { print }
    ' "$file")"

    if grep -qE "^blacklist\.[0-9]+[[:space:]]*=[[:space:]]*${host}\$" <<<"$block"; then
        echo "  $host already blacklisted in $stanza — leaving as is"
        return
    fi

    local max_idx=-1 idx
    while IFS= read -r idx; do
        [[ -n "$idx" ]] || continue
        (( idx > max_idx )) && max_idx=$idx
    done < <(grep -oE '^blacklist\.[0-9]+' <<<"$block" | grep -oE '[0-9]+')
    local next_idx=$(( max_idx + 1 ))

    awk -v stanza="$stanza" -v line="blacklist.${next_idx} = ${host}" '
        { print }
        $0 == stanza { print line }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    echo "  added blacklist.${next_idx} = ${host} to $stanza"
}

echo "== ServerClass: all_indexers (idx1, idx2) =="
ensure_stanza "$CONF" "[serverClass:all_indexers]" \
"[serverClass:all_indexers]
whitelist.0 = ${IDX1_CLIENT_NAME}
whitelist.1 = ${IDX2_CLIENT_NAME}
restartSplunkd = true"
ensure_stanza "$CONF" "[serverClass:all_indexers:app:${CLUSTER_INDEXER_BASE_APP}]" \
"[serverClass:all_indexers:app:${CLUSTER_INDEXER_BASE_APP}]
restartSplunkd = true"

echo
echo "== ServerClass: cluster_master (cm1) — mirrors all_indexers' apps =="
ensure_stanza "$CONF" "[serverClass:cluster_master]" \
"[serverClass:cluster_master]
whitelist.0 = ${CM1_CLIENT_NAME}
restartSplunkd = true"
ensure_stanza "$CONF" "[serverClass:cluster_master:app:${CLUSTER_INDEXER_BASE_APP}]" \
"[serverClass:cluster_master:app:${CLUSTER_INDEXER_BASE_APP}]
restartSplunkd = true
stateOnClient = noop"

echo
echo "== ServerClass: all_hosts — blacklist cm1 =="
ensure_blacklisted "$CONF" "[serverClass:all_hosts]" "$CM1_CLIENT_NAME"

echo
echo "== Fix ownership =="
chown "$SPLUNK_USER:$SPLUNK_GROUP" "$CONF"

echo
echo "== Reload deployment server =="
sudo -u "$SPLUNK_USER" \
    env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
    "$SPLUNK_HOME/bin/splunk" reload deploy-server

echo
echo "Done. cm1 will pick up $CLUSTER_INDEXER_BASE_APP into its manager-apps"
echo "directory on next phone-home (needs deploy_cfrtl5_manager_deploymentclient.sh"
echo "run on cm1 first). idx1/idx2 get this content by hand-copy instead — see"
echo "migrate_cfrtl5_indexer_to_cluster.sh."
