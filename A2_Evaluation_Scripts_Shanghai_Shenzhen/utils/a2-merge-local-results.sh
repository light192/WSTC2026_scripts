#!/usr/bin/env bash
# Объединить локальные TSV-результаты из local/a2-local-check.sh.
# Использование:
#   ./a2-merge-local-results.sh /path/to/local-reports

set -euo pipefail
DIR="${1:-./reports}"
OUT="$DIR/a2-local-merged-results.tsv"
SUMMARY="$DIR/a2-local-merged-summary.txt"

if ! ls "$DIR"/a2-local-*-results.tsv >/dev/null 2>&1; then
  echo "В $DIR не найдены локальные файлы результатов"
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
    print "Сводка объединенных локальных проверок A2";
    print "==============================";
    printf "Строк: %d\n", NR-1;
    printf "Засчитано баллов из строк отчета:  %.2f\n", pass;
    printf "Не засчитано из строк отчета:      %.2f\n", fail;
    printf "Предупреждения из строк отчета:    %.2f\n", warn;
    printf "Пропущено из строк отчета:         %.2f\n", skip;
    print "";
    print "Важно: локальный режим собирает подтверждения, это не полный автоматический итоговый балл.";
    print "Используйте XLSX-схему оценки и remote-скрипт, когда сетевая доступность восстановлена.";
    print "";
    for (s in count) {
      label=s;
      if (s=="PASS") label="OK";
      if (s=="FAIL") label="Не засчитано";
      if (s=="WARN") label="Предупреждения";
      if (s=="SKIP") label="Пропущено";
      printf "%s: %d\n", label, count[s];
    }
  }
' "$OUT" | tee "$SUMMARY"

echo "Объединено: $OUT"
echo "Сводка: $SUMMARY"
