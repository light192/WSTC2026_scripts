#!/usr/bin/env bash
set -euo pipefail
DIR="${1:-/opt/grading/a3/local-report}"
OUT="$DIR/a3-local-merged-results.tsv"
printf 'CriterionID\tMaxMark\tStatus\tMessage\tSourceFile\n' > "$OUT"
for f in "$DIR"/a3-local-*-results.tsv; do
  [ -f "$f" ] || continue
  awk -F'\t' -v src="$(basename "$f")" 'NR>1 {print $0 "\t" src}' "$f" >> "$OUT"
done
echo "$OUT"
