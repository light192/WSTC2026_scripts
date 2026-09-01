# A6 Verification Scripts - Shanghai/Shenzhen

Пакет построен в формате A1-A5 для Training A6 **Integrated Infrastructure,
File Services and Monitoring**.

- источник задания: `Module A/A6_v3_Competitor_Task_EN_styled.pdf`;
- источник критериев: `Module A/WSTC2026_39_A6_Marking_Scheme_CIS_Revised.xlsx`;
- карта: `criteria/a6_criteria_map.tsv` — 73 measurement aspects, 25.00 points;
- оценивание выполняется по работающей системе; файлы evidence от участника не требуются.

## Узлы

| Узел | IP для SSH | Основные роли |
|---|---:|---|
| sh-edge-a6 | 10.76.10.1 | WireGuard, DHCP relay, nftables/NAT |
| sh-user-a6 | 10.76.10.100 | DHCP, SSSD, NFS/SMB и прикладные тесты |
| sz-edge-a6 | 10.76.20.1 | WireGuard, DHCP relay, nftables/NAT/DNAT |
| ops-a6 | 10.76.20.100 | Docker, Prometheus, Grafana, Blackbox Exporter |
| services-a6 | 10.76.30.10 | Apache, Postfix/Dovecot, NFSv4, Samba, SSSD |
| directory-a6 | 10.76.40.10 | primary DNS, OpenLDAP, CA |
| network-a6 | 10.76.40.20 | secondary DNS, Kea DHCPv4 |

Домен: `nova.a6.test`. Пароль maya/timur: `Skill39@A6`, bind account:
`Reader39@A6`, Grafana admin: `Skill39-A6-Monitor!`.

## Запуск

Рекомендуемый узел эксперта — `ops-a6`:

```bash
sudo bash remote/a6-evaluate-remote.sh \
  --report-dir /opt/grading/a6/eval-report
```

Без пауз или с продолжением с конкретного аспекта:

```bash
sudo bash remote/a6-evaluate-remote.sh --no-pause \
  --start-from D1.01 --report-dir /opt/grading/a6/eval-report
```

Evaluator выводит компактные блоки `DEVICE`, `COMMAND`, `OUTPUT`, `RESULT` для
каждой удалённой команды. Пароли отображаются без маскирования, поскольку пакет
предназначен для изолированной учебной инфраструктуры модуля A6.

Сначала выполняйте обычное оценивание. Контролируемые остановки DNS/SMB,
`docker compose down/up` и перезапуск Docker запускайте последними:

```bash
sudo bash remote/a6-evaluate-remote.sh --no-pause --disruptive \
  --start-from I1.01 --report-dir /opt/grading/a6/disruptive-report
```

Скрипт использует cleanup-trap для восстановления сервисов и временных данных
после тестов отказа. D1.07-D1.08, E1.11 и F1.07 выполняются автоматически с
уникальными временными объектами. Только F1.06 оставлен под контролируемый тест
эксперта: для точного подтверждения SNAT двух площадок нужны согласованные WAN
listeners и короткие packet captures. Он получает WARN, а не ложный PASS.

Отчёты: `a6-results.tsv`, `a6-detail.log`, `a6-summary.txt`.

## Локальный fallback

Если узел недоступен по SSH:

```bash
sudo bash local/a6-local-check.sh --no-pause \
  --report-dir /opt/grading/a6/local-report
bash utils/a6-merge-local-results.sh /opt/grading/a6/local-report
```

Карта критериев воспроизводимо пересобирается из XLSX:

```bash
python3 tools/build_a6_map.py \
  WSTC2026_39_A6_Marking_Scheme_CIS_Revised.xlsx \
  criteria/a6_criteria_map.tsv
```
