#!/usr/bin/env bash
# Merge local result TSV files produced by local/a2-local-check.sh.
# Usage:
#   ./a2-merge-local-results.sh /path/to/local-reports

set -euo pipefail
DIR="${1:-./reports}"
OUT="$DIR/a2-local-merged-results.tsv"
SUMMARY="$DIR/a2-local-merged-summary.txt"

if ! ls "$DIR"/a2-local-*-results.tsv >/dev/null 2>&1; then
  echo "No local result files found in $DIR"
  exit 1
fi

head -n 1 "$(ls "$DIR"/a2-local-*-results.tsv | head -1)" > "$OUT"
for f in "$DIR"/a2-local-*-results.tsv; do
  tail -n +2 "$f" >> "$OUT"
done

awk -F'\t' '
  NR>1 {
    total += $2;
    if ($3=="PASS") pass += $2;
    if ($3=="FAIL") fail += $2;
    if ($3=="WARN") warn += $2;
    if ($3=="SKIP") skip += $2;
    count[$3]++
  }
  END {
    print "A2 Local Checks Merged Summary";
    print "==============================";
    printf "Rows: %d\n", NR-1;
    printf "Passed weighted marks from reported rows: %.2f\n", pass;
    printf "Failed weighted marks from reported rows: %.2f\n", fail;
    printf "Warn weighted marks from reported rows:   %.2f\n", warn;
    printf "Skip weighted marks from reported rows:   %.2f\n", skip;
    print "";
    print "Important: local mode is evidence collection, not a complete automatic final score.";
    print "Use the XLSX marking scheme and remote script when connectivity is available.";
    print "";
    for (s in count) printf "%s: %d\n", s, count[s];
  }
' "$OUT" | tee "$SUMMARY"

echo "Merged: $OUT"
echo "Summary: $SUMMARY"
