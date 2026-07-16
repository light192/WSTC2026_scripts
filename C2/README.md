# C2 PNETLab Checker

Автоматизированная оценка Training C2 по 100 Measurement aspects (25 баллов).
Основной файл — `c2_check_ios.py`.

## Запуск

1. Запустите C2 lab в PNETLab. Имя running-сессии по умолчанию должно содержать `module-c`.
2. Проверьте параметры PNETLab и Cisco в `creds.json`.
3. Запустите из каталога `C2`:

```powershell
python .\c2_check_ios.py
```

Начать с критерия, aspect ID или порядкового номера:

```powershell
python .\c2_check_ios.py --start D
python .\c2_check_ios.py --start D10
python .\c2_check_ios.py --start 49
```

Если имя lab отличается:

```powershell
python .\c2_check_ios.py --lab c2
```

По умолчанию после завершения каждого критерия A–F скрипт ждет нажатия
`Enter`, прежде чем перейти к следующему критерию. Для полностью
автоматического запуска без пауз:

```powershell
python .\c2_check_ios.py --no-pause
```

## Принципы оценки

- Используются operational и dedicated show-команды; `show running-config` не используется.
- `PASS` — выполнены все независимые проверки аспекта.
- `PART` — балл рассчитан пропорционально успешным проверкам.
- `FAIL` — проверка не пройдена.
- `SKIP` — аспект требует Linux PC/SVR, точной ручной привязки порта или контролируемого failover-теста экспертом.

Скрипт использует проверенные библиотеки подключения из соседнего каталога `C1` (`pnetlab_lib.py` и `checker_lib.py`), но не импортирует конфликтный `c1_check_ios.py`.
