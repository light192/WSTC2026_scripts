# C5 checker

Read-only скрипт проверки Training C5 в формате и на консольном движке C3/C4.
Он загружает 100 аспектов официальной схемы оценки (25,00 балла), подключается
к устройствам активной PNETLab-сессии и выводит требования, команды, фактическое
evidence и результат `PASS/PART/FAIL/SKIP`.

## Запуск

При необходимости измените URL и учётные данные в `creds.json`, затем:

```powershell
py -m pip install -r .\C5\requirements.txt
py .\C5\c5_check_ios.py
```

Выбор сессии, старт с конкретного аспекта и непрерывный режим:

```powershell
py .\C5\c5_check_ios.py --session-id 4 --start C17 --no-pause
py .\C5\c5_check_ios.py --start D -c
```

`--start` принимает раздел `A`–`G`, ID аспекта или номер `1`–`100`.

## Безопасность и границы автоматизации

Скрипт не меняет конфигурацию и не выполняет destructive tests T1–T8. Для
аспектов, которым обязательно нужен управляемый отказ, injection или negative
test, выводится `SKIP` либо `PART` с точной экспертной процедурой. Это исключает
ложное присвоение баллов только по наличию конфигурации.

Полный `show running-config` для поиска решения не используется. Допускаются
только семь точечных проверок с листа **Restricted Checks**:

- R1 — global baseline;
- R2 — whitelist static routes в startup-config;
- R3 — literal BGP password (секрет не сохраняется в комментариях);
- R4 — DHCP exclusions;
- R5 — отсутствие SNMP community, только при неоднозначном negative test;
- R6 — domain/local user privilege;
- R7 — поля Syslog.

Перед официальной оценкой нужно smoke-test выполнить на точных IOSv/IOSvL2 и
Linux images, зафиксированных в листе **Environment Record**. Интерфейсная карта
в скрипте соответствует опубликованной топологии WSC2026_TD39.
