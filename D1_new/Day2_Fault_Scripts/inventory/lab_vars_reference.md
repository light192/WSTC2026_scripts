# D1_new lab variable reference

These Day 2 fault scripts are matched to `D1_Day2_Competitor_Task_EN_styled.pdf`
and to `Clean_Baseline_Scripts` in this same `D1_new` package — both use the
identical addressing plan, so **no IP translation or hedging is needed**
(unlike the older `D1_Fault_Scripts_MATCHED_TO_TASKBOOKS` package, which was
written against a different, undocumented addressing scheme than the
taskbook — see the chat analysis this package was built from).

Addressing used by these fault scripts (see
`Clean_Baseline_Scripts/inventory/D1_addressing_table.csv` for the full table
and `Clean_Baseline_Scripts/docs/ADDRESSING_NOTES.md` for the two additions
not explicit in the PDF):

| Role | Address | Source |
|---|---|---|
| HQ-WS01 | 10.19.10.10 | PDF hosts & services table |
| HQ-AD01 | 10.19.20.10 | PDF hosts & services table |
| HQ-FILE01 | 10.19.20.20 | PDF hosts & services table |
| HQ-LNX01 | 10.19.20.30 | PDF hosts & services table |
| DC-LNX01 | 10.21.10.10 | PDF hosts & services table |
| DC-LNX02 | 10.21.10.20 | PDF hosts & services table |
| DC-CL01 | 10.21.10.30 | PDF hosts & services table |
| DC-Win01 | 10.21.10.40 | PDF hosts & services table |
| DC-SVC01 | 10.21.10.50 | PDF hosts & services table |
| Cloud service loopback (DC1) | 10.201.1.1 | Added — see ADDRESSING_NOTES.md |
| Cloud backup loopback (DC2) | 10.201.2.1 | Added — see ADDRESSING_NOTES.md |

DNS suffix for every host is `skill39.d1` (single zone, authoritative on
HQ-AD01), matching the FQDN column of the PDF's hosts & services table
exactly.
