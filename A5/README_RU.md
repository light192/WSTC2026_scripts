# Скрипты проверки A5 — Shanghai/Shenzhen

Пакет создан по структуре A4 (унаследованной от A3/A2/A1) для Training A5
«Integrated Enterprise Linux Services» — DNS, OpenLDAP+TLS+SSSD, DHCPv4+relay,
HTTPS-портал с LDAP-аутентификацией, Chrony, central rsyslog, nftables,
Ansible.

- источник задания: `Module A/A5_Competitor_Task_EN_styled.pdf`;
- источник критериев: `A5_Marking_Scheme_Balanced_Championship_Detailed_HowToMark_RU_v2.pdf`;
- карта: `criteria/a5_criteria_map.tsv` — 96 Measurement-аспектов, 25.00 баллов.

## Топология и учётные данные

| Узел | Роль | IP (для SSH) |
|---|---|---|
| idm-a5 | Primary DNS, OpenLDAP, local CA, Chrony server, Ansible control | 10.55.40.10 |
| net-a5 | Secondary DNS, Kea DHCPv4, central rsyslog | 10.55.40.20 |
| portal-a5 | Apache HTTPS portal с LDAP-аутентификацией | 10.55.30.10 |
| sh-gw-a5 | L3 gateway, DHCP relay, nftables (Shanghai) | 10.55.10.1 |
| sh-client-a5 | DHCP client, DNS/LDAP/HTTPS validation | 10.55.10.100 |
| sz-gw-a5 | L3 gateway, DHCP relay, nftables (Shenzhen) | 10.55.20.1 |
| sz-client-a5 | DHCP client, user/evidence workstation | 10.55.20.100 |

Домен: `atlas.a5.test`. Пароль тестовых LDAP-пользователей (nora, erlan) и
корневой пароль по умолчанию: `Skill39@A5`. Пароль bind-аккаунта
`ldap-reader`: `Skill39@A5-Reader` (см. HowToMark).

## Запуск

Рекомендуемый judge/evidence host — **idm-a5 (`10.55.40.10`)**, он же control
node Ansible и место каталога `/opt/grading/a5/`. Из каталога пакета:

```bash
sudo bash remote/a5-evaluate-remote.sh \
  --report-dir /opt/grading/a5/eval-report
```

Без пауз или с нужного аспекта:

```bash
sudo bash remote/a5-evaluate-remote.sh --no-pause \
  --start-from A5.4.06 --report-dir /opt/grading/a5/eval-report
```

Restart/persistence-аспекты (A5.1.10 reboot; A5.3.12, A5.5.12, A5.6.08
restart) по умолчанию получают SKIP. После согласованного restart/reboot:

```bash
sudo bash remote/a5-evaluate-remote.sh --post-reboot \
  --start-from A5.1.10 --report-dir /opt/grading/a5/post-reboot-report
```

## Формат проверки

Перед каждым аспектом выводятся описание, готовая команда How to Mark,
ожидаемый результат, полный stdout/stderr и PASS/FAIL. SSH работает только в
BatchMode с ограниченным timeout. Отчёты:

- `a5-results.tsv`;
- `a5-detail.log`;
- `a5-summary.txt`.

Если DNS не работает, сервис следует повторно проверить по IP и зафиксировать
DNS как primary failure. Отрицательные firewall/LDAP-anonymous/AXFR-проверки
оцениваются по отсутствию успешного результата, а не по exit code команды с
`|| true`. Во время A5.2.12 (проверка secondary-failover) primary BIND9
намеренно останавливается — обязательно перезапустить его после теста
(скрипт делает это автоматически последней командой критерия).

Критерии A5.8.04–A5.8.07 (distinct Ansible common actions) и A5.9.02
(соответствие evidence содержимому задания) требуют финального ручного
подтверждения экспертом: автоматика лишь собирает `--list-tasks`/`--check`
вывод и grep по evidence-файлам, а решение о том, что все четыре категории
различны (иначе — Duplicate category = 0), принимает эксперт.

## Кириллица на голой VGA-консоли (без SSH/X11)

Если evaluator запускается прямо с консоли гипервизора (TERM=linux), а не по
SSH, кириллица может отображаться как псевдографика/значки — это не ошибка
скрипта: в загруженном шрифте консоли просто нет кириллических глифов, хотя
сам вывод в кодировке UTF-8 корректен. Оба скрипта (`remote/a5-evaluate-remote.sh`
и `local/a5-local-check.sh`) сами определяют `TERM=linux` и один раз печатают
подсказку с командами ручного исправления (`setfont`/`dpkg-reconfigure
console-setup`) — **эта подсказка намеренно написана на ASCII/английском**, а
не на русском: если шрифт не поддерживает кириллицу, объяснение этого факта
кириллицей никто не прочитает.

Скрипт **не** трогает шрифт консоли автоматически — только печатает подсказку.
Более ранняя версия пробовала сама вызывать `setfont` с первым найденным
кириллическим шрифтом, и на практике это оказалось хуже исходной проблемы:
`setfont` может подхватить неподходящий по размеру шрифт (например, огромный,
рассчитанный на другое разрешение) и испортить вывод прямо посреди сессии, а
не восстановить его. Выбор и загрузка шрифта оставлены оператору вручную —
если что-то пошло не так, `setfont` без аргументов сбрасывает шрифт к
дефолтному.

Проще всего — подключаться к idm-a5 по SSH из обычного терминала: там эта
проблема не возникает. На PASS/FAIL и итоговые баллы это не влияет — отчёты
(`a5-results.tsv` и др.) всегда пишутся корректным UTF-8 независимо от того,
что видно на экране.

## Локальный fallback

На недоступном по SSH узле:

```bash
sudo bash local/a5-local-check.sh --no-pause \
  --report-dir /opt/grading/a5/local-report
```

Объединение локальных результатов:

```bash
bash utils/a5-merge-local-results.sh /opt/grading/a5/local-report
```

Переменные:

```bash
export A5_DOMAIN='atlas.a5.test'
export A5_ROOT_PASS='Skill39@A5'
export A5_LDAP_USER_PASS='Skill39@A5'
export A5_LDAP_READER_PASS='Skill39@A5-Reader'
export A5_TIMEOUT=6
export A5_CMD_TIMEOUT=180
```
