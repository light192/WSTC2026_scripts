# A2 Evaluation Scripts - Shanghai/Shenzhen

Пакет сделан по структуре A1: `common`, `criteria`, `remote`, `local`, `utils`.

Основной источник критериев: `Module A/A2_Marking_Scheme_Shanghai_Shenzhen_Detailed_HowToMark_RU.xlsx`.
Карта критериев находится в `criteria/a2_criteria_map.tsv`: 93 пункта, суммарно 25.00 баллов.

## Основной запуск

Рекомендуемая точка запуска по marking scheme: `ops-ws-a2`.

```bash
cd /root/A2_Evaluation_Scripts_Shanghai_Shenzhen
sudo bash remote/a2-evaluate-remote.sh --report-dir /opt/grading/a2/eval-report
```

По умолчанию скрипт делает паузу после каждого аспекта и показывает:

- критерий и описание;
- команды из marking scheme;
- ожидаемый результат;
- фактический вывод команды;
- PASS/FAIL/WARN/SKIP и вес критерия.

Запуск без пауз:

```bash
sudo bash remote/a2-evaluate-remote.sh --no-pause --report-dir /opt/grading/a2/eval-report
```

Продолжить с конкретного критерия после остановки:

```bash
sudo bash remote/a2-evaluate-remote.sh --start-from A2.4.6 --report-dir /opt/grading/a2/eval-report
```

Проверки после согласованной перезагрузки:

```bash
sudo bash remote/a2-evaluate-remote.sh --post-reboot --start-from A2.8.11 --report-dir /opt/grading/a2/eval-report
```

## Локальный запуск

Если remote-доступ недоступен, скопируйте пакет на нужную VM и запустите локальный сбор evidence:

```bash
sudo bash local/a2-local-check.sh --report-dir /opt/grading/a2/local-report
```

Локальный режим выполняет роль-зависимые проверки для текущего hostname:

- `east-edge-a2`, `core-edge-a2`: маршрутизация, forwarding, nftables/drop logs;
- `auth-a2`: DNS, LDAP, PKI/StartTLS, remote logs;
- `repo-a2`: SSSD и `/srv/repo/audit`;
- `portal-a2`: SSSD, HTTPS portal, portal logs;
- `east-ws-a2`, `ops-ws-a2`: SSSD, resolver, HTTPS portal, evidence files на `ops-ws-a2`.

Локальный режим не является полной заменой remote-оценки, потому что часть критериев проверяет взаимодействие между хостами.

## Переменные

Можно переопределить пароли и таймауты через окружение:

```bash
export A2_PASS='Skill39@A2'
export A2_READER_PASS='Skill39@A2reader'
export A2_TIMEOUT=6
export A2_CMD_TIMEOUT=180
```

Для функциональных SSH/sudo-тестов LDAP-пользователей желательно наличие `sshpass` на host запуска. Root SSH проверяется по ключу.

## Файлы отчета

Remote:

- `a2-results.tsv`
- `a2-detail.log`
- `a2-summary.txt`

Local:

- `a2-local-<hostname>-results.tsv`
- `a2-local-<hostname>-detail.log`
- `a2-summary.txt`

Слияние локальных TSV:

```bash
bash utils/a2-merge-local-results.sh /opt/grading/a2/local-report
```

## Копирование пакета

Из корня пакета:

```bash
bash utils/a2-copy-package-to-hosts.sh
```

Скрипт копирует пакет на все A2-хосты в `/root/A2_Evaluation_Scripts_Shanghai_Shenzhen`.
