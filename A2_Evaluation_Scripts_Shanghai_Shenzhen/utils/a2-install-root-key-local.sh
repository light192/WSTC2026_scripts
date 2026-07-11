#!/usr/bin/env bash
# Установить публичный ключ эксперта в /root/.ssh/authorized_keys на текущей VM.
# Запускается локально на консоли целевой VM, если ssh-copy-id не входит под root.

set -euo pipefail

KEY_TEXT=""
KEY_FILE=""
ALLOW_ROOT_KEY_LOGIN=0
ALLOW_ROOT_PAM_FROM=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Использование:
  sudo bash utils/a2-install-root-key-local.sh --key 'ssh-ed25519 AAAA...'
  sudo bash utils/a2-install-root-key-local.sh --key-file /tmp/id_ed25519.pub

Опции:
  --key TEXT                Текст public key для добавления в /root/.ssh/authorized_keys.
  --key-file PATH           Файл с public key.
  --allow-root-key-login    Также добавить sshd drop-in для root key login.
                            Записывает PermitRootLogin prohibit-password и
                            PubkeyAuthentication yes, затем reload sshd.
  --allow-root-pam-from SRC Добавить первое правило pam_access:
                            + : root : SRC
                            Используйте исходный IP хоста проверки из auth.log,
                            например 10.22.10.5.
  --dry-run                 Показать действия и диагностику sshd без изменений.
  -h, --help                Показать эту справку.

Примечания:
  ssh-copy-id требует интерактивный root login. Если sshd закрывает соединение
  до password auth, установите ключ локально этим скриптом.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --key)
      shift
      [ $# -gt 0 ] || { echo "Не указано значение для --key" >&2; exit 2; }
      KEY_TEXT="$1"
      ;;
    --key-file)
      shift
      [ $# -gt 0 ] || { echo "Не указано значение для --key-file" >&2; exit 2; }
      KEY_FILE="$1"
      ;;
    --allow-root-key-login) ALLOW_ROOT_KEY_LOGIN=1 ;;
    --allow-root-pam-from|--allow-root-from)
      shift
      [ $# -gt 0 ] || { echo "Не указано значение для --allow-root-pam-from" >&2; exit 2; }
      ALLOW_ROOT_PAM_FROM="$1"
      ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестная опция: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите от root." >&2
  exit 1
fi

if [ -n "$KEY_FILE" ]; then
  [ -r "$KEY_FILE" ] || { echo "Не удается прочитать файл ключа: $KEY_FILE" >&2; exit 1; }
  KEY_TEXT="$(sed -n '1p' "$KEY_FILE")"
fi

if [ -z "$KEY_TEXT" ]; then
  echo "Нужен public key. Используйте --key или --key-file." >&2
  usage
  exit 2
fi

case "$KEY_TEXT" in
  ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*\ *) ;;
  *)
    echo "Значение не похоже на OpenSSH public key:" >&2
    echo "$KEY_TEXT" >&2
    exit 2
    ;;
esac

echo "Хост: $(hostname -f 2>/dev/null || hostname)"
echo "Fingerprint ключа:"
if command -v ssh-keygen >/dev/null 2>&1; then
  printf '%s\n' "$KEY_TEXT" | ssh-keygen -lf - || true
else
  printf '%s\n' "$KEY_TEXT"
fi

echo
echo "Текущие релевантные настройки sshd:"
if command -v sshd >/dev/null 2>&1; then
  sshd -T 2>/dev/null | grep -Ei '^(permitrootlogin|pubkeyauthentication|authorizedkeysfile|passwordauthentication) ' || true
else
  echo "Команда sshd не найдена в PATH"
fi
grep -RHE '^[[:space:]]*(PermitRootLogin|PubkeyAuthentication|AuthorizedKeysFile|AllowUsers|DenyUsers|AllowGroups|DenyGroups|Match)[[:space:]]' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null || true
echo
echo "Текущие релевантные настройки PAM access:"
grep -RHE '^[[:space:]]*account[[:space:]].*pam_access\.so' /etc/pam.d/sshd /etc/pam.d 2>/dev/null || true
grep -RHE '^[[:space:]]*[+-][[:space:]]*:' /etc/security/access.conf /etc/security/access.d 2>/dev/null || true

if [ "$DRY_RUN" = "1" ]; then
  echo
  echo "Только dry run. Изменения не внесены."
  exit 0
fi

install -d -m 700 -o root -g root /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys

if grep -Fxq "$KEY_TEXT" /root/.ssh/authorized_keys; then
  echo "Ключ уже есть в /root/.ssh/authorized_keys"
else
  printf '%s\n' "$KEY_TEXT" >> /root/.ssh/authorized_keys
  echo "Ключ добавлен в /root/.ssh/authorized_keys"
fi

if [ "$ALLOW_ROOT_KEY_LOGIN" = "1" ]; then
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    install -d -m 755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-a2-root-key-marking.conf <<'EOF'
# A2 marking access: разрешить root login только по public key.
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
    echo "Записан /etc/ssh/sshd_config.d/99-a2-root-key-marking.conf"
  else
    echo "ПРЕДУПРЕЖДЕНИЕ: /etc/ssh/sshd_config не включает /etc/ssh/sshd_config.d/*.conf" >&2
    echo "Ключ установлен, но политика root-login в sshd не изменена." >&2
    echo "Добавьте вручную при необходимости:" >&2
    echo "  PermitRootLogin prohibit-password" >&2
    echo "  PubkeyAuthentication yes" >&2
  fi
fi

if [ -n "$ALLOW_ROOT_PAM_FROM" ]; then
  ACCESS_CONF="/etc/security/access.conf"
  ACCESS_RULE="+ : root : $ALLOW_ROOT_PAM_FROM"
  ACCESS_COMMENT="# A2 marking access: разрешить root SSH с $ALLOW_ROOT_PAM_FROM"
  touch "$ACCESS_CONF"
  if grep -Fxq "$ACCESS_RULE" "$ACCESS_CONF"; then
    echo "Правило PAM access уже есть в $ACCESS_CONF"
  else
    backup="$ACCESS_CONF.a2bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$ACCESS_CONF" "$backup"
    tmp="$(mktemp)"
    {
      printf '%s\n' "$ACCESS_COMMENT"
      printf '%s\n' "$ACCESS_RULE"
      printf '\n'
      cat "$ACCESS_CONF"
    } > "$tmp"
    cat "$tmp" > "$ACCESS_CONF"
    rm -f "$tmp"
    echo "Добавлено первое правило PAM access в $ACCESS_CONF"
    echo "Резервная копия: $backup"
  fi
fi

if command -v sshd >/dev/null 2>&1; then
  sshd -t
elif [ -x /usr/sbin/sshd ]; then
  /usr/sbin/sshd -t
fi

systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || true

echo
echo "Готово. Проверьте с хоста проверки:"
echo "  ssh -o BatchMode=yes root@$(hostname -I 2>/dev/null | awk '{print $1}') 'echo ROOT_OK:\$(hostname -s)'"
