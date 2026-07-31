#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared PNETLab config-push engine for D1_new (network devices only).

Modeled on the C1-C4 checker framework (``pnetlab_lib`` + ``checker_lib``):
same login/session-join/console-map flow and the same ``IOSConsoleSession``
TCP console. Unlike the C-module checkers, this is *not* read-only: it
pastes ``Clean_Baseline_Scripts`` or ``Day2_Fault_Scripts`` ``.ios`` files
into the console of each Cisco device, the same way an expert would paste
them by hand. No host (Windows/Linux) devices are touched.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Reuse the proven PNETLab session/console library from Module C instead of
# duplicating it.
sys.path.insert(0, str(HERE.parent.parent / "C1"))

from pnetlab_lib import login, logout, join_session, get_nodes  # noqa: E402
from checker_lib import (  # noqa: E402
    BLUE, CYAN, GREEN, NC, PURPLE, RED, YELLOW,
    IOSConsoleSession, build_node_console_map,
    get_running_session_id_by_substring,
    _send_ios_command,  # reused verbatim for the multi-line config paste
)

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

DEFAULT_CREDS = HERE / "creds.json"

# RSA key generation and a full config paste take longer than a single
# ``show`` command; give the console generous, but bounded, time to catch up
# between lines instead of the checker's 1.5s default.
PUSH_IDLE_TIMEOUT = 2.5
PUSH_TOTAL_TIMEOUT = 90.0


def load_creds(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_config_text(path: Path) -> str:
    """Read a .ios file and prepend ``configure terminal`` if it isn't
    already the first real line (Clean_Baseline_Scripts files assume the
    operator typed it manually before pasting; Day2_Fault_Scripts files
    already include it themselves)."""
    text = path.read_text(encoding="utf-8")
    first_real_line = next(
        (line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("!")),
        "",
    )
    if first_real_line.lower() != "configure terminal":
        text = "configure terminal\n" + text
    return text


def push_config(session: IOSConsoleSession, config_text: str) -> str:
    """Paste a full config block into an already-connected console session."""
    if session.sock is None:
        session.connect()
    return _send_ios_command(
        session.sock,
        config_text,
        timeout=PUSH_TOTAL_TIMEOUT,
        idle_timeout=PUSH_IDLE_TIMEOUT,
    )


def evaluate_push(raw_output: str) -> tuple[bool, list[str]]:
    """Return (looks_ok, warning_lines) from the raw console transcript."""
    warnings = [
        line.strip()
        for line in raw_output.splitlines()
        if any(marker in line for marker in ("% Invalid input", "% Ambiguous", "% Incomplete", "% Unknown"))
    ]
    saved = "[OK]" in raw_output or "Building configuration" in raw_output
    return (not warnings and saved), warnings


def confirm(prompt: str) -> bool:
    answer = input(f"{YELLOW}{prompt} [yes/N]: {NC}").strip().lower()
    return answer in ("yes", "y")


def run_push(
    *,
    devices: list[str],
    config_dir: Path,
    filename_for: "callable[[str], str]",
    label: str,
    lab_substring: str,
    creds_path: Path,
    session_id: str | None,
    only_devices: list[str] | None,
    dry_run: bool,
    yes: bool,
) -> int:
    targets = only_devices or devices
    unknown = [d for d in targets if d not in devices]
    if unknown:
        print(f"{RED}[!] Unknown device(s) for {label}: {', '.join(unknown)}. "
              f"Valid: {', '.join(devices)}{NC}")
        return 2

    missing_files = []
    files_by_device = {}
    for dev in targets:
        path = config_dir / filename_for(dev)
        if not path.is_file():
            missing_files.append(str(path))
        else:
            files_by_device[dev] = path
    if missing_files:
        print(f"{RED}[!] Missing config file(s):{NC}")
        for m in missing_files:
            print(f"    {m}")
        return 2

    print(f"{PURPLE}===== {label}: {len(files_by_device)} device(s) targeted ====={NC}")
    for dev, path in files_by_device.items():
        print(f"  {dev:<10} <- {path.name}")
    print(f"{PURPLE}=========================================================={NC}")

    if dry_run:
        print(f"{CYAN}[dry-run] No connection made, no config sent.{NC}")
        for dev, path in files_by_device.items():
            print(f"\n{BLUE}--- {dev} ({path.name}) ---{NC}")
            print(load_config_text(path))
        return 0

    if not yes and not confirm(
        f"This will push live configuration to {len(files_by_device)} PNETLab "
        f"device(s) ({label}). Continue?"
    ):
        print(f"{YELLOW}Aborted by operator.{NC}")
        return 1

    creds = load_creds(creds_path)
    url = creds["pnet_url"]
    cookie = login(url, creds["username"], creds["password"])
    exit_code = 0
    try:
        sid = session_id or get_running_session_id_by_substring(url, cookie, lab_substring)
        join_session(url, sid, cookie)
        consoles = build_node_console_map(get_nodes(url, cookie).json())

        results = []
        for dev, path in files_by_device.items():
            if dev not in consoles:
                print(f"{RED}[!] {dev}: not found among the lab's nodes; skipped.{NC}")
                results.append((dev, False, "node not present in this PNETLab session"))
                continue

            host, port = consoles[dev]
            session = IOSConsoleSession(
                host, port,
                creds.get("enable_password"),
                dev,
                device_username=creds.get("device_username"),
                device_password=creds.get("device_password"),
            )
            print(f"\n{BLUE}[+] {dev}: connecting to {host}:{port} and pasting {path.name} ...{NC}")
            try:
                session.connect()
                config_text = load_config_text(path)
                raw = push_config(session, config_text)
                ok, warnings = evaluate_push(raw)
                if ok:
                    print(f"{GREEN}[OK] {dev}: config applied and saved.{NC}")
                else:
                    print(f"{RED}[!] {dev}: possible issue while applying config.{NC}")
                    for w in warnings:
                        print(f"      {w}")
                    if not warnings:
                        print("      No '[OK]' from 'write memory' seen in the console output.")
                results.append((dev, ok, "; ".join(warnings) if warnings else ("ok" if ok else "no confirmation seen")))
            except Exception as exc:
                print(f"{RED}[!] {dev}: {exc}{NC}")
                results.append((dev, False, str(exc)))
            finally:
                session.close()
            time.sleep(0.3)

        print(f"\n{PURPLE}===== {label}: summary ====={NC}")
        for dev, ok, detail in results:
            status = f"{GREEN}PASS{NC}" if ok else f"{RED}FAIL{NC}"
            print(f"  {dev:<10} {status}  {detail}")
        if any(not ok for _, ok, _ in results):
            exit_code = 1
    finally:
        try:
            logout(url)
        except Exception:
            pass
    return exit_code


def build_arg_parser(description: str) -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--lab", default="D1", help="substring of the running PNETLab lab name (used when --session-id is not given)")
    p.add_argument("--session-id", default=None, help="skip interactive lab selection and join this PNETLab session id directly")
    p.add_argument("--device", action="append", default=None, help="apply to only this device (repeatable); default is all devices in this package")
    p.add_argument("--dry-run", action="store_true", help="print what would be sent, without connecting to PNETLab")
    p.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    p.add_argument("--creds", default=str(DEFAULT_CREDS), help="path to creds.json")
    return p
