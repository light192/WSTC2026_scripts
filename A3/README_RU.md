# Скрипты проверки A3 — Shanghai/Shenzhen

Пакет создан по структуре A2 и проверяет Training A3 «Secure Services
Publishing and Remote Access».

- источник задания: `Module A/A3_Competitor_Task_EN_styled.pdf`;
- источник критериев: `A3_Marking_Scheme_Shanghai_Shenzhen_Detailed_HowToMark_v2_RU.xlsx`;
- карта: `criteria/a3_criteria_map.tsv` — 106 measurement-аспектов, 25.00 баллов.

## Рекомендуемый хост запуска

Удалённую проверку рекомендуется запускать с **admin-a3 (`10.33.20.20`)**.
Это прямо предусмотренный заданием evidence/scoring host. Он должен иметь root
SSH key-доступ ко всем остальным узлам и хранит evidence в `/opt/grading/a3`.
Запуск с gateway или proxy хуже: firewall matrix намеренно ограничивает их
доступ, поэтому часть положительных/отрицательных тестов станет неоднозначной.

## Подготовка admin-a3

```bash
sudo -i
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''
cat /root/.ssh/id_ed25519.pub
```

Public key необходимо установить в `/root/.ssh/authorized_keys` всех семи VM.
При закрытом root SSH это можно сделать через локальную консоль VM:

```bash
sudo bash utils/a3-install-root-key-local.sh \
  --key 'ssh-ed25519 AAAA...' --allow-root-key-login
```

Утилита предназначена только для подготовки предусмотренного заданием
экспертного root key-доступа. Она не устанавливает парольный root SSH.

## Основной запуск

```bash
cd /root/A3
sudo bash remote/a3-evaluate-remote.sh \
  --report-dir /opt/grading/a3/eval-report
```

По умолчанию после каждого аспекта есть пауза. На экране последовательно
показываются критерий, точная команда How to Mark, ожидаемый результат,
отфильтрованный фактический вывод и PASS/FAIL.

Без пауз:

```bash
sudo bash remote/a3-evaluate-remote.sh --no-pause \
  --report-dir /opt/grading/a3/eval-report
```

Продолжение с нужного аспекта:

```bash
sudo bash remote/a3-evaluate-remote.sh --start-from A3.5.1 \
  --report-dir /opt/grading/a3/eval-report
```

## Persistence/restart проверки

Обычный проход не перезапускает рабочие сервисы. Аспекты persistence получают
SKIP и запускаются отдельно после согласованного reboot или в конце оценки:

```bash
sudo bash remote/a3-evaluate-remote.sh --post-reboot \
  --start-from A3.1.12 --report-dir /opt/grading/a3/post-reboot-report
```

Этот режим может перезапускать bind9, nginx, приложение, WireGuard и rsyslog.

## Локальный fallback

Если admin-a3 не достигает отдельную VM, скопируйте пакет на эту VM и выполните:

```bash
sudo bash local/a3-local-check.sh --no-pause \
  --report-dir /opt/grading/a3/local-report
```

Локальный скрипт собирает role-specific evidence. Это не полная замена remote
matrix, поскольку firewall, WireGuard jump и routed no-NAT требуют нескольких
узлов. Объединение локальных TSV:

```bash
bash utils/a3-merge-local-results.sh /opt/grading/a3/local-report
```

## Переменные

```bash
export A3_DOMAIN='nova.a3.test'
export A3_ROOT_PASS='Skill39@A3'
export A3_TIMEOUT=6
export A3_CMD_TIMEOUT=180
```

Пароль хранится как справочное значение; основной evaluator намеренно проверяет
предусмотренный критерием root key-доступ (`BatchMode=yes`).

## Отчёты

- `a3-results.tsv` — статус и вес каждого аспекта;
- `a3-detail.log` — команды и фактический вывод;
- `a3-summary.txt` — итоговая сумма и количество PASS/FAIL/WARN/SKIP.

Отрицательные проверки оценивают отсутствие успешного TCP/HTTP-подключения.
Если FQDN-тест не прошёл, эксперт должен повторить его по IP, как предписывает
marking scheme, и отнести первичную ошибку к DNS, а не автоматически обнулять
зависимый сервис.
