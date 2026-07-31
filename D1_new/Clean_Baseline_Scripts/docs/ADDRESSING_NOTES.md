# Addressing design notes — D1_new

This baseline was rebuilt from scratch so that every IP address, VLAN, and FQDN
matches `D1_Day2_Competitor_Task_EN_styled.pdf` (device/interface map, hosts &
services table, network device roles). It replaces the older
`D1_Clean_Baseline_Scripts` / `D1_Fault_Scripts_MATCHED_TO_TASKBOOKS` packages,
which were built against a different, undocumented addressing plan
(172.19.0.0/30 WAN links, 10.255.19.0/30 MPLS links, VLAN-segmented
10.19.110.0/24 + 10.19.120.0/24 DC network, `corp.d1.skills`/`dc.d1.skills`
AD domain) that does not match the taskbook.

## What comes straight from the PDF

- All Cloud DC / Internet / MPLS / DC-GW / HQ-GW1 / HQ-GW2 point-to-point
  networks — taken verbatim from the "Device and interface map" table.
- All host IPs and FQDNs — taken verbatim from the "Hosts and services" table
  (single DNS suffix `skill39.d1` for every host, HQ and DC alike).
- DC server network is one flat `/24` (`10.21.10.0/24`) with **no VLANs** —
  the PDF does not describe any DC-side VLAN split, unlike the old baseline.

## Decisions made to fill gaps the PDF leaves open

The taskbook is a competitor-facing summary; it doesn't specify every
implementation detail. Where it was silent, the following choices were made
and are recorded here so they can be revised if the real PNETLab source
schema says otherwise:

- **Cloud service / backup loopbacks (10.201.1.1/32 on DC1, 10.201.2.1/32 on
  DC2).** The PDF talks about "the Cloud service" (T04) and "the Cloud DC
  backup target" (T08) but never gives a concrete IP for either — it only
  lists DC1/DC2's physical interface addresses. Since DC1/DC2 are plain
  Cisco routers (not app servers) per the "Hosts and services" table, the
  loopbacks were added inside the already-allocated Cloud DC block
  (`10.201.0.0/24`) rather than inventing an unrelated subnet. DC1 answers
  HTTP/80 on its loopback (`ip http server`) to represent the cloud
  service; DC2 answers SSH/22 on its loopback (existing router management
  SSH) to represent the backup target.
- **HQ VLAN numbers (10 = users, 20 = servers).** The PDF's device/interface
  map marks the HQ-GW↔HQ-SW/HQ-SW-D uplinks as "trunk" but never states VLAN
  IDs. 10/20 were chosen to mirror the subnet numbering (`10.19.10.0/24`,
  `10.19.20.0/24`) — this is an arbitrary but harmless implementation detail.
- **HSRP interface tracking on HQ-GW1/HQ-GW2.** Modern IOS's `standby track`
  only accepts an enhanced object-tracking object number, not an interface
  name directly. Each gateway defines `track 1 interface GigabitEthernet0/0
  line-protocol` (global config) and both HSRP groups reference it with
  `standby <group> track 1 decrement 20`, so losing the Internet uplink's
  line-protocol demotes HSRP priority by 20 and lets the peer preempt. The
  previous baseline had
  no tracking at all, which made ticket T06 ("failover via HQ-GW2 does not
  work") logically hollow — there was no working "clean" failover to break.
- **HQ-SW-D ↔ HQ-R segment.** The PDF marks the HQ-GW1→HQ-SW-D and
  HQ-GW2→HQ-SW-D uplinks as "trunk" but the only subnets documented on
  HQ-SW-D are the two routed `/30` links to HQ-R
  (`10.19.30.0/30`, `10.19.30.4/30`) — no VLAN/host traffic is described for
  HQ-SW-D at all, and no Day 2 ticket touches HQ-R. To avoid inventing an
  L2 loop or an undocumented second gateway presence in VLAN 10/20, those
  trunk links are configured as trunks carrying **no active host VLANs**;
  HQ-SW-D only actively routes (OSPF) on its two `/30` links to HQ-R. If a
  future taskbook version gives HQ-R/HQ-SW-D an actual role, revisit this.
- **DNS design.** HQ-AD01 is the AD-integrated authoritative DNS server for
  the single zone `skill39.d1` covering every host in the PDF's FQDN column.
  DC-LNX02 (PDF role: "DNS/utility service") runs a forwarding/caching
  resolver used by the DC hosts, forwarding recursive queries up to
  HQ-AD01 — this keeps ticket T10 (DNS recursion restricted between DC and
  HQ) meaningful without inventing extra AD sub-domains like the old
  baseline's `corp.d1.skills`/`dc.d1.skills` split.
