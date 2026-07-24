#!/usr/bin/env bash
set -euo pipefail
DIR="${1:-/opt/grading/a4/local-report}"
OUT="$DIR/a4-local-merged-results.tsv"
printf 'CriterionID\tMaxMark\tStatus\tMessage\tSourceFile\n' > "$OUT"
for f in "$DIR"/a4-local-*-results.tsv; do
  [ -f "$f" ] || continue
  awk -F'\t' -v src="$(basename "$f")" 'NR>1 {print $0 "\t" src}' "$f" >> "$OUT"
done
echo "$OUT"
