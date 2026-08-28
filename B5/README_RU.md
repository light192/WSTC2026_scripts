# B5 Local Evaluation Scripts

Пакет создан по `B5_Corrected_Competitor_Task_RU_styled.docx` и
`B5_marking_scheme_corrected_final_revised.xlsx` на основе отлаженной структуры
и проверок B1–B4. Карта содержит 112 измеримых аспектов на 25,00 балла,
сгруппированных по 14 точкам проверки.

Проверяются адресация и маршрутизация, граница workgroup/domain, AD DS, AD
Sites, DNS, DHCP, OU/группы/пользователи, local administrators, WinRM и
firewall, WSL/Ansible, Windows LAPS, AppLocker, BitLocker, gMSA, изоляция и
локальная сдача.

## Запуск

Запустите PowerShell от имени Administrator:

```powershell
cd C:\B5
powershell -ExecutionPolicy Bypass -File .\local\b5-local-check.ps1
```

Или запустите точку конкретного устройства:

```powershell
.\hosts\check-SHA-DC01.ps1 -NoPause -Report
.\hosts\check-SHA-CL01.ps1 -StartFromAspect D-SHA-CL01-01
```

`-Report` создаёт `reports\<HOST>` с полным evidence, TSV-результатами и
локальной суммой. Составной аспект обычно получает пропорциональный `PART`;
для аспектов с прямым указанием `Award only if all` неполная проверка даёт
0 баллов согласно marking scheme.

Автоматический сбор является read-only. Потенциально изменяющие состояние
команды из задания (установка gMSA, запуск scheduled task, запуск playbook)
показываются как команды marking scheme, но не запускаются checker-ом.
Проверку `E-SHA-DC01-05` следует запускать в контексте `NBB5\laps.reader1`;
полученный LAPS password проверяется, но не записывается в отчёт.

Дистрибутивы WSL регистрируются отдельно для каждой Windows-учётной записи.
Checker видит регистрации во всех загруженных профилях, но выполнять команды
может только в дистрибутиве текущего пользователя. Если WSL принадлежит другой
учётной записи, проект и evidence читаются из обязательной копии
`C:\Skills\B5\ansible-b5-export`. Проверку установленных `ansible` и `python3`
следует запускать из сеанса владельца WSL.

## Структура

- `common\b5-common.ps1` — общий движок и evaluators;
- `criteria\b5_device_criteria_map.tsv` — карта 112 аспектов;
- `hosts\check-*.ps1` — локальные точки входа;
- `local\b5-local-check.ps1` — автоопределение по `COMPUTERNAME`;
- `tools\build_b5_map.py` — воспроизводимое построение TSV из XLSX.
- `tools\validate_b5_package.ps1` — статическая проверка структуры, суммы и покрытия ID.
