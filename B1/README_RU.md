# B1 Local Evaluation Scripts

Пакет предназначен для локальной проверки B1 по критериям из файла
`B1_marking_scheme_CIS_published_topology_25_by_host_addressing_updated.xlsx`.

Удаленный запуск через WinRM не используется. На каждом хосте запускается свой
скрипт из каталога `hosts`.

## Запуск

Перейдите в каталог `B1` пакета и запустите скрипт, соответствующий текущему
хосту:

```powershell
powershell -ExecutionPolicy Bypass -File .\hosts\check-SHA-DC01.ps1
```

Можно также использовать автоопределение по имени текущего компьютера:

```powershell
powershell -ExecutionPolicy Bypass -File .\local\b1-local-check.ps1
```

## Скрипты по хостам

- `hosts\check-SHA-RTR01.ps1`
- `hosts\check-BJ-RTR01.ps1`
- `hosts\check-SHA-DC01.ps1`
- `hosts\check-BJ-DC02.ps1`
- `hosts\check-SHA-FS01.ps1`
- `hosts\check-BJ-SRV01.ps1`
- `hosts\check-SHA-CL01.ps1`
- `hosts\check-BJ-CL01.ps1`
- `hosts\check-SHA-WEB01.ps1`
- `hosts\check-SHA-APP01.ps1`
- `hosts\check-INET-SRV01.ps1`
- `hosts\check-INET-CL01.ps1`
- `hosts\check-ISP-SHA01.ps1`
- `hosts\check-ISP-BJ.ps1`

Аспекты `K1.01` и `K1.02` относятся к общей Internet-zone. Они доступны в
локальных скриптах `INET-SRV01`, `INET-CL01`, `ISP-SHA01` и `ISP-BJ`, чтобы
каждый из этих хостов можно было проверить локально.

## Продолжение с нужного аспекта

Если проверка была остановлена, ее можно повторно запустить с нужного аспекта:

```powershell
powershell -ExecutionPolicy Bypass -File .\hosts\check-SHA-DC01.ps1 -StartFromAspect C1.13
```

Все аспекты с меньшим индексом будут пропущены.

## Паузы

По умолчанию после каждого аспекта скрипт ждет Enter. Для запуска без пауз:

```powershell
powershell -ExecutionPolicy Bypass -File .\hosts\check-SHA-DC01.ps1 -NoPause
```

## Отчеты

По умолчанию отчеты отключены: скрипт выводит команды, ожидаемый результат,
фактический вывод и итог только на экран.

Чтобы включить запись отчета в `reports\<HOST>`, используйте `-Report`:

```powershell
powershell -ExecutionPolicy Bypass -File .\hosts\check-SHA-DC01.ps1 -Report
```

Чтобы указать каталог отчета явно, используйте `-ReportDir`. Передача
`-ReportDir` автоматически включает отчет:

```powershell
powershell -ExecutionPolicy Bypass -File .\hosts\check-BJ-SRV01.ps1 -ReportDir C:\B1-report
```

При включенном отчете создаются файлы:

- `b1-detail.log` - подробный журнал команд, ожидаемых результатов, вывода и решений.
- `b1-results.tsv` - табличный результат по аспектам.
- `b1-summary.txt` - краткая сводка.

## Что выводится на экран

Для каждого аспекта выводится:

- индекс и описание аспекта;
- команды из marking scheme;
- ожидаемый результат;
- фактически выполненная локальная команда;
- фактический вывод команды;
- итог `PASS`, `FAIL` или `WARN`.

`WARN` означает, что скрипт показал доказательства, но аспект требует ручной
интерпретации или проверки под конкретной учетной записью.

## Структура

- `common\b1-common.ps1` - общий локальный движок проверки.
- `criteria\b1_criteria_map.tsv` - критерии, извлеченные из XLSX.
- `hosts\check-*.ps1` - отдельные локальные скрипты по хостам.
- `local\b1-local-check.ps1` - совместимая точка входа с автоопределением хоста.
