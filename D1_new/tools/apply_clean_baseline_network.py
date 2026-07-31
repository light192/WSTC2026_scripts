#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Push D1_new Clean_Baseline_Scripts to the PNETLab network devices only.

Hosts (Windows/Linux) are out of scope here - see
``Clean_Baseline_Scripts/windows`` and ``Clean_Baseline_Scripts/linux`` for
those, which are applied from inside each VM instead.

Usage:
    py apply_clean_baseline_network.py --dry-run
    py apply_clean_baseline_network.py --lab D1
    py apply_clean_baseline_network.py --session-id 4 --yes
    py apply_clean_baseline_network.py --device DC-GW --device Switch
"""
from __future__ import annotations

from pathlib import Path

from d1_pnetlab_push import build_arg_parser, run_push

HERE = Path(__file__).resolve().parent
CONFIG_DIR = HERE.parent / "Clean_Baseline_Scripts" / "cisco"

# Deployment order from Clean_Baseline_Scripts/docs/RUN_ORDER.md - core
# transit/WAN first, then the DC side, then the HQ side.
DEVICES = [
    "Internet", "MPLS",
    "DC1", "DC2", "DC-GW", "Switch",
    "HQ-GW1", "HQ-GW2", "HQ-SW", "HQ-SW-D", "HQ-R",
]


def filename_for(device: str) -> str:
    return f"{device}_clean_baseline.ios"


def main() -> int:
    p = build_arg_parser("Apply the D1_new clean baseline to PNETLab network devices")
    a = p.parse_args()
    return run_push(
        devices=DEVICES,
        config_dir=CONFIG_DIR,
        filename_for=filename_for,
        label="Clean baseline",
        lab_substring=a.lab,
        creds_path=Path(a.creds),
        session_id=a.session_id,
        only_devices=a.device,
        dry_run=a.dry_run,
        yes=a.yes,
    )


if __name__ == "__main__":
    raise SystemExit(main())
