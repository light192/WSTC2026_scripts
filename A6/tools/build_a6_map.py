#!/usr/bin/env python3
"""Build the A6 evaluator TSV from the approved marking workbook."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

from openpyxl import load_workbook


HEADER = [
    "CriterionID", "Subsection", "Description", "MaxMark", "RunFrom",
    "Commands", "ExpectedResult", "Notes",
]


def clean(value: object) -> str:
    if value is None:
        return ""
    return " ".join(str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").split())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("workbook", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    workbook = load_workbook(args.workbook, data_only=True, read_only=True)
    sheet = workbook["Expert Marking Sheet"]
    how_sheet = workbook["How to Mark"]
    safe_notes = {
        clean(row[0]): clean(row[6])
        for row in how_sheet.iter_rows(min_row=5, values_only=True)
        if row[0]
    }
    rows = []
    for row in sheet.iter_rows(min_row=5, values_only=True):
        criterion, aspect, subsection, description, expected, mark, kind, procedure = row[:8]
        if not aspect or not str(aspect).startswith(tuple("ABCDEFGHI")):
            continue
        rows.append([
            clean(aspect), clean(subsection), clean(description), clean(mark),
            clean(criterion), clean(procedure), clean(expected), safe_notes.get(clean(aspect), ""),
        ])

    if len(rows) != 73 or abs(sum(float(row[3]) for row in rows) - 25.0) > 1e-9:
        raise SystemExit("unexpected A6 workbook content: expected 73 aspects / 25.00 marks")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(HEADER)
        writer.writerows(rows)


if __name__ == "__main__":
    main()
