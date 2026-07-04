# A1 Evaluation Scripts — Shanghai–Shenzhen Revised

Пакет предназначен для проверки тренировочного задания A1 по топологии Shanghai–Shenzhen.

## Рекомендуемая схема запуска

Основной вариант — запускать удалённую проверку с `sz-client-a1`.

Почему `sz-client-a1`:

- это evidence/check host по заданию;
- он находится внутри Shenzhen client network;
- при корректной маршрутизации должен видеть Shanghai и серверные сети;
- запуск с него позволяет сразу выявить проблемы маршрутизации, DNS, LDAP/SSSD, web, NFS/Samba, firewall и syslog.

```bash
cd A1_Evaluation_Scripts_Shanghai_Shenzhen
sudo bash remote/a1-evaluate-remote.sh --report-dir /opt/grading/a1/eval-report
```

По умолчанию evaluator делает паузу после каждого проверенного аспекта, чтобы эксперт мог прочитать команду, ожидаемый результат и фактический вывод. Для непрерывного запуска используйте:

```bash
sudo bash remote/a1-evaluate-remote.sh --no-pause --report-dir /opt/grading/a1/eval-report
```

Если проверка была остановлена, её можно продолжить с нужного критерия или подаспекта:

```bash
sudo bash remote/a1-evaluate-remote.sh --start-from A4.6 --report-dir /opt/grading/a1/eval-report
```

`--start-from A4` начинает с `A4.1`, `--start-from A4.6` — с конкретного подаспекта. Обычно указывайте первый незавершенный подаспект. В режиме `--start-from` существующие `a1-results.tsv` и `a1-detail.log` в указанной директории не затираются: новые результаты дописываются в конец.

После перезагрузки всех VM можно повторить только post-reboot логику в общем прогоне:

```bash
sudo bash remote/a1-evaluate-remote.sh --post-reboot --report-dir /opt/grading/a1/eval-report-postreboot
```

## Если связности нет

Если remote-проверка не может подключиться к части VM, используйте локальный режим:

1. Скопируйте пакет на нужный хост.
2. Запустите локальный скрипт на каждой VM:

    ```bash
    sudo bash local/a1-local-check.sh --report-dir /root/a1-local-report
    ```

3. Соберите файлы `a1-local-*-results.tsv` и `a1-local-*-detail.log` с хостов.
4. Объедините результаты:

    ```bash
    bash utils/a1-merge-local-results.sh ./reports
    ```

Локальный режим не является полноценной заменой remote-проверки: он собирает evidence и проверяет локальную конфигурацию, когда end-to-end connectivity отсутствует.

## Файлы пакета

| Файл | Назначение |
| --- | --- |
| `remote/a1-evaluate-remote.sh` | основной удалённый evaluator |
| `local/a1-local-check.sh` | локальная проверка на отдельной VM |
| `common/a1-common.sh` | общие функции, цвета, PASS/FAIL/summary |
| `utils/a1-merge-local-results.sh` | объединение локальных TSV-отчётов |
| `criteria/a1_criteria_map.tsv` | карта критериев из marking scheme |
| `remote/a1-hosts.conf` | справочная карта IP-адресов |

## Отчёты

Remote evaluator создаёт:

```text
a1-results.tsv
a1-detail.log
a1-summary.txt
```

Local checker создаёт:

```text
a1-local-<hostname>-results.tsv
a1-local-<hostname>-detail.log
a1-summary.txt
```

## Важные замечания

1. Скрипты используют root SSH key. Если ключ удалён участником, часть remote-проверок будет недоступна.
2. Remote evaluator подключается по IP-адресам, а не по DNS-именам, чтобы DNS-ошибки не ломали всю проверку.
3. Проверки `--post-reboot` запускайте только после ручной перезагрузки VM и восстановления доступности.
4. Скрипты не заменяют экспертное решение в спорных случаях: особенно для dependency failures, DNS/FQDN vs IP, firewall source matching и reboot persistence.
5. Для точной оценки используйте итоговый XLSX marking scheme вместе с `a1-results.tsv`.
