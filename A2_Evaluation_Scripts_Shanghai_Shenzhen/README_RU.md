# Скрипты проверки A2 - Shanghai/Shenzhen

Пакет сделан по структуре A1: `common`, `criteria`, `remote`, `local`, `utils`.

Основной источник критериев: `Module A/A2_Marking_Scheme_Shanghai_Shenzhen_Detailed_HowToMark_RU.xlsx`.
Карта критериев находится в `criteria/a2_criteria_map.tsv`: 93 пункта, суммарно 25.00 баллов.

## Основной запуск

Рекомендуемая точка запуска по схеме оценки: `ops-ws-a2`.

```bash
cd /root/A2_Evaluation_Scripts_Shanghai_Shenzhen
sudo bash remote/a2-evaluate-remote.sh --report-dir /opt/grading/a2/eval-report
```

По умолчанию скрипт делает паузу после каждого аспекта и показывает:

- критерий и описание;
- команды из схемы оценки;
- ожидаемый результат;
- фактический вывод команды;
- статус OK/не засчитано/предупреждение/пропущено и вес критерия.

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

Если удаленный доступ недоступен, скопируйте пакет на нужную VM и запустите локальный сбор подтверждений:

```bash
sudo bash local/a2-local-check.sh --report-dir /opt/grading/a2/local-report
```

Локальный режим выполняет роль-зависимые проверки для текущего hostname:

- `east-edge-a2`, `core-edge-a2`: маршрутизация, форвардинг, nftables/drop logs;
- `auth-a2`: DNS, LDAP, PKI/StartTLS, remote-логи;
- `repo-a2`: SSSD и `/srv/repo/audit`;
- `portal-a2`: SSSD, HTTPS-портал, логи портала;
- `east-ws-a2`, `ops-ws-a2`: SSSD, резолвер, HTTPS-портал, файлы подтверждения на `ops-ws-a2`.

Локальный режим не является полной заменой удаленной оценки, потому что часть критериев проверяет взаимодействие между хостами.

## Переменные

Можно переопределить пароли и таймауты через окружение:

```bash
export A2_PASS='Skill39@A2'
export A2_READER_PASS='Skill39@A2reader'
export A2_TIMEOUT=6
export A2_CMD_TIMEOUT=180
```

Для функциональных SSH/sudo-тестов LDAP-пользователей желательно наличие `sshpass` на хосте запуска. Root SSH проверяется по ключу.

## Если `ssh-copy-id root@IP` закрывает соединение

Сообщение вида `ERROR: Connection closed by 10.22.10.1 port 22` означает, что host key уже принят, но sshd на целевой VM закрывает попытку входа под `root`. Обычно причина в `PermitRootLogin no/prohibit-password`, `AllowUsers`, `DenyUsers` или похожем SSH/PAM-ограничении.

`ssh-copy-id` в такой ситуации не поможет, потому что он сам должен сначала войти по SSH. Ключ нужно поставить локально через консоль VM.

На хосте проверки (`Checky` или `ops-ws-a2`) покажите public key:

```bash
cat /root/.ssh/id_ed25519.pub
```

На целевой VM из консоли вставьте этот ключ:

```bash
sudo bash utils/a2-install-root-key-local.sh --key 'ssh-ed25519 AAAA...'
```

Если нужно явно разрешить root login по ключу для экспертного доступа:

```bash
sudo bash utils/a2-install-root-key-local.sh --key 'ssh-ed25519 AAAA...' --allow-root-key-login
```

Если пакет еще не скопирован на VM, можно выполнить вручную в консоли VM:

```bash
install -d -m 700 -o root -g root /root/.ssh
echo 'ssh-ed25519 AAAA...' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
```

Если root login по ключу запрещен в sshd, дополнительно:

```bash
cat > /etc/ssh/sshd_config.d/99-a2-root-key-marking.conf <<'EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
sshd -t && systemctl reload ssh
```

Если в `/var/log/auth.log` видно `pam_access(sshd:account): access denied for user root from 10.22.10.5`, то блокирует не sshd, а PAM account policy. Разрешите root только с адреса хоста проверки, который указан в логе:

```bash
sudo bash utils/a2-install-root-key-local.sh --key 'ssh-ed25519 AAAA...' --allow-root-key-login --allow-root-pam-from 10.22.10.5
```

Ручной вариант без пакета на VM:

```bash
cp -a /etc/security/access.conf /etc/security/access.conf.a2bak.$(date +%Y%m%d%H%M%S)
tmp=$(mktemp)
{
  echo '# A2 marking access: разрешить root SSH с 10.22.10.5'
  echo '+ : root : 10.22.10.5'
  echo
  cat /etc/security/access.conf
} > "$tmp"
cat "$tmp" > /etc/security/access.conf
rm -f "$tmp"
systemctl reload ssh
```

Проверка с хоста проверки:

```bash
ssh -o BatchMode=yes root@10.22.10.1 'echo ROOT_OK:$(hostname -s)'
```

Важно: `--allow-root-key-login` меняет проверяемую SSH-конфигурацию хоста. Используйте его только как подготовку экспертного доступа или если по заданию root SSH по ключу действительно должен быть сохранен.

## Файлы отчета

Удаленная проверка:

- `a2-results.tsv`
- `a2-detail.log`
- `a2-summary.txt`

Локальная проверка:

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
