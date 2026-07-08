#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
checker_lib.py — общие вспомогательные функции для чекеров Mod C:
- цвета, очистка экрана, ожидание Enter
- поиск нужной сессии PNETLab по подстроке имени
- построение карты нод -> (host, port)
- TCP-подключение к консоли IOS, вход в enable, выполнение команды
- разбор show run: интерфейсы и ip address
- фильтрация show run по интересующим интерфейсам
"""

import os
import socket
import time
import ipaddress
import re
from urllib.parse import urlparse

from pnetlab_lib import (
    get_sessions_count,
    filter_session,
    join_session,
    get_nodes,
    filter_user,
)

# ---------- цвета ----------

RED    = "\033[0;31m"
GREEN  = "\033[1;32m"
YELLOW = "\033[1;33m"
BLUE   = "\033[1;34m"
PURPLE = "\033[0;35m"
CYAN   = "\033[0;36m"
NC     = "\033[0m"

# если True — при неудачном enable спросим пароль руками и попробуем ещё раз
ASK_ENABLE_INTERACTIVE = True

# если True — при отсутствии/ошибке device login спросим учётные данные руками
ASK_DEVICE_LOGIN_INTERACTIVE = True

# Таймаут ожидания данных от устройства (секунды) для всех recv()
SOCKET_RECV_TIMEOUT = 20.0

# IOS prompt at the end of command output, including config modes:
# R1#, R1>, R1(config)#, R1(config-line)#, etc.
IOS_PROMPT_RE = re.compile(r"(?m)(?:^|\r?\n)[^\r\n]+(?:\(config[^\)]*\))?[>#]\s*$")


# ---------- утилиты вывода ----------

def clear_screen():
    """Очистка экрана."""
    os.system("cls" if os.name == "nt" else "clear")


def wait_enter(prompt: str = "Нажмите Enter для перехода к следующей проверке..."):
    """Пауза между проверками."""
    input(f"{YELLOW}\n{prompt}{NC}")


# ---------- работа с PNETLab-сессией ----------

def get_running_session_id_by_substring(
    pnet_url: str,
    cookie,
    name_substring: str,
) -> str:
    """
    Ищет среди запущенных сессий PNETLab все, у которых lab_session_path
    содержит указанную подстроку name_substring.

    Поведение:
      - печатает список всех активных сессий (ID, username, path);
      - выделяет только подходящие сессии;
      - ВСЕГДА просит пользователя выбрать лабораторию по её ID
        (даже если подходящая только одна);
      - возвращает выбранный lab_session_id.
    """
    # --- берём список пользователей, чтобы потом по pod найти username ---
    try:
        users_resp = filter_user(pnet_url, cookie).json()
        users_table = users_resp.get("data", {}).get("data_table", [])
    except Exception:
        users_table = []

    pod_to_username = {}
    for u in users_table:
        pod = u.get("pod")
        username = u.get("username")
        if pod is not None and username:
            pod_to_username[pod] = username

    # --- общее количество сессий ---
    r_count = get_sessions_count(pnet_url, cookie).json()
    count_labs = r_count.get("data", 0)
    print(f"{BLUE}[+] Найдено {count_labs} активных сессий лабораторий{NC}")

    if count_labs == 0:
        raise RuntimeError("Нет запущенных лабораторий")

    resp = filter_session(pnet_url, cookie, 1, count_labs)
    data = resp.json()
    sessions = data.get("data", {}).get("data_table", [])
    if not sessions:
        raise RuntimeError("filter_session не вернул data_table")

    # --- печатаем все активные сессии ---
    print(f"\n{PURPLE}===== Активные сессии лабораторий ====={NC}")
    for s in sessions:
        sid = s.get("lab_session_id")
        path = s.get("lab_session_path")
        status = s.get("status", "") or s.get("lab_session_status", "")
        pod = s.get("lab_session_pod")
        username = pod_to_username.get(pod, "?")
        print(f"ID: {sid} | user: {username} | status: {status} | path: {path}")
    print(f"{PURPLE}========================================{NC}\n")

    # --- фильтрация по подстроке в пути ---
    matching = []
    for s in sessions:
        path = (s.get("lab_session_path") or "")
        if name_substring in path:
            matching.append(s)

    if not matching:
        raise RuntimeError(
            f"Не найдена запущенная лаба с подстрокой '{name_substring}' в пути"
        )

    print(
        f"{YELLOW}[i] Найдено {len(matching)} лаборатор(ий), содержащих подстроку "
        f"'{name_substring}' в пути. Выберите нужную по ID:{NC}"
    )

    ids: list[int] = []
    for s in matching:
        sid = s.get("lab_session_id")
        path = s.get("lab_session_path")
        status = s.get("status", "") or s.get("lab_session_status", "")
        pod = s.get("lab_session_pod")
        username = pod_to_username.get(pod, "?")
        try:
            sid_int = int(sid)
        except (TypeError, ValueError):
            continue
        ids.append(sid_int)
        print(f"  ID: {sid_int} | user: {username} | status: {status} | path: {path}")

    if not ids:
        raise RuntimeError("Не удалось извлечь ID сессий для выбора")

    # --- выбор по ID ---
    while True:
        choice = input(f"{YELLOW}Введите ID лаборатории из списка: {NC}").strip()
        try:
            cid = int(choice)
        except ValueError:
            print(RED + "Нужно ввести числовой ID, как в колонке ID." + NC)
            continue

        if cid not in ids:
            print(RED + "Такого ID нет среди перечисленных лабораторий." + NC)
            continue

        for s in matching:
            try:
                sid_int = int(s.get("lab_session_id"))
            except (TypeError, ValueError):
                continue
            if sid_int == cid:
                sid = s.get("lab_session_id")
                path = s.get("lab_session_path")
                pod = s.get("lab_session_pod")
                username = pod_to_username.get(pod, "?")
                print(
                    f"{GREEN}[+] Выбрана лаборатория ID {sid}, user {username}, "
                    f"path '{path}'.{NC}"
                )
                return str(sid)


def join_lab_session(pnet_url: str, cookie, session_id: str):
    """Обёртка над join_session для единообразия."""
    return join_session(pnet_url, session_id, cookie)


def build_node_console_map(nodes_json: dict) -> dict[str, tuple[str, int]]:
    """
    Из ответа get_nodes собираем словарь:
    { 'DS1': (host, port), 'DS2': (...), ... }
    """
    nodes = nodes_json.get("data", {}).get("nodes", {})
    if not nodes:
        raise RuntimeError("get_nodes не вернул ни одной ноды")

    mapping: dict[str, tuple[str, int]] = {}
    print(f"{PURPLE}===== Список нод в лаборатории ====={NC}")
    for node_id, node in nodes.items():
        name = node.get("name")
        url = node.get("url")
        print(f"ID: {node_id:>3} | Name: {name:<20} | URL: {url}")
        if not name or not url:
            continue
        parsed = urlparse(url)
        host = parsed.hostname
        port = parsed.port
        if host and port:
            mapping[name] = (host, port)
    print(f"{PURPLE}======================================{NC}\n")
    return mapping


def get_nodes_json(pnet_url: str, cookie):
    """Удобная обёртка для получения JSON со списком нод."""
    return get_nodes(pnet_url, cookie).json()


# ---------- telnet/TCP + login + enable ----------

def _has_username_prompt(text: str) -> bool:
    """Ищем приглашение Username/Login в выводе консоли."""
    if not text:
        return False
    return bool(re.search(r"(?i)(username|login)\s*:\s*$", text))


def _has_password_prompt(text: str) -> bool:
    """Ищем реальное приглашение Password: в выводе консоли."""
    if not text:
        return False
    return bool(re.search(r"(?i)password\s*:\s*$", text))


def _has_ios_prompt(text: str) -> bool:
    """Проверяет, что последний видимый фрагмент похож на IOS prompt."""
    if not text:
        return False
    return bool(IOS_PROMPT_RE.search(text))


def enter_login_mode(sock: socket.socket,
                     device_username: str | None,
                     device_password: str | None,
                     device_label: str = "",
                     initial_text: str = "") -> str:
    """
    Проходит обычный IOS login prompt до пользовательского/enable prompt.

    Возвращает накопленный вывод, чтобы вызывающий код мог сохранить его
    для диагностики. Если устройство уже на prompt, ничего не делает.
    """
    label = f" [{device_label}]" if device_label else ""
    buf = initial_text or ""
    tail = buf

    if _has_ios_prompt(tail):
        return buf

    for _ in range(8):
        if _has_username_prompt(tail):
            username = device_username
            if not username:
                if not ASK_DEVICE_LOGIN_INTERACTIVE:
                    raise RuntimeError(f"Для устройства{label} требуется username")
                username = input(f"{YELLOW}Введите username для устройства{label}: {NC}")
            sock.sendall(username.encode() + b"\r\n")
            time.sleep(0.8)
            try:
                data = sock.recv(4096).decode(errors="ignore")
            except socket.timeout:
                data = ""
            tail = data
            buf += data
            continue

        if _has_password_prompt(tail):
            password = device_password
            if not password:
                if not ASK_DEVICE_LOGIN_INTERACTIVE:
                    raise RuntimeError(f"Для устройства{label} требуется password")
                password = input(f"{YELLOW}Введите password для устройства{label}: {NC}")
            sock.sendall(password.encode() + b"\r\n")
            time.sleep(1.0)
            try:
                data = sock.recv(4096).decode(errors="ignore")
            except socket.timeout:
                data = ""
            tail = data
            buf += data

            if "% Login invalid" in data or "Login invalid" in data:
                print(f"{RED}[!] Неверный device username/password для устройства{label}{NC}")
                device_username = None
                device_password = None
                continue

            if _has_ios_prompt(tail) or _has_ios_prompt(buf):
                return buf
            continue

        # Нет явного prompt — разбудим консоль ещё раз.
        sock.sendall(b"\r\n")
        time.sleep(0.8)
        try:
            data = sock.recv(4096).decode(errors="ignore")
        except socket.timeout:
            data = ""
        if not data:
            return buf
        tail = data
        buf += data
        if _has_ios_prompt(tail) or _has_ios_prompt(buf):
            return buf

    if _has_username_prompt(tail) or _has_password_prompt(tail) or _has_username_prompt(buf) or _has_password_prompt(buf):
        tail_safe = repr((tail or buf)[-300:])
        raise RuntimeError(f"Не удалось пройти login для устройства{label}; последний вывод: {tail_safe}")

    return buf

def enter_enable_mode(sock: socket.socket,
                      enable_password: str | None,
                      device_label: str = "") -> None:
    """
    Аккуратно заходим в enable:
    - шлём 'enable'
    - ждём, пока не увидим либо приглашение 'Password:', либо prompt с '#'
    - если нужен пароль: пробуем из creds.json, при неудаче (и если разрешено)
      спрашиваем вручную.
    Бросаем RuntimeError, если войти не удалось.
    """

    label = f" [{device_label}]" if device_label else ""

    # отправляем enable
    sock.sendall(b"enable\r\n")
    time.sleep(1.0)

    buf = ""
    # несколько попыток дождаться либо Password:, либо '#'
    for _ in range(5):
        try:
            data = sock.recv(4096).decode(errors="ignore")
        except socket.timeout:
            # ничего не пришло — ещё раз попробуем
            continue

        if not data:
            break

        buf += data

        # уже в привилегированном режиме, пароль не нужен
        if "#" in buf:
            return

        # увидели нормальное приглашение Password: — дальше ввод пароля
        if _has_password_prompt(buf):
            break

    # если к этому моменту уже есть '#', считаем, что мы в enable
    if "#" in buf:
        return

    # явного приглашения Password: нет — считаем, что пароль не требуется
    if not _has_password_prompt(buf):
        return

    # явно просят пароль
    for attempt in range(2):
        pwd_to_use = enable_password
        if not pwd_to_use:
            if not ASK_ENABLE_INTERACTIVE:
                break
            # ручной ввод
            pwd_to_use = input(
                f"{YELLOW}Введите enable-пароль для устройства{label}: {NC}"
            )

        sock.sendall(pwd_to_use.encode() + b"\r\n")
        time.sleep(1.0)

        try:
            resp = sock.recv(4096).decode(errors="ignore")
        except socket.timeout:
            resp = ""

        buf += resp

        # успешно вошли в enable
        if "#" in resp or "#" in buf:
            return

        # всё ещё просят пароль — значит, введён неверный
        if _has_password_prompt(resp):
            print(f"{RED}[!] Неверный enable-пароль для устройства{label}{NC}")
            # на следующей итерации дадим ввести руками
            enable_password = None
            continue

    raise RuntimeError(f"Не удалось войти в enable для устройства{label}")


def _read_until_prompt_or_idle(
    sock: socket.socket,
    timeout: float = SOCKET_RECV_TIMEOUT,
    idle_timeout: float = 1.5,
) -> str:
    """
    Читает вывод консоли до возврата IOS prompt или до устойчивого idle.

    Старый код мог завершить чтение на первом коротком socket.timeout.
    На загруженных IOSv/IOSvL2 `show running-config ...` иногда начинает
    отдавать данные позже, и checker получал пустой вывод.
    """
    deadline = time.time() + timeout
    chunks: list[str] = []
    last_data_at: float | None = None

    while time.time() < deadline:
        remaining = max(0.05, deadline - time.time())
        sock.settimeout(min(0.5, remaining))
        try:
            data = sock.recv(65535)
        except socket.timeout:
            if last_data_at is not None and (time.time() - last_data_at) >= idle_timeout:
                break
            continue
        except OSError:
            break

        if not data:
            break

        chunks.append(data.decode(errors="ignore"))
        last_data_at = time.time()
        if _has_ios_prompt("".join(chunks)):
            break

    sock.settimeout(timeout)
    return "".join(chunks)


def _send_ios_command(
    sock: socket.socket,
    command: str,
    timeout: float = SOCKET_RECV_TIMEOUT,
    idle_timeout: float = 1.5,
) -> str:
    lines = command.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if len(lines) == 1:
        sock.sendall(command.encode() + b"\r\n")
        return _read_until_prompt_or_idle(sock, timeout=timeout, idle_timeout=idle_timeout)

    chunks: list[str] = []
    for line in lines:
        sock.sendall(line.encode() + b"\r\n")
        chunks.append(_read_until_prompt_or_idle(sock, timeout=timeout, idle_timeout=idle_timeout))
        time.sleep(0.05)
    return "".join(chunks)


def prepare_ios_console_session(
    sock: socket.socket,
    timeout: float = SOCKET_RECV_TIMEOUT,
    device_label: str = "",
) -> None:
    """
    Готовит IOS console к неинтерактивным проверкам.

    - `exec-timeout 0 0` на line console 0 не даёт PNET-консоли отключаться
      во время длинного прогона checker.
    - terminal length/width отключают pager и переносы, которые ломают парсинг.

    Команды не сохраняются в startup-config.
    """
    label = f" ({device_label})" if device_label else ""
    try:
        _send_ios_command(sock, "terminal length 0", timeout=timeout, idle_timeout=0.8)
        _send_ios_command(sock, "terminal width 511", timeout=timeout, idle_timeout=0.8)
        _send_ios_command(
            sock,
            "configure terminal\nline console 0\nexec-timeout 0 0\nend",
            timeout=timeout,
            idle_timeout=1.0,
        )
        _send_ios_command(sock, "terminal length 0", timeout=timeout, idle_timeout=0.8)
        _send_ios_command(sock, "terminal width 511", timeout=timeout, idle_timeout=0.8)
    except Exception as exc:
        print(f"{YELLOW}[!] Не удалось подготовить консоль{label}: {exc}{NC}")


class IOSConsoleSession:
    """Постоянная TCP-консоль IOS: login/enable один раз, затем много show-команд."""

    def __init__(
        self,
        host: str,
        port: int,
        enable_password: str | None,
        device_label: str = "",
        timeout: float = SOCKET_RECV_TIMEOUT,
        device_username: str | None = None,
        device_password: str | None = None,
    ):
        self.host = host
        self.port = port
        self.enable_password = enable_password
        self.device_label = device_label
        self.timeout = timeout
        self.device_username = device_username
        self.device_password = device_password
        self.sock: socket.socket | None = None
        self.connected = False

    def _read_until_idle(self, idle_timeout: float = 1.0, max_wait: float | None = None) -> str:
        if self.sock is None:
            return ""
        return _read_until_prompt_or_idle(
            self.sock,
            timeout=max_wait if max_wait is not None else self.timeout,
            idle_timeout=idle_timeout,
        )

    def connect(self) -> None:
        if self.connected:
            return

        print(f"{BLUE}[+] Открытие постоянной консоли {self.host}:{self.port} ({self.device_label})...{NC}")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect((self.host, self.port))
        self.sock = sock

        time.sleep(1)
        sock.sendall(b"\r\n")
        time.sleep(1)
        try:
            initial_text = sock.recv(4096).decode(errors="ignore")
        except socket.timeout:
            initial_text = ""

        enter_login_mode(
            sock,
            self.device_username,
            self.device_password,
            device_label=self.device_label,
            initial_text=initial_text,
        )
        enter_enable_mode(sock, self.enable_password, device_label=self.device_label)
        prepare_ios_console_session(sock, timeout=self.timeout, device_label=self.device_label)

        self.connected = True

    def exec(self, command: str) -> str:
        if not self.connected or self.sock is None:
            self.connect()
        if self.sock is None:
            raise RuntimeError(f"Нет TCP-сессии для {self.device_label}")

        # Сначала вычищаем возможный поздний syslog/эхо из канала.
        self._read_until_idle(idle_timeout=0.2, max_wait=0.6)

        raw = _send_ios_command(
            self.sock,
            command,
            timeout=self.timeout,
            idle_timeout=1.5,
        )
        if not raw.strip():
            print(f"{YELLOW}[!] {self.device_label}: пустой вывод для '{command}', повторяю после подготовки консоли...{NC}")
            prepare_ios_console_session(self.sock, timeout=self.timeout, device_label=self.device_label)
            raw = _send_ios_command(
                self.sock,
                command,
                timeout=self.timeout,
                idle_timeout=2.0,
            )
        return raw

    def close(self) -> None:
        if self.sock is None:
            return
        try:
            self.sock.sendall(b"\r\nexit\r\n")
            time.sleep(0.2)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self.sock = None
        self.connected = False


def tcp_exec_ios_command(host: str,
                         port: int,
                         command: str,
                         enable_password: str | None,
                         device_label: str = "",
                         timeout: float = SOCKET_RECV_TIMEOUT,
                         device_username: str | None = None,
                         device_password: str | None = None) -> str:
    """
    Подключение к консоли IOS по TCP, переход в enable,
    выполнение команды и возврат всего вывода.
    """
    print(f"{BLUE}[+] Подключение к {host}:{port} по TCP ({device_label})...{NC}")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    # общий таймаут на ожидание данных/ответа от устройства
    s.settimeout(timeout)
    s.connect((host, port))

    output_chunks: list[str] = []
    initial_text = ""

    # разбудить консоль
    time.sleep(1)
    s.sendall(b"\r\n")
    time.sleep(1)
    try:
        data = s.recv(4096)
        if data:
            initial_text = data.decode(errors="ignore")
            output_chunks.append(initial_text)
    except socket.timeout:
        pass

    login_output = enter_login_mode(
        s,
        device_username,
        device_password,
        device_label=device_label,
        initial_text=initial_text,
    )
    if login_output and login_output != initial_text:
        output_chunks.append(login_output[len(initial_text):])

    # нормальный вход в enable
    enter_enable_mode(s, enable_password, device_label=device_label)
    prepare_ios_console_session(s, timeout=timeout, device_label=device_label)

    # основная команда: читаем до возврата prompt, а не до первого idle timeout
    raw_command_output = _send_ios_command(
        s,
        command,
        timeout=timeout,
        idle_timeout=1.5,
    )
    if not raw_command_output.strip():
        print(f"{YELLOW}[!] {device_label}: пустой вывод для '{command}', повторяю после подготовки консоли...{NC}")
        prepare_ios_console_session(s, timeout=timeout, device_label=device_label)
        raw_command_output = _send_ios_command(
            s,
            command,
            timeout=timeout,
            idle_timeout=2.0,
        )
    output_chunks.append(raw_command_output)

    try:
        s.sendall(b"\r\nexit\r\n")
        time.sleep(0.5)
    except OSError:
        pass

    s.close()
    return "".join(output_chunks)

def canonical_ifname(name: str) -> str:
    """Приводит имя интерфейса к «полной» форме: Gi0/1 -> GigabitEthernet0/1 и т.п."""
    name = name.strip()

    mapping = {
        "Gi": "GigabitEthernet",
        "Fa": "FastEthernet",
        "Se": "Serial",
        "Te": "TenGigabitEthernet",
        "Vl": "Vlan",
        "Po": "Port-channel",
        "Tu": "Tunnel",
        "Lo": "Loopback",
    }

    for short, full in mapping.items():
        if name.startswith(short) and not name.startswith(full):
            return full + name[len(short):]

    return name

import re


# ---------- разбор конфигурации ----------

def extract_interface_networks_from_config(config_text: str) -> dict[str, set[str]]:
    """
    Разбирает вывод show run:
      interface X
        ip address A.B.C.D M.M.M.M
    и возвращает dict:
      { "GigabitEthernet0/0": {"10.10.0.0/24", ...}, ... }
    """
    iface_nets: dict[str, set[str]] = {}
    current_if: str | None = None

    for raw in config_text.splitlines():
        line = raw.rstrip()

        # начало интерфейсного блока
        if line.startswith("interface "):
            parts = line.split()
            current_if = parts[1] if len(parts) > 1 else None
            continue

        if current_if is None:
            continue

        stripped = line.strip()
        if not stripped:
            continue

        # если ушли в другой раздел (например, 'router eigrp')
        if not line.startswith(" ") and not line.startswith("\t"):
            current_if = None
            continue

        if stripped.startswith("ip address "):
            parts = stripped.split()
            if len(parts) < 4:
                continue
            ip_str = parts[2]
            mask_str = parts[3]
            try:
                net = ipaddress.IPv4Network(f"{ip_str}/{mask_str}", strict=False)
                key = f"{net.network_address}/{net.prefixlen}"
            except Exception:
                continue
            iface_nets.setdefault(current_if, set()).add(key)

    return iface_nets


def normalise_net_string(net_str: str) -> str:
    """
    Нормализует запись сети:
    - принимает '10.10.0.0/24' или '10.10.0.0 255.255.255.0'
    - отдаёт '10.10.0.0/24'
    """
    parts = net_str.split()
    if len(parts) == 2:
        ip, mask = parts
        net = ipaddress.IPv4Network(f"{ip}/{mask}", strict=False)
    else:
        net = ipaddress.IPv4Network(net_str, strict=False)
    return f"{net.network_address}/{net.prefixlen}"


def filter_config_for_interfaces(config_text: str, interfaces: list[str]) -> str:
    """
    Оставляет в конфиге только нужные интерфейсы и строки ip address.
    На выходе:
      interface X
       ip address ...
      interface Y
       ip address ...
    """
    interfaces_set = set(interfaces)
    lines = config_text.splitlines()
    result_lines: list[str] = []
    current_if: str | None = None
    include = False

    for raw in lines:
        line = raw.rstrip("\n")

        # начало интерфейсного блока
        if line.startswith("interface "):
            parts = line.split()
            current_if = parts[1] if len(parts) > 1 else None
            include = current_if in interfaces_set
            if include:
                result_lines.append(line)
            continue

        if current_if is None or not include:
            continue

        stripped = line.strip()
        if not stripped:
            result_lines.append(line)
            continue

        # вываливаемся из интерфейса, если начался новый раздел без отступа
        if not line.startswith(" ") and not line.startswith("\t"):
            current_if = None
            include = False
            continue

        # внутри нужного интерфейса оставляем только ip address
        if stripped.startswith("ip address "):
            result_lines.append(line)

    return "\n".join(result_lines)

def ios_cmd(node_console_map, dev, cmd, enable_password):
    """
    Унифицированный запуск команды на IOS-устройстве с красивым выводом.
    Возвращает уже очищенный вывод (после format_ios_output).
    """
    if dev not in node_console_map:
        print(RED + f"[!] {dev} не найден в node_console_map" + NC)
        return ""

    host, port = node_console_map[dev]
    print(YELLOW + "Устройство:" + NC, BLUE + dev + NC)
    print(YELLOW + "Команда:" + NC, BLUE + cmd + NC)
    raw = tcp_exec_ios_command(host, port, cmd, enable_password, device_label=dev)
    out = format_ios_output(raw, cmd)
    print(BLUE + "Вывод:" + NC)
    print(out + "\n")
    return out


def format_ios_output(raw: str, cmd: str | None = None) -> str:
    """
    Очистка вывода команд IOS для красивого отображения.

    Делает следующее:
    1) Отрезает всё, что было ДО строки с выполняемой командой (если cmd задана).
    2) Удаляет баннер IOSv / EULA (включая строку 'By using the software...' и URL EULA).
    3) Убирает 'terminal length 0', эхо команды, системные сообщения (%CDP-, %LINK- и т.п.)
       и чистое приглашение вида R1#, R2>.
    4) Сохраняет полезные сообщения вида '% Invalid input detected at '^' marker.'
       и '% Subnet not in table', т.е. НЕ режет все строки, начинающиеся с '%'.

    ВАЖНО: использовать только для оформления вывода на экран.
           Для парсинга всегда бери сырое `raw`.
    """
    if not raw:
        return ""

    lines = raw.splitlines()

    # 1. Обрезаем всё до строки с командой
    if cmd:
        start_idx = None
        for i, line in enumerate(lines):
            if cmd in line:
                start_idx = i
                break
        if start_idx is not None:
            # всё, что до эхо команды, выкидываем
            lines = lines[start_idx + 1 :]

    # Ключевые фразы EULA / баннера IOSv
    eula_keywords = [
        "IOSv - Cisco Systems Confidential",
        "Cisco Systems Confidential",
        "End User License Restrictions",
        "This IOSv software is provided AS-IS",
        "IOSv software is provided AS-IS",
        "By using this software",
        "By using the software, you agree",
        "Cisco End User License Agreement",
        "http://www.cisco.com/go/eula",
    ]

    # системные сообщения, которые нам не нужны
    syslog_prefixes = (
        "%CDP-",
        "%LINK-",
        "%LINEPROTO-",
        "%SYS-",
        "%DUAL-",
        "%SPANTREE-",
    )

    cleaned: list[str] = []
    in_banner = False

    for line in lines:
        s = line.rstrip("\r\n")
        stripped = s.strip()

        # пропускаем ведущие пустые строки
        if not stripped and not cleaned and not in_banner:
            continue

        # --- детект начала баннера / EULA ---
        if any(k in stripped for k in eula_keywords):
            in_banner = True
            continue

        # --- внутри баннера: выкидываем все строки со звёздочками и пустые ---
        if in_banner:
            # типичный баннер — строки с '*' и пустые
            if stripped.startswith("*") or not stripped:
                continue
            # первая "нормальная" строка — конец баннера
            in_banner = False
            # эту строку дальше обработаем общей логикой

        # отдельные остатки EULA, которые могут идти одной строкой
        if any(
            k in stripped
            for k in (
                "Cisco End User License Agreement",
                "http://www.cisco.com/go/eula",
                "By using the software",
            )
        ):
            continue

        # terminal length 0
        if "terminal length 0" in stripped.lower():
            continue

        # системные сообщения (но НЕ все строки с '%')
        if stripped.startswith(syslog_prefixes):
            continue

        # эхо команды (если по какой-то причине ещё осталось)
        if cmd and cmd in stripped:
            continue

        # голое приглашение вида R1#, R1>
        # (нет пробелов, заканчивается на # или >)
        if (stripped.endswith("#") or stripped.endswith(">")) and " " not in stripped:
            continue

        cleaned.append(s)

    # убираем пустые строки в начале и конце
    while cleaned and not cleaned[0].strip():
        cleaned.pop(0)
    while cleaned and not cleaned[-1].strip():
        cleaned.pop()

    return "\n".join(cleaned) if cleaned else raw.strip()
