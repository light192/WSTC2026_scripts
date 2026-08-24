# A5 Verification Scripts - Shanghai/Shenzhen

Package built on the A4 structure (inherited from A3/A2/A1) for Training A5
"Integrated Enterprise Linux Services" - DNS, OpenLDAP+TLS+SSSD, DHCPv4+relay,
HTTPS portal with LDAP authentication, Chrony, central rsyslog, nftables,
Ansible.

- task source: `Module A/A5_Competitor_Task_EN_styled.pdf`;
- marking scheme source: `A5_Marking_Scheme_Balanced_Championship_Detailed_HowToMark_RU_v2.pdf`;
- map: `criteria/a5_criteria_map.tsv` - 96 measurement aspects, 25.00 points.

All interactive output (evaluator messages, criterion descriptions, expected
results) is plain ASCII English on purpose, so it renders correctly on any
console - including a bare hypervisor VGA/text console with no SSH/X11 and no
Cyrillic-capable font loaded.

## Topology and credentials

| Node | Role | IP (for SSH) |
|---|---|---|
| idm-a5 | Primary DNS, OpenLDAP, local CA, Chrony server, Ansible control | 10.55.40.10 |
| net-a5 | Secondary DNS, Kea DHCPv4, central rsyslog | 10.55.40.20 |
| portal-a5 | Apache HTTPS portal with LDAP authentication | 10.55.30.10 |
| sh-gw-a5 | L3 gateway, DHCP relay, nftables (Shanghai) | 10.55.10.1 |
| sh-client-a5 | DHCP client, DNS/LDAP/HTTPS validation | 10.55.10.100 |
| sz-gw-a5 | L3 gateway, DHCP relay, nftables (Shenzhen) | 10.55.20.1 |
| sz-client-a5 | DHCP client, user/evidence workstation | 10.55.20.100 |

Domain: `atlas.a5.test`. Password for the test LDAP users (nora, erlan) and
the default root password: `Skill39@A5`. Password for the `ldap-reader` bind
account: `Skill39@A5-Reader` (see the HowToMark).

## Running it

Recommended judge/evidence host - **idm-a5 (`10.55.40.10`)**, which is also
the Ansible control node and where `/opt/grading/a5/` lives. From the package
directory:

```bash
sudo bash remote/a5-evaluate-remote.sh \
  --report-dir /opt/grading/a5/eval-report
```

No pauses, or resuming from a specific aspect:

```bash
sudo bash remote/a5-evaluate-remote.sh --no-pause \
  --start-from A5.4.06 --report-dir /opt/grading/a5/eval-report
```

Restart/persistence aspects (A5.1.10 reboot; A5.3.12, A5.5.12, A5.6.08
restart) are SKIPped by default. After a coordinated restart/reboot:

```bash
sudo bash remote/a5-evaluate-remote.sh --post-reboot \
  --start-from A5.1.10 --report-dir /opt/grading/a5/post-reboot-report
```

## Verification format

Before each aspect, the script prints the description, the ready-to-run How
to Mark command, the expected result, the full stdout/stderr, and PASS/FAIL.
SSH always runs in BatchMode with a bounded timeout. Reports:

- `a5-results.tsv`;
- `a5-detail.log`;
- `a5-summary.txt`.

If DNS is not working, re-check the affected service by IP and record DNS as
the primary failure. Negative firewall/LDAP-anonymous/AXFR checks are scored
by the absence of a successful result, not by the exit code of a command
chained with `|| true`. During A5.2.12 (secondary-failover check) the primary
BIND9 is intentionally stopped - it must be restarted after the test (the
script does this automatically as the last command of that criterion).

Criteria A5.8.04-A5.8.07 (distinct Ansible common actions) and A5.9.02
(evidence matching the task's requirements) need a final manual confirmation
from the expert: the automation only collects `--list-tasks`/`--check`
output and greps the evidence files - deciding whether all four categories
are genuinely distinct (otherwise: Duplicate category = 0) is up to the
expert.

## Local fallback

On a node that is not reachable over SSH:

```bash
sudo bash local/a5-local-check.sh --no-pause \
  --report-dir /opt/grading/a5/local-report
```

Merging local results:

```bash
bash utils/a5-merge-local-results.sh /opt/grading/a5/local-report
```

Variables:

```bash
export A5_DOMAIN='atlas.a5.test'
export A5_ROOT_PASS='Skill39@A5'
export A5_LDAP_USER_PASS='Skill39@A5'
export A5_LDAP_READER_PASS='Skill39@A5-Reader'
export A5_TIMEOUT=6
export A5_CMD_TIMEOUT=180
```
