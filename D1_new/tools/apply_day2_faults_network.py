#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Push D1_new Day2_Fault_Scripts to the PNETLab network devices only.

Only the four Cisco devices involved in the Day 2 closed-control tickets
(T04, T06, T08, T09) are touched. Windows/Linux Day 2 faults (T01, T02, T03,
T05, T07, T10) are applied from inside each VM instead - see
``Day2_Fault_Scripts/windows`` and ``Day2_Fault_Scripts/linux``.

Restore every device to the clean-baseline snapshot before running this -
see ``Clean_Baseline_Scripts/docs/WHAT_TO_SNAPSHOT.md`` - and never combine
Day 1 and Day 2 faults.

Usage:
    py apply_day2_faults_network.py --dry-run
    py apply_day2_faults_network.py --lab D1
    py apply_day2_faults_network.py --session-id 4 --yes
    py apply_day2_faults_network.py --device DC-GW
"""
from __future__ import annotations

from pathlib import Path

from d1_pnetlab_push import build_arg_parser, run_push

HERE = Path(__file__).resolve().parent
CONFIG_DIR = HERE.parent / "Day2_Fault_Scripts" / "cisco" / "day2"

DEVICES = ["DC-GW", "DC2", "HQ-GW1", "HQ-GW2"]


def filename_for(device: str) -> str:
    return f"{device}_apply_day2_matched_faults.ios"


def main() -> int:
    p = build_arg_parser("Apply the D1_new Day 2 faults to PNETLab network devices")
    a = p.parse_args()
    return run_push(
        devices=DEVICES,
        config_dir=CONFIG_DIR,
        filename_for=filename_for,
        label="Day 2 faults",
        lab_substring=a.lab,
        creds_path=Path(a.creds),
        session_id=a.session_id,
        only_devices=a.device,
        dry_run=a.dry_run,
        yes=a.yes,
    )


if __name__ == "__main__":
    raise SystemExit(main())
