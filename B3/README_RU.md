# B3 Local Evaluation Scripts

Пакет создан по заданию `B3_Competitor_Task_EN_styled.pdf` и marking scheme
`B3_marking_scheme_CIS_published_topology_25_revised.xlsx`. Он проверяет 81
измеримый аспект B3 на общую сумму 25,00 балла. Рабочая карта сгруппирована
по устройствам, поэтому на каждом узле последовательно выводятся все
относящиеся к нему критерии независимо от исходного раздела службы.

Проверяются foundation networking/AD/DNS/DHCP, диски, SMB/NTFS/ABE, iSCSI,
DFS Namespace, DFS Replication, FSRM, Shadow Copies, Windows Server Backup,
restore, client validation и local submission.

## Запуск

PowerShell необходимо открыть от имени Administrator. На domain-хостах
учётная запись должна иметь права чтения AD и соответствующих server roles.
Пароли пользователей скрипты не хранят и автоматически не подставляют.

На любом поддерживаемом хосте:

```powershell
cd C:\B3
powershell -ExecutionPolicy Bypass -File .\local\b3-local-check.ps1
```

Или запустить конкретную точку входа:

```powershell
.\hosts\check-SHA-FS01.ps1
.\hosts\check-BJ-SRV01.ps1 -NoPause -Report
.\hosts\check-SHA-CL01.ps1 -StartFromAspect SCL.08
```

Поддерживаемые узлы: `SHA-RTR01`, `BJ-RTR01`, `SHA-DC01`, `BJ-DC02`,
`SHA-FS01`, `BJ-SRV01`, `SHA-CL01`, `BJ-CL01`.

## Отчёты

По умолчанию отчёт не записывается. Параметр `-Report` создаёт каталог
`reports\<HOST>`, а `-ReportDir C:\B3-report` задаёт другой путь. Создаются:

- `b3-detail.log` — команды, полный вывод и строки evidence;
- `b3-results.tsv` — результат каждого аспекта;
- `b3-summary.txt` — локальная сумма PASS/FAIL/WARN.

`WARN` используется для проверок, где корректный результат нельзя безопасно
получить без интерактивного входа под тестовым пользователем либо требуется
визуальное подтверждение previous version/effective access. Скрипт не выдаёт
за PASS отсутствие ошибки команды.

Перед каждым аспектом выводится полная команда ручной проверки, пригодная для
копирования в Windows PowerShell. Составные проверки выводят отдельные строки
`*_OK`, `*_FAIL` и `*_INFO` для каждого ожидаемого объекта или параметра.
После краткого ожидаемого результата выводится блок `Точные ожидаемые свойства
и значения`, полученный из поля `Requirement (Measurement Only)` исходного
marking scheme. Это поле также сохранено в картах как `ExpectedAttributes`.

## Структура

- `common\b3-common.ps1` — общий движок и evaluators;
- `criteria\b3_device_criteria_map.tsv` — рабочая карта из 81 аспекта,
  сгруппированная по устройствам;
- `criteria\b3_criteria_map.tsv` — исходная карта по разделам служб;
- `hosts\check-*.ps1` — host-local точки запуска;
- `local\b3-local-check.ps1` — автоопределение по `COMPUTERNAME`.

Проверки не изменяют оцениваемую конфигурацию. Исключение не делается даже
для functional access tests: результаты действий под `storage.sh01`,
`storage.bj01` и `auditor.b3` читаются из `C:\Skills\B3\B3-selfcheck.txt`,
чтобы evaluator не хранил пароль участника.
