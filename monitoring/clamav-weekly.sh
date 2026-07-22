#!/bin/sh
# Weekly incremental ClamAV scan -> node_exporter textfile metrics.
#
# Incremental without any database: scan only files newer than the marker
# file, which is touched at the start of each run (files that arrive mid-scan
# land in next week's pass). First run bootstraps to the last 30 days instead
# of the full multi-TB volume. Report-only: nothing is quarantined or deleted
# automatically — the ClamavInfected alert surfaces hits for a human call.
#
# Runs from cron (see repo README); uses the ClamAV App Central engine so
# definitions stay updated by the app itself.
CLAM=/usr/local/AppCentral/clamav/bin/clamscan
CLAMDB=/usr/local/AppCentral/clamav/etc/virusdb
BASE=/volume1/configs/monitoring
MARK=$BASE/.clamav-marker
OUT=$BASE/textfile/clamav.prom
LOG=$BASE/clamav-last.log
TARGETS="/volume1/Vault /volume1/configs /volume2/Downloads /volume2/Warehouse-1 /volume3/Warehouse-2"
LIST=/tmp/clamav-list.$$

[ -x "$CLAM" ] || exit 0

# transcoding-temp and cache churn by design (segments vanish mid-scan)
FILTER='-not -path */transcoding-temp/* -not -path */cache/* -not -path */#Recycle/*'
if [ -f "$MARK" ]; then
  find $TARGETS -type f $FILTER -newer "$MARK" 2>/dev/null > "$LIST"
else
  find $TARGETS -type f $FILTER -mtime -30 2>/dev/null > "$LIST"
fi
touch "$MARK"

N=$(wc -l < "$LIST")
START=$(date +%s)
INF=0
RC=0
if [ "$N" -gt 0 ]; then
  nice -n 19 "$CLAM" -d "$CLAMDB" --no-summary -i -f "$LIST" \
    --max-filesize=200M --max-scansize=500M > "$LOG" 2>&1
  RC=$?
  INF=$(grep -c "FOUND$" "$LOG" 2>/dev/null)
  [ -n "$INF" ] || INF=0
fi
END=$(date +%s)

mkdir -p "$BASE/textfile"
{
  echo "nas_clamav_last_scan_timestamp $END"
  echo "nas_clamav_scan_duration_seconds $((END - START))"
  echo "nas_clamav_files_scanned $N"
  echo "nas_clamav_infected_files $INF"
  echo "nas_clamav_scan_exit_code $RC"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
rm -f "$LIST"
