# B4 Local Evaluation Scripts

Пакет создан по `B4_Competitor_Task_EN_styled.pdf` и
`B4_marking_scheme_by_device_25_final.xlsx` с использованием структуры и
приёмов B1–B3. Он содержит 106 измеримых аспектов на 25,00 балла. Критерии
сгруппированы по устройству, на котором эксперт выполняет проверку.

Проверяются routing/DHCP Relay, AD DS, DNS, DHCP, OU, группы и пользователи,
domain account policy, local administrator GPO, Windows Firewall/WinRM,
Defender, Advanced Audit Policy, Security log, Windows Event Forwarding,
security validation и local submission.

## Запуск

PowerShell запустите от имени Administrator:

```powershell
cd C:\B4
powershell -ExecutionPolicy Bypass -File .\local\b4-local-check.ps1
```

Либо используйте конкретную точку входа:

```powershell
.\hosts\check-SHA-DC01.ps1
.\hosts\check-BJ-SRV01.ps1 -NoPause -Report
.\hosts\check-SHA-CL01.ps1 -StartFromAspect SHA-CL01-08
```

Поддерживаются `SHA-RTR01`, `BJ-RTR01`, `SHA-DC01`, `BJ-DC02`, `SHA-FS01`,
`BJ-SRV01`, `SHA-CL01`, `BJ-CL01`, `INET-CL01`. Девять submission-аспектов
проверяются на `SHA-CL01`.

## Информативный результат

Перед каждым аспектом выводятся:

- исходная команда marking scheme, пригодная для копирования;
- точные проверяемые свойства и ожидаемый результат;
- полная команда автоматической проверки;
- полный фактический вывод;
- отдельная строка `[PASS]` или `[FAIL]` для каждого IP, route, DNS/DHCP
  параметра, объекта, membership, события, порта или файла.

Составные критерии получают пропорциональный `PART`. Например, если из четырёх
обязательных WinRM endpoints доступны три, начисляется 3/4 максимального балла
аспекта. `WARN` используется только там, где безопасное локальное чтение не
может заменить экспертное/интерактивное подтверждение.

## Отчёты

Параметр `-Report` создаёт `reports\<HOST>`, а `-ReportDir` задаёт другой
каталог:

- `b4-detail.log` — команды и полный evidence;
- `b4-results.tsv` — максимальный и фактически начисленный балл;
- `b4-summary.txt` — локальная сумма PASS/PART/FAIL/WARN.

## Структура

- `common\b4-common.ps1` — общий движок и evaluators;
- `criteria\b4_device_criteria_map.tsv` — рабочая карта 106 аспектов;
- `criteria\b4_device_criteria_map.xlsx` — исходная device-oriented таблица;
- `hosts\check-*.ps1` — локальные точки входа;
- `local\b4-local-check.ps1` — автоопределение по `COMPUTERNAME`;
- `tools\build_b4_map.py` — воспроизводимое построение TSV из официального XLSX.

Скрипты предназначены для чтения и оценки конфигурации. Исключение — сами
functional команды задания (например, TCP validation), которые не меняют
оцениваемую конфигурацию.
