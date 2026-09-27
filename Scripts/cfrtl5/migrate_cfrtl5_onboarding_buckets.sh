#!/usr/bin/env bash
#
# Migrates the pre-cluster "onboarding" index buckets on idx1 into the
# clustered bucket-naming format, per the lab's "Migrate buckets from a
# non-clustered environment into the Indexer Cluster":
#
#   1. Roll any remaining hot buckets to warm WHILE Splunk is running (a
#      hot bucket can't be safely renamed).
#   2. Stop Splunk.
#   3. Read this host's GUID from etc/instance.cfg.
#   4. Rename every bucket directory under the index's homePath to append
#      "_<GUID>" — this is what makes a cluster peer treat it as a
#      replicable bucket instead of a single-instance one.
#   5. Start Splunk.
#
# Run this ON idx1 (the host holding the pre-existing "onboarding" data) —
# repeat on any other host that was carrying stand-alone data before joining
# the cluster.
#
# NOT idempotent in the traditional sense, but safe to re-run: already-
# suffixed bucket directories are skipped.
#
#   sudo ./migrate_cfrtl5_onboarding_buckets.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_DB="${SPLUNK_DB:-$SPLUNK_HOME/var/lib/splunk}"
INDEX_NAME="${INDEX_NAME:-onboarding}"

# Same admin username/password for every host in this lab — export once per
# shell session:
#   export SPLUNK_ADMIN_USER=admin
#   export SPLUNK_ADMIN_PASSWORD='...'
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:?export SPLUNK_ADMIN_USER first}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:?export SPLUNK_ADMIN_PASSWORD first}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

DB_DIR="$SPLUNK_DB/$INDEX_NAME/db"
[[ -d "$DB_DIR" ]] || { echo "ERROR: $DB_DIR not found — check SPLUNK_DB/INDEX_NAME." >&2; exit 1; }

splunk_cli() {
    sudo -u "$SPLUNK_USER" \
        env SPLUNK_USERNAME="$SPLUNK_ADMIN_USER" SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASSWORD" \
        "$SPLUNK_HOME/bin/splunk" "$@"
}

echo "== Checking for hot buckets under $DB_DIR =="
shopt -s nullglob
HOT_BUCKETS=("$DB_DIR"/hot_*)
shopt -u nullglob

if [[ ${#HOT_BUCKETS[@]} -gt 0 ]]; then
    echo "  found ${#HOT_BUCKETS[@]} hot bucket(s) — rolling hot -> warm (Splunk must be running for this)"
    splunk_cli _internal call "/data/indexes/${INDEX_NAME}/roll-hot-buckets"

    echo "  waiting for hot buckets to clear..."
    for _ in $(seq 1 30); do
        shopt -s nullglob
        HOT_BUCKETS=("$DB_DIR"/hot_*)
        shopt -u nullglob
        [[ ${#HOT_BUCKETS[@]} -eq 0 ]] && break
        sleep 2
    done
    if [[ ${#HOT_BUCKETS[@]} -gt 0 ]]; then
        echo "ERROR: hot buckets still present after waiting — investigate before continuing." >&2
        exit 1
    fi
    echo "  all hot buckets rolled to warm"
else
    echo "  no hot buckets found — skipping straight to the stop/rename steps"
fi

echo
echo "== Stop Splunk (renaming buckets while running is not safe) =="
splunk_cli stop

echo
echo "== Reading this host's GUID from instance.cfg =="
INSTANCE_CFG="$SPLUNK_HOME/etc/instance.cfg"
[[ -f "$INSTANCE_CFG" ]] || { echo "ERROR: $INSTANCE_CFG not found." >&2; exit 1; }
GUID="$(grep -E '^\s*guid\s*=' "$INSTANCE_CFG" | sed 's/^\s*guid\s*=\s*//' | tr -d '[:space:]')"
[[ -n "$GUID" ]] || { echo "ERROR: could not read guid from $INSTANCE_CFG." >&2; exit 1; }
echo "  GUID = $GUID"

echo
echo "== Renaming bucket directories under $DB_DIR to append _$GUID =="
RENAMED=0
for dir in "$DB_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    base="$(basename "$dir")"
    case "$base" in
        *"_${GUID}")
            echo "  $base already suffixed — skipping"
            ;;
        db.* | CoreDB.*)
            # Metadata directories, not bucket directories — leave alone.
            echo "  $base is not a bucket directory — skipping"
            ;;
        *)
            mv "$dir" "${dir}_${GUID}"
            echo "  renamed $base -> ${base}_${GUID}"
            RENAMED=$((RENAMED + 1))
            ;;
    esac
done
echo "  renamed $RENAMED bucket director(y/ies)"

echo
echo "== Start Splunk =="
splunk_cli start

echo
echo "Done. On cm1's UI: Settings -> Indexer Clustering -> Indexes should show"
echo "the onboarding index with buckets now being replicated. On sh1, run"
echo "'| dbinspect index=onboarding' to confirm rb_ (replicated bucket) paths."
