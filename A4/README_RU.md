# Скрипты проверки A4 — Shanghai/Shenzhen

Пакет создан по структуре A3 для Training A4 «Storage, Backup, Logs and
Recovery».

- источник задания: `Module A/A4_Competitor_Task_EN_styled.pdf`;
- источник критериев: `A4_Marking_Scheme_Shanghai_Shenzhen_Detailed_HowToMark_v2_RU.xlsx`;
- карта: `criteria/a4_criteria_map.tsv` — 109 Measurement-аспектов, 25.00 баллов.

## Запуск

Рекомендуемый judge/evidence host — **maint-a4 (`10.44.20.20`)**. Из каталога
пакета:

```bash
sudo bash remote/a4-evaluate-remote.sh \
  --report-dir /opt/grading/a4/eval-report
```

Без пауз или с нужного аспекта:

```bash
sudo bash remote/a4-evaluate-remote.sh --no-pause \
  --start-from A4.3.1 --report-dir /opt/grading/a4/eval-report
```

Restart/persistence-аспекты по умолчанию получают SKIP. После согласованного
restart/reboot:

```bash
sudo bash remote/a4-evaluate-remote.sh --post-reboot \
  --start-from A4.2.13 --report-dir /opt/grading/a4/post-reboot-report
```

## Формат проверки

Перед каждым аспектом выводятся описание, готовая команда How to Mark,
ожидаемый результат, полный stdout/stderr и PASS/FAIL. SSH работает только в
BatchMode с ограниченным timeout. Отчёты:

- `a4-results.tsv`;
- `a4-detail.log`;
- `a4-summary.txt`.

Если DNS не работает, сервис следует повторно проверить по IP и зафиксировать
DNS как primary failure. Отрицательные firewall/Samba/WAN-source проверки
оцениваются по отсутствию успешного соединения, а не по exit code команды с
`|| true`.

## Локальный fallback

На недоступном по SSH узле:

```bash
sudo bash local/a4-local-check.sh --no-pause \
  --report-dir /opt/grading/a4/local-report
```

Объединение локальных результатов:

```bash
bash utils/a4-merge-local-results.sh /opt/grading/a4/local-report
```

Переменные:

```bash
export A4_DOMAIN='cedar.a4.local'
export A4_ROOT_PASS='Skill39@A4'
export A4_TIMEOUT=6
export A4_CMD_TIMEOUT=180
```
