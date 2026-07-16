# B2 Local Evaluation Scripts

Пакет создан по заданию `B2_Competitor_Task_EN_clean_snapshot_styled.pdf` и
актуальной схеме `B2_marking_scheme_CIS_published_topology_25_final.xlsx`.

Каждый скрипт запускается локально на соответствующем хосте. WinRM, SSH и
другой удаленный запуск для выполнения проверок не используются.

PowerShell следует открыть от имени Administrator. На domain/PKI-хостах
учетная запись должна иметь права чтения соответствующих AD, CA и template
объектов; скрипт не хранит и не подставляет пароли.

## Запуск

Из каталога `B2` выполните скрипт текущего хоста:

```powershell
powershell -ExecutionPolicy Bypass -File .\hosts\check-SHA-CL01.ps1
```

Либо используйте автоопределение по `$env:COMPUTERNAME`:

```powershell
powershell -ExecutionPolicy Bypass -File .\local\b2-local-check.ps1
```

Созданы локальные скрипты для:

- `SHA-RTR01`, `BJ-RTR01`;
- `SHA-DC01`, `BJ-DC02`, `BJ-SRV01`, `SHA-FS01`;
- `SHA-WEB01`, `SHA-APP01`;
- `SHA-CL01`, `BJ-CL01`;
- `INET-SRV01`, `INET-CL01`.

ISP-узлы не включены: в задании они преднастроены и не являются первичными
оцениваемыми объектами B2.

## Продолжение и паузы

По умолчанию после каждого аспекта требуется нажать Enter. Продолжить с
конкретного аспекта:

```powershell
.\hosts\check-BJ-SRV01.ps1 -StartFromAspect F1.05
```

Отключить паузы:

```powershell
.\hosts\check-BJ-SRV01.ps1 -NoPause
```

## Отчеты

Отчет по умолчанию отключен. Включить его можно параметром `-Report` или
указанием `-ReportDir`:

```powershell
.\hosts\check-SHA-WEB01.ps1 -Report
.\hosts\check-SHA-WEB01.ps1 -ReportDir C:\B2-report
```

Создаются `b2-detail.log`, `b2-results.tsv` и `b2-summary.txt`.

## Вывод и оценка

Для каждого аспекта показываются исходная команда из marking scheme,
ожидаемый результат, реально выполненная команда, полный фактический вывод,
строки, использованные автоматической проверкой, и решение `PASS`, `FAIL` или
`WARN`.

`WARN` используется только там, где права CA/template представлены security
descriptor и требуют визуального подтверждения по показанным строкам.

Каждый аспект относится ровно к одному локальному хосту и имеет уникальный
номер. Исходные требования, охватывающие несколько хостов, разделены на
отдельные локальные аспекты; их баллы также разделены. Поэтому результаты всех
12 хостов можно складывать: общая сумма составляет ровно 25,00 балла.

Скрипты CDP/AIA не предполагают фиксированные имена `.crl`/`.cer`: реальные
URL извлекаются из portal certificate, после чего запрашиваются конкретные
опубликованные файлы.

## Структура

- `common\b2-common.ps1` - общий движок и evaluators;
- `criteria\b2_criteria_map.tsv` - 85 локальных аспектов актуальной host-based схемы; поле
  `OriginalAspectID` используется только для совместимости с evaluator;
- `hosts\check-*.ps1` - локальные точки запуска;
- `local\b2-local-check.ps1` - автоопределение текущего хоста.
