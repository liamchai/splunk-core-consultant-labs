#!/usr/bin/env bash
#
# Creates /opt/splunkdata and gives it to the splunk user — the non-default
# storage location the volume-based indexes apps (ap3_indexer_volume_indexes,
# ap3_search_volume_indexes) point at.
#
# Run this ON every host that stores index data: idx1, idx2 (indexers) AND
# sh1, mc1 (search heads — same location per the lab, "For this practice lab
# we will keep them the same").
#
# Idempotent: safe to re-run.
#
#   sudo ./prepare_splunkdata_dirs.sh
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SPLUNK_USER="${SPLUNK_USER:-splunk}"
SPLUNK_GROUP="${SPLUNK_GROUP:-$SPLUNK_USER}"
SPLUNKDATA_DIR="${SPLUNKDATA_DIR:-/opt/splunkdata}"
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

echo "== Creating $SPLUNKDATA_DIR =="
mkdir -p "$SPLUNKDATA_DIR"
chown "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNKDATA_DIR"

echo
echo "Done. $SPLUNKDATA_DIR owned by $SPLUNK_USER:$SPLUNK_GROUP"
