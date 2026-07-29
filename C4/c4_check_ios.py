#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only PNETLab scorer for WSC2026 Training C4.

The console/session framework is the proven C3 implementation.  Evidence is
collected with operational ``show`` commands.  The few targeted configuration
commands below are explicitly authorised by the C4 Restricted Checks sheet;
the unrestricted ``show running-config`` command is never issued.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "C3"))
import c3_check_ios as c3

base = c3.base
C4_CHECKER_VERSION = "2026-07-29.34"
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

DEVICES = ["IR1","IR2","CR1","CR2","DS1","DS2","AS1","AS2",
           "IR3","DS3","DS4","BR1","BR2","AS3","AS4"]
EDGES = ["IR1","IR2","IR3","BR1","BR2"]
SPOKES = ["IR3","BR1","BR2"]
HUBS = ["IR1","IR2"]
SWITCHES = ["DS1","DS2","AS1","AS2","DS3","DS4","AS3","AS4"]
WAN = {"IR1":"GigabitEthernet0/3","IR2":"GigabitEthernet0/3",
       "IR3":"GigabitEthernet0/3","BR1":"GigabitEthernet0/0",
       "BR2":"GigabitEthernet0/0"}
NBMA = {"IR1":"203.0.113.66","IR2":"203.0.113.70",
        "IR3":"203.0.113.74","BR1":"203.0.113.78","BR2":"203.0.113.82"}
LOOPBACKS = {
 "IR1":"10.255.100.1","IR2":"10.255.100.2","CR1":"10.255.100.11",
 "CR2":"10.255.100.12","DS1":"10.255.100.21","DS2":"10.255.100.22",
 "IR3":"10.255.101.1","DS3":"10.255.101.11","DS4":"10.255.101.12",
 "BR1":"10.255.102.1","BR2":"10.255.103.1"}
ISP_PEERS = {"IR1":"203.0.113.65","IR2":"203.0.113.69",
             "IR3":"203.0.113.73","BR1":"203.0.113.77","BR2":"203.0.113.81"}

ASPECTS = []
ROWS = {}
with open(HERE / "c4_criteria.tsv", encoding="utf-8-sig") as criteria:
    next(criteria)
    for line in criteria:
        cols = line.rstrip("\n").split("\t")
        aspect = base.Aspect(int(cols[0]), cols[1], float(cols[5]), cols[3])
        ASPECTS.append(aspect)
        ROWS[aspect.id] = cols
BY_ID = {a.id:a for a in ASPECTS}
base.ASPECTS, base.BY_ID = ASPECTS, BY_ID

# Commands are deliberately complete and copyable.  They are also displayed
# before every aspect, including tests that require Expert actions.
MANUAL = {
 "A1":["show interfaces description","show ip interface brief","show interfaces status"],
 "A2":["show ip interface brief","show ip ospf interface brief","show ip eigrp interfaces",
       "show ip route 10.100.0.40 255.255.255.252"],
 "A3":["show bgp ipv4 unicast summary","show ip route 0.0.0.0"],
 "A4":["ping <remote-NBMA> source <local-WAN-interface> repeat 3"],
 "A5":["show bgp ipv4 unicast","show ip route bgp"],
 "A6":["show ip ospf interface brief","show ip ospf neighbor",
       "show ip ospf database summary","show ip route ospf"],
 "A7":["show vlan brief","show interfaces trunk","show spanning-tree mst",
       "show standby brief","show ip interface brief"],
 "A8":["show ip policy","show ip interface brief | include Tunnel","show ip route static",
       "show archive config differences nvram:startup-config system:running-config",
       "show startup-config | include ^ip route"],
 "B1":["show interfaces Tunnel100","show tunnel interface Tunnel100","show ip nhrp"],
 "B2":["show ip interface brief | include Tunnel100","show tunnel interface Tunnel100","show ip nhrp"],
 "B3":["show dmvpn detail","show ip nhrp","show ip nhrp traffic"],
 "B4":["show ip nhrp 172.20.100.1 detail"],
 "B5":["show ip nhrp multicast","show ip nhrp nhs","show dmvpn detail"],
 "B6":["show dmvpn detail","show ip nhrp",
       "show running-config interface Tunnel100 | include ip nhrp authentication"],
 "B7":["show ip nhrp detail",
       "show running-config interface Tunnel100 | include ip nhrp holdtime"],
 "B8":["show interfaces Tunnel100","show ip interface Tunnel100",
       "show running-config interface Tunnel100 | include ip tcp adjust-mss"],
 "B9":["show dmvpn","show ip nhrp"],
 "B10":["show dmvpn","show ip nhrp nhs","show interfaces Tunnel100"],
 "B11":["show interfaces tunnel","show dmvpn"],
 "B12":["show ip nhrp traffic","show dmvpn detail"],
 "B13":["show ip nhrp"],
 "B14":["show ip cef 10.103.0.0/16 detail","show ip cef 10.102.0.0/16 detail","show dmvpn"],
 "B15":["show dmvpn","show ip nhrp","show ip cef 10.103.0.0/16 detail"],
 "C1":["show interfaces Tunnel200","show tunnel interface Tunnel200","show ip nhrp"],
 "C2":["show ip interface brief | include Tunnel200","show tunnel interface Tunnel200","show ip nhrp"],
 "C3":["show dmvpn detail","show ip nhrp","show ip nhrp traffic"],
 "C4":["show ip nhrp 172.20.200.1 detail"],
 "C5":["show ip nhrp multicast","show ip nhrp nhs","show dmvpn detail"],
 "C6":["show dmvpn","show ip nhrp"],
 "C7":["show ip nhrp detail","show dmvpn detail"],
 "C8":["show interfaces Tunnel200","show ip interface Tunnel200",
       "show running-config interface Tunnel200 | include ip tcp adjust-mss"],
 "C9":["show dmvpn","show ip nhrp"],
 "C10":["show dmvpn","show ip nhrp nhs","show interfaces Tunnel200"],
 "C11":["show dmvpn","show ip nhrp","show ip eigrp neighbors","show crypto session detail","show logging"],
 "D1":["show crypto ikev2 proposal"],
 "D2":["show crypto ikev2 policy"],
 "D3":["show crypto ikev2 sa detailed",
       "show running-config | section crypto ikev2 keyring"],
 "D4":["show crypto ikev2 profile","show crypto ikev2 sa detailed"],
 "D5":["show crypto ipsec transform-set","show crypto ipsec sa","show crypto session detail"],
 "D6":["show crypto ipsec profile","show crypto session detail"],
 "D7":["show crypto ikev2 sa","show crypto ipsec sa","show crypto session detail"],
 "D8":["show crypto session detail",
       "show running-config interface Tunnel100 | include tunnel protection",
       "show running-config interface Tunnel200 | include tunnel protection"],
 "D9":["show crypto ikev2 sa","show crypto session detail"],
 "D10":["show crypto ikev2 sa","show crypto session detail"],
 "D11":["show crypto ipsec sa"],
 "D12":["show crypto ipsec sa","show crypto session detail","show ip nhrp",
        "show ip cef 10.103.0.0/16 detail",
        "ping 10.103.10.1 source 10.102.10.1 repeat 5",
        "ping 10.102.10.1 source 10.103.10.1 repeat 5"],
 "E1":["show ip protocols","show eigrp address-family ipv4 interfaces"],
 "E2":["show ip protocols","show ip eigrp topology 0.0.0.0/0","show ip interface brief | include Loopback0"],
 "E3":["show ip protocols","show ip eigrp interfaces"],
 "E4":["show ip eigrp neighbors"],
 "E5":["show ip eigrp neighbors"],
 "E6":["show ip eigrp interfaces detail Tunnel100","show ip eigrp interfaces detail Tunnel200"],
 "E7":["show ip eigrp topology","show ip nhrp","show dmvpn"],
 "E8":["show ip eigrp neighbors detail"],
 "E9":["show interfaces Tunnel100","show interfaces Tunnel200"],
 "E10":["show ip eigrp interfaces detail","show ip eigrp neighbors"],
 "E11":["show ip protocols","show ip route eigrp"],
 "E12":["show ip route 10.102.0.0","show ip eigrp topology 10.102.0.0/16"],
 "E13":["show ip route 10.103.0.0","show ip eigrp topology 10.103.0.0/16"],
 "E14":["show ip protocols","show route-map","show ip eigrp topology 10.100.0.0/16"],
 "E15":["show ip ospf database external 10.101.0.0",
        "show ip ospf database external 10.102.0.0",
        "show ip ospf database external 10.103.0.0"],
 "E16":["show ip protocols","show route-map","show ip eigrp topology 10.101.0.0/16",
        "show ip ospf database external 10.100.0.0"],
 "E17":["show ip route 10.100.0.0","show ip route 10.101.0.0",
        "show ip route 10.102.0.0","show ip route 10.103.0.0"],
 "E18":["show ip route 10.101.0.0","show ip route 10.102.0.0",
        "show ip route 10.103.0.0","show ip ospf database external"],
 "E19":["show ip route 10.100.0.0","show ip route 10.102.0.0",
        "show ip route 10.103.0.0","show ip ospf database external"],
 "E20":["show ip route eigrp","show ip ospf database external","show ip eigrp topology"],
 "F1":["show class-map"],
 "F2":["show policy-map C4-WAN-QOS","show policy-map interface"],
 "F3":["show policy-map C4-WAN-QOS","show policy-map interface"],
 "F4":["show policy-map C4-WAN-QOS","show policy-map interface"],
 "F5":["show policy-map interface",
       "show running-config interface Tunnel100 | include qos pre-classify",
       "show running-config interface Tunnel200 | include qos pre-classify"],
 "F6":["show policy-map C4-WAN-PARENT","show policy-map interface"],
 "F7":["show policy-map interface <WAN-interface>"],
 "F8":["show policy-map interface GigabitEthernet0/3  # IR1/IR2/IR3",
       "show policy-map interface GigabitEthernet0/0  # BR1/BR2"],
 "F9":["show policy-map interface <WAN-interface>"],
 "F10":["show policy-map interface <WAN-interface>"],
 "G1":["show ip sla configuration 401","show ip sla statistics 401"],
 "G2":["show ip sla configuration 402","show ip sla statistics 402"],
 "G3":["show ip sla configuration 403","show ip sla statistics 403"],
 "G4":["show track 401","show track 402","show track 403"],
 "G5":["show ip sla statistics <operation>","show track <operation>"],
 "G6":["show track <operation>","show ip policy","show ip route static"],
 "H1":["show ip nat translations","show ip nat statistics"],
 "H2":["show ip nat translations","show ip nat statistics"],
 "H3":["show ip nat translations","show ip nat statistics"],
 "H4":["show ip nat translations","show ip nat statistics",
       "curl -sS --max-time 5 -o /dev/null -w HTTP_STATUS=%{http_code} http://198.51.100.121/healthz  # PC3 и PC4"],
 "H5":["show ip ssh",
       "show running-config | section line vty",
       "show access-lists | include IP access list|permit|deny",
       "show ip interface | include is up|Inbound access list|Outgoing access list"],
 "H6":["show ntp associations","show ntp status","show logging"],
 "H7":["show snmp user","show snmp group","show snmp",
       "show flow monitor","show flow exporter","show flow interface",
       "show ip flow export"],
 "H8":["ping <remote-loopback> source Loopback0 repeat 3"],
 "I1":["show interfaces GigabitEthernet0/3  # IR1 only",
       "show dmvpn","show ip nhrp","show crypto session",
       "show ip eigrp neighbors","show track"],
 "I2":["show ip route eigrp","show dmvpn","show ip cef <remote-summary> detail"],
 "I3":["show track 401","show track 402","show track 403"],
 "I4":["show dmvpn","show ip nhrp","show ip cef 10.103.0.0/16 detail","show crypto ipsec sa"],
 "I5":["show dmvpn","show ip nhrp","show crypto session","show ip eigrp neighbors"],
 "I6":["show track 401","show track 402","show track 403"],
 "I7":["show dmvpn","show ip nhrp","show ip cef 10.103.0.0/16 detail","show crypto ipsec sa"],
 "I8":["show dmvpn","show ip eigrp neighbors","show ip route eigrp"],
 "I9":["show dmvpn","show crypto session","show ip eigrp neighbors","show ip route eigrp"],
 "I10":["show policy-map interface <WAN-interface>","show dmvpn","show track"],
}

def devices_for(aid):
    if aid in {"A1","H6"}: return DEVICES
    if aid in {"A3","A4","A5","E1","E2","E3","F7","F8","H7"}: return EDGES
    if aid in {"A2"}: return ["IR2","IR3"]
    if aid in {"A6"}: return ["IR1","IR2","CR1","CR2","DS1","DS2","IR3","DS3","DS4"]
    if aid in {"A7"}: return SWITCHES
    if aid.startswith("B"): return ["IR1"] if aid in {"B1","B3","B9"} else (SPOKES if aid in {"B2","B4","B5","B10","B13","B14"} else ["IR1"]+SPOKES)
    if aid.startswith("C"): return ["IR2"] if aid in {"C1","C3","C9"} else (SPOKES if aid in {"C2","C4","C5","C10"} else ["IR2"]+SPOKES)
    if aid.startswith("D"):
        if aid=="D7":
            return HUBS
        if aid=="D12":
            return ["BR1","BR2"]
        return SPOKES if aid in {"D8","D9","D10"} else EDGES
    if aid=="E4": return ["IR1"]+SPOKES
    if aid in {"E6","E14","E15"}: return HUBS
    if aid in {"E5","E8"}: return ["IR2"]+SPOKES
    if aid in {"E12"}: return ["IR1","IR2","IR3","BR2"]
    if aid in {"E13"}: return ["IR1","IR2","IR3","BR1"]
    if aid in {"E16"}: return ["IR3","DS3","DS4"]
    if aid in {"E17"}: return ["BR1","BR2"]
    if aid in {"E18"}: return ["CR1","CR2","DS1","DS2"]
    if aid in {"E19"}: return ["DS3","DS4"]
    if aid.startswith("E"): return EDGES
    if aid.startswith("F"): return EDGES
    if aid=="G1": return ["IR3"]
    if aid=="G2": return ["BR1"]
    if aid=="G3": return ["BR2"]
    if aid.startswith("G"): return SPOKES
    if aid=="H1": return ["BR1"]
    if aid=="H2": return ["BR2"]
    if aid=="H3": return ["IR3","BR1","BR2"]
    if aid=="H4": return ["IR3"]
    if aid=="H5": return DEVICES
    if aid=="H8": return EDGES
    if aid.startswith("I"): return ["IR1","IR2"]+SPOKES
    return EDGES

class Scorer(c3.Scorer):
    """C4 evaluator.  Every automatic action is read-only."""

    def ios_sourced_ping(self, device, target, source, repeat=3):
        """Run a read-only IOS ping with an explicit routed source address."""
        output=self.cmd(
            device,
            f"ping {target} source {source} repeat {repeat}",
            refresh=True)
        match=re.search(r"Success +rate +is +(\d+) +percent",output,re.I)
        return bool(match and int(match.group(1))>0),output

    def connect(self):
        super().connect()
        # C2/C3 framework knows SVR1/SVR2; C4 names the independent
        # validation host JUDGE-SRV, so attach its read-only shell explicitly.
        dev="JUDGE-SRV"
        if dev in self.consoles and dev not in self.host_sessions:
            host,port=self.consoles[dev]
            session=base.LinuxSSHSession(
                host,port,dev,
                self.creds.get("server_username","student"),
                self.creds.get("server_password","StudentPass"))
            try:
                session.connect()
                self.host_sessions[dev]=session
            except Exception as exc:
                self.host_errors[dev]=str(exc)
                print(f"{base.YELLOW}[!] {dev} SSH: {exc}{base.NC}")

    def filtered_command(self, command):
        # Avoid gigantic outputs while retaining the dedicated operational data.
        if command == "show ip route eigrp":
            return command + " | include ^D|10\\.10[0-3]\\."
        if command == "show ip ospf database external":
            return command + " | include Link State ID|Advertising Router|Metric Type|Metric:|Route Tag"
        return command

    def expected(self, aid): return ROWS[aid][4]

    @staticmethod
    def print_expected(aspect):
        row = ROWS[aspect.id]
        print(f"{base.CYAN}Ожидаемый результат:{base.NC}")
        print(f"  {aspect.title}")
        print(f"  Максимальный балл: {aspect.mark:.3f}")
        print(f"  Проверяемые свойства: {row[4]}")
        print(f"{base.GREEN}Готовые команды для отдельной ручной проверки (можно скопировать):{base.NC}")
        if aspect.id=="A4":
            for source in EDGES:
                for target in EDGES:
                    if source!=target:
                        print(f"  [{source}] ping {NBMA[target]} source {WAN[source]} repeat 3")
            return
        if aspect.id=="B12":
            print("  [IR1] show ip nhrp traffic")
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 10")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 10")
            print("  [IR1] show ip nhrp traffic")
            print("  [BR1] show ip nhrp 172.20.100.12 detail")
            print("  [BR1] show ip cef 10.103.0.0/16 detail")
            print("  [BR2] show ip nhrp 172.20.100.11 detail")
            print("  [BR2] show ip cef 10.102.0.0/16 detail")
            return
        if aspect.id=="B15":
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 5")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 5")
            print("  [BR1] show ip nhrp 172.20.100.12 detail")
            print("  [BR1] show ip cef 10.103.0.0/16 detail")
            print("  [BR2] show ip nhrp 172.20.100.11 detail")
            print("  [BR2] show ip cef 10.102.0.0/16 detail")
            return
        if aspect.id=="F8":
            for dev in EDGES:
                interface=WAN[dev]
                peer=ISP_PEERS[dev]
                print(f"  [{dev}] show policy-map interface {interface}")
                print(
                    f"  [{dev}] ping {peer} source {interface} "
                    "dscp 46 repeat 5")
                print(f"  [{dev}] show policy-map interface {interface}")
                print(
                    f"  [{dev}] ping {peer} source {interface} "
                    "dscp 26 repeat 5")
                print(f"  [{dev}] show policy-map interface {interface}")
                print(
                    f"  [{dev}] ping {peer} source {interface} repeat 5")
                print(f"  [{dev}] show policy-map interface {interface}")
            return
        if aspect.id=="C11":
            for dev in ("IR2","IR3","BR1","BR2"):
                print(f"  [{dev}] show interfaces Tunnel200")
                print(f"  [{dev}] show dmvpn")
                print(f"  [{dev}] show ip nhrp")
                print(f"  [{dev}] show ip eigrp neighbors")
                print(f"  [{dev}] show crypto session detail")
            print("  # Для проверки отсутствия flaps повторить команды через 60 секунд.")
            return
        if aspect.id=="D11":
            print("  [BR1] show crypto ipsec sa")
            print("  [BR2] show crypto ipsec sa")
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 5")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 5")
            print("  [BR1] show crypto ipsec sa")
            print("  [BR2] show crypto ipsec sa")
            print("  [PNETLab] Capture BR1/BR2 WAN: ESP должен присутствовать, GRE protocol 47 отсутствовать")
            return
        if aspect.id=="D12":
            print("  [BR1] show crypto session detail")
            print("  [BR2] show crypto session detail")
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 10")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 10")
            print("  [BR1] show ip nhrp 172.20.100.12 detail")
            print("  [BR1] show ip cef 10.103.0.0/16 detail")
            print("  [BR1] show crypto session detail")
            print("  [BR2] show ip nhrp 172.20.100.11 detail")
            print("  [BR2] show ip cef 10.102.0.0/16 detail")
            print("  [BR2] show crypto session detail")
            return
        if aspect.id=="H8":
            for dev in ("IR1","BR1","BR2"):
                print(f"  [{dev}] ping ops.c4.skill39.local source "
                      f"{LOOPBACKS[dev]} repeat 2")
            print(f"  [IR1] ping 10.101.130.10 source {LOOPBACKS['IR1']} repeat 3")
            for device,address in LOOPBACKS.items():
                print(f"  [IR3] ping {address} source {LOOPBACKS['IR3']} "
                      f"repeat 3  ! {device}")
            return
        if aspect.id=="H4":
            print("  [IR3] show ip nat translations")
            print("  [IR3] show ip nat statistics")
            print("  [PC3] curl -sS --max-time 5 -o /dev/null -w "
                  "'HTTP_STATUS=%{http_code}' http://198.51.100.121/healthz")
            print("  [PC4] curl -sS --max-time 5 -o /dev/null -w "
                  "'HTTP_STATUS=%{http_code}' http://198.51.100.121/healthz")
            return
        if aspect.id=="H5":
            for dev in DEVICES:
                print(f"  [{dev}] show ip ssh")
                print(f"  [{dev}] show running-config | section line vty")
                print(f"  [{dev}] show access-lists | include IP access list|permit|deny")
            for dev in DEVICES:
                print(f"  [{dev}] show ip interface | include is up|Inbound access list|Outgoing access list")
            return
        if aspect.id=="H7":
            for dev in EDGES:
                print(f"  [{dev}] show snmp user")
                print(f"  [{dev}] show snmp group")
                print(f"  [{dev}] show snmp")
                print(f"  [{dev}] show flow monitor")
                print(f"  [{dev}] show flow exporter")
                print(f"  [{dev}] show flow interface")
                print(f"  [{dev}] show ip flow export")
            loopbacks=" ".join(LOOPBACKS[dev] for dev in EDGES)
            print("  [JUDGE-SRV] export C4_SNMP_USER='<protected-user>'")
            print("  [JUDGE-SRV] export C4_SNMP_AUTH='<protected-auth-key>'")
            print("  [JUDGE-SRV] export C4_SNMP_PRIV='<protected-privacy-key>'")
            print(
                "  [JUDGE-SRV] for ip in "
                f"{loopbacks}; do echo \"=== $ip ===\"; "
                "snmpwalk -v3 -l authPriv -u \"$C4_SNMP_USER\" "
                "-a SHA -A \"$C4_SNMP_AUTH\" -x AES "
                "-X \"$C4_SNMP_PRIV\" \"$ip\" 1.3.6.1.2.1.1; done")
            print("  [SVR1] sudo ss -lunp")
            print(
                "  [SVR1] sudo timeout 20 tcpdump -nn -i any "
                "'udp and not port 53'")
            print(
                "  # SNMP credentials берутся только из protected Expert "
                "Data и не печатаются checker-ом.")
            return
        if aspect.id=="I1":
            print("  [IR1] show interfaces GigabitEthernet0/3")
            for dev in EDGES:
                print(f"  [{dev}] show dmvpn")
                print(f"  [{dev}] show ip nhrp")
                print(f"  [{dev}] show crypto session")
                print(f"  [{dev}] show ip eigrp neighbors")
                print(f"  [{dev}] show track")
            return
        if aspect.id=="I2":
            site_summary={"HQ":"10.100.0.0","IR3":"10.101.0.0","BR1":"10.102.0.0",
                          "BR2":"10.103.0.0"}
            for dev in SPOKES:
                print(f"  [{dev}] show ip eigrp neighbors")
                print(f"  [{dev}] show dmvpn")
                for owner,summary in site_summary.items():
                    if owner!=dev:
                        print(f"  [{dev}] show ip route {summary} 255.255.0.0")
                        print(f"  [{dev}] show ip cef {summary}/16 detail")
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 3")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 3")
            return
        if aspect.id=="I3":
            for dev,number in (("IR3","401"),("BR1","402"),("BR2","403")):
                print(f"  [{dev}] show track {number}")
                print(f"  [{dev}] show ip sla configuration {number}")
                print(f"  [{dev}] show ip sla statistics {number}")
            return
        if aspect.id=="G5":
            for dev,number in (("IR3","401"),("BR1","402"),("BR2","403")):
                print(f"  [{dev}] show ip sla statistics {number}")
                print(f"  [{dev}] show track {number}")
            return
        if aspect.id=="I6":
            for dev,number in (("IR3","401"),("BR1","402"),("BR2","403")):
                print(f"  [{dev}] show track {number}")
                print(f"  [{dev}] show ip sla configuration {number}")
                print(f"  [{dev}] show ip sla statistics {number}")
            return
        if aspect.id=="I8":
            print("  [BR1] show interfaces Tunnel100")
            for dev in ("IR3","BR1","BR2"):
                print(f"  [{dev}] show ip eigrp neighbors")
                print(f"  [{dev}] show dmvpn")
            print("  [BR1] show ip route 10.101.0.0 255.255.0.0")
            print("  [BR1] show ip cef 10.101.0.0/16 detail")
            print("  [BR1] show ip route 10.103.0.0 255.255.0.0")
            print("  [BR1] show ip cef 10.103.0.0/16 detail")
            print("  [IR3] show ip cef 10.103.0.0/16 detail")
            print("  [BR2] show ip cef 10.101.0.0/16 detail")
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 3")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 3")
            return
        if aspect.id=="I4":
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 10")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 10")
            print("  [BR1] show ip nhrp 172.20.200.12 detail")
            print("  [BR1] show ip cef 10.103.0.0/16 detail")
            print("  [BR1] show crypto session detail")
            print("  [BR2] show ip nhrp 172.20.200.11 detail")
            print("  [BR2] show ip cef 10.102.0.0/16 detail")
            print("  [BR2] show crypto session detail")
            return
        if aspect.id=="I5":
            print("  [IR1] show interfaces GigabitEthernet0/3")
            for dev in EDGES:
                print(f"  [{dev}] show dmvpn")
                print(f"  [{dev}] show ip nhrp")
                print(f"  [{dev}] show crypto session")
                print(f"  [{dev}] show ip eigrp neighbors")
            for dev in SPOKES:
                for summary in ("10.100.0.0","10.101.0.0",
                                "10.102.0.0","10.103.0.0"):
                    print(f"  [{dev}] show ip route {summary} 255.255.0.0")
                    print(f"  [{dev}] show ip cef {summary}/16 detail")
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 3")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 3")
            return
        if aspect.id=="I7":
            print("  # Старый BR1↔BR2 shortcut предварительно очищает эксперт")
            print("  [BR1] show crypto session detail")
            print("  [BR2] show crypto session detail")
            print("  [BR1] ping 10.103.10.1 source 10.102.10.1 repeat 10")
            print("  [BR2] ping 10.102.10.1 source 10.103.10.1 repeat 10")
            print("  [BR1] show ip nhrp 172.20.100.12 detail")
            print("  [BR1] show ip cef 10.103.0.0/16 detail")
            print("  [BR1] show crypto session detail")
            print("  [BR2] show ip nhrp 172.20.100.11 detail")
            print("  [BR2] show ip cef 10.102.0.0/16 detail")
            print("  [BR2] show crypto session detail")
            return
        for command in MANUAL.get(aspect.id, []):
            print(f"  {command}")

    def run_commands(self, aid):
        records = {}
        for dev in devices_for(aid):
            outputs = []
            for raw in MANUAL.get(aid, []):
                # Skip unresolved explanatory placeholders, but substitute the
                # concrete WAN interface placeholder used by F7/F8/I10.
                if (("<" in raw and "<WAN-interface>" not in raw)
                        or raw.startswith("ping ")):
                    continue
                # IOS routers do not support the switch-only status command.
                # Their physical state is proven by description/IP brief.
                if raw=="show interfaces status" and dev not in SWITCHES:
                    continue
                # The protected keyring inspection is intentionally manual:
                # its output may contain the PSK and must not enter evidence.
                if aid=="D3" and "crypto ikev2 keyring" in raw:
                    continue
                command = raw.replace("<WAN-interface>", WAN.get(dev,"GigabitEthernet0/3"))
                # Commands for one cloud are only valid where that tunnel exists.
                if "Tunnel100" in command and dev=="IR2": continue
                if "Tunnel200" in command and dev=="IR1": continue
                try: outputs.append(self.cmd(dev,command))
                except Exception as exc: outputs.append(f"[ERROR] {exc}")
            records[dev] = "\n".join(outputs)
        return records

    @staticmethod
    def has(text, pattern): return bool(re.search(pattern,text,re.I|re.M))

    @staticmethod
    def h7_snmp_state(text):
        """Return safe SNMPv3 configuration and polling-activity evidence."""
        v3=bool(re.search(
            r"(?i)(?:security\s+(?:model|level)\s*[:=]?\s*v?3|"
            r"\bv3\s+(?:priv|auth)\b|SNMPv3)",text))
        authentication=bool(re.search(
            r"(?i)(?:authentication\s+protocol|auth(?:entication)?)[^\r\n]*"
            r"(?:SHA|HMAC)",text))
        privacy=bool(re.search(
            r"(?i)(?:privacy\s+protocol|priv(?:acy)?)[^\r\n]*"
            r"(?:AES|DES)|\bauthPriv\b|\bv3\s+priv\b",text))
        activity=0
        for pattern in (
            r"(?im)^\s*(\d+)\s+Get-request\s+PDUs",
            r"(?im)^\s*(\d+)\s+Get-next\s+PDUs",
            r"(?im)^\s*(\d+)\s+Get-bulk\s+PDUs",
            r"(?im)^\s*(\d+)\s+SNMP\s+packets\s+input",
        ):
            activity += sum(int(value) for value in re.findall(pattern,text))
        return v3 and authentication and privacy, activity > 0

    @staticmethod
    def h7_flow_state(text):
        """Return configured exporter chain and successful-export evidence."""
        monitor=bool(re.search(
            r"(?im)^\s*(?:Flow\s+Monitor|Monitor\s+Name)\s*:?\s+\S+",
            text))
        exporter=bool(re.search(
            r"(?im)^\s*(?:Flow\s+Exporter|Exporter\s+Name)\s*:?\s+\S+",
            text))
        destination=bool(re.search(
            r"(?im)^\s*(?:Destination(?:\s+IP)?(?:\s+address)?|"
            r"Export\s+destination)\s*:?\s*10\.101\.130\.10\b",
            text))
        attached=bool(re.search(
            r"(?is)(?:Interface\s+\S+.*?(?:Flow\s+Monitor|"
            r"FNF:\s*monitor)|(?:Flow\s+Monitor|FNF:\s*monitor|"
            r"Monitor\s+\S+).*?\b(?:Input|Output)\b)",text))
        sent=0
        for pattern in (
            r"(?im)^\s*Successfully\s+sent(?:\s+export\s+packets)?"
            r"\s*:?\s*(\d+)",
            r"(?im)^\s*(\d+)\s+(?:flows|datagrams|packets)\s+exported",
            r"(?im)^\s*(\d+)\s+export\s+packets\s+were\s+sent",
        ):
            sent += sum(int(value) for value in re.findall(pattern,text))
        return monitor and exporter and destination and attached, sent > 0

    @staticmethod
    def vty_source_acl(text):
        """Return the IPv4 inbound access-class applied to VTY lines."""
        match=re.search(
            r"(?im)^\s*access-class\s+(\S+)\s+in(?:\s+vrf-also)?\s*$",
            text)
        return match.group(1) if match else ""

    @staticmethod
    def acl_block(text, name):
        """Extract one named/numbered ACL from compact ``show access-lists``."""
        header=re.search(
            rf"(?im)^(?:Standard|Extended)\s+IP\s+access\s+list\s+"
            rf"{re.escape(name)}\s*$",text)
        if not header:
            return ""
        next_header=re.search(
            r"(?im)^(?:Standard|Extended)\s+IP\s+access\s+list\s+\S+\s*$",
            text[header.end():])
        end=(header.end()+next_header.start()) if next_header else len(text)
        return text[header.start():end]

    @staticmethod
    def bgp_peer_established(text, peer):
        """IOS summary uses a number in State/PfxRcd when the peer is established."""
        for line in text.splitlines():
            fields=line.split()
            if fields and fields[0]==peer:
                # Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
                return len(fields)>=10 and fields[-1].isdigit()
        return False

    @staticmethod
    def ipsec_packet_counters(text):
        """Return aggregate encaps/decaps counters from IOS IPsec SA output."""
        encaps=sum(int(value) for value in re.findall(
            r"#pkts encaps:\s*(\d+)",text,re.I))
        decaps=sum(int(value) for value in re.findall(
            r"#pkts decaps:\s*(\d+)",text,re.I))
        return encaps,decaps

    @staticmethod
    def ipsec_peer_snapshot(text, peer):
        """Return counters/state only for the IPsec SA belonging to one peer."""
        blocks=re.split(r"(?=^\s*protected vrf:)",text,flags=re.I|re.M)
        peer_re=re.escape(peer)
        selected=[
            block for block in blocks
            if re.search(rf"\bcurrent_peer\s+{peer_re}\b",block,re.I)
            or re.search(rf"\bremote crypto endpt\.:\s*{peer_re}\b",block,re.I)
        ]
        joined="\n".join(selected)
        return {
            "found":bool(selected),
            "active":bool(re.search(r"Status:\s*ACTIVE(?:\(ACTIVE\))?",joined,re.I)),
            "encaps":sum(int(value) for value in re.findall(
                r"#pkts encaps:\s*(\d+)",joined,re.I)),
            "decaps":sum(int(value) for value in re.findall(
                r"#pkts decaps:\s*(\d+)",joined,re.I)),
            "spis":tuple(sorted(set(re.findall(
                r"\bspi:\s*(0x[0-9A-F]+)",joined,re.I)))),
        }

    @staticmethod
    def peer_session_counters(text, peer):
        """Extract encrypted/decrypted counters only from a selected peer session."""
        encrypted=decrypted=0
        found=False
        for block in re.split(r"(?=Interface:\s*)",text,flags=re.I):
            # IOS XE ``show crypto session detail`` identifies the other end
            # differently between releases: ``Peer:``, IKEv2 ``remote``,
            # ``Phase1_id`` or the endpoints in ``IPSEC FLOW``.
            peer_seen=any(re.search(pattern,block,re.I) for pattern in (
                rf"\bPeer:\s*{re.escape(peer)}\b",
                rf"\bremote\s+{re.escape(peer)}(?:/\d+)?\b",
                rf"\bPhase1_id:\s*{re.escape(peer)}\b",
                rf"\bhost\s+{re.escape(peer)}\b",
            ))
            if not peer_seen:
                continue
            found=bool(re.search(
                r"UP-ACTIVE|IKEv2 SA:.*\bActive\b|Active SAs:\s*[1-9]\d*",
                block,re.I))
            encrypted+=sum(int(value) for value in re.findall(
                r"#pkts enc(?:'|ry)t?ed\s+(\d+)",block,re.I))
            decrypted+=sum(int(value) for value in re.findall(
                r"#pkts dec(?:'|ry)t?ed\s+(\d+)",block,re.I))
        return found,encrypted,decrypted

    @staticmethod
    def dynamic_dmvpn_peer(text, nbma, tunnel_address):
        """Match a dynamic peer row, without being fooled by the DMVPN legend."""
        for line in text.splitlines():
            if nbma in line and tunnel_address in line:
                return bool(re.search(r"\bD(?:T[12])?\b|\bDynamic\b",line,re.I))
        return False

    @staticmethod
    def dmvpn_peer_up(text, nbma, tunnel_address):
        """Confirm that one concrete NBMA/tunnel mapping is operational."""
        for line in text.splitlines():
            if nbma in line and tunnel_address in line:
                return bool(re.search(r"\bUP\b|\bRegistered\b",line,re.I))
        return False

    @staticmethod
    def eigrp_neighbor_on_tunnel(text, address, tunnel):
        """Recognize a neighbor row in named-EIGRP IOS output."""
        number=tunnel.removeprefix("Tunnel")
        # The task calls the clouds Tunnel100/Tunnel200, while the supplied
        # IOS image may expose the instantiated interfaces as
        # Tunnel1100/Tunnel1200.  Accept both forms and their Tu abbreviation.
        names=(f"Tunnel{number}",f"Tu{number}",
               f"Tunnel1{number}",f"Tu1{number}")
        for line in text.splitlines():
            if address in line and re.search(
                    rf"\b(?:{'|'.join(re.escape(name) for name in names)})\b",
                    line,re.I):
                return True
        return False

    @staticmethod
    def qos_child_class_packets(text, class_name):
        """Return the largest packet counter for a C4-WAN-QOS child class."""
        child=re.search(
            r"Service-policy\s*(?:output\s*)?:?\s*C4-WAN-QOS(?P<body>.*)",
            text,re.I|re.S)
        scope=child.group("body") if child else text
        blocks=re.split(r"(?=^\s*Class-map:)",scope,flags=re.I|re.M)
        counters=[]
        for block in blocks:
            heading=re.match(r"^\s*Class-map:\s*([^\r\n(]+)",block,re.I)
            if not heading or heading.group(1).strip().lower()!=class_name.lower():
                continue
            counters.extend(int(value) for value in re.findall(
                r"(?:Matched\s*:?\s*)?(\d+)\s+packets\b",block,re.I))
        return max(counters,default=0)

    @staticmethod
    def crypto_peer_counters(text, peer):
        """Return encrypted/decrypted packet sum for an active peer session."""
        blocks=re.split(r"(?=^\s*Interface:)",text,re.I|re.M)
        for block in blocks:
            if peer not in block:
                continue
            active=bool(re.search(r"UP-ACTIVE|IKEv2 SA:.*\bActive\b",block,re.I))
            values=[int(v) for v in re.findall(
                r"#pkts\s+(?:enc|dec)'ed\s+(\d+)",block,re.I)]
            if active:
                return sum(values)
        return -1

    def generic_state(self, aid, records):
        """Return useful per-device state tests for operational aspects."""
        tests=[]; labels=[]
        for dev,text in records.items():
            label=dev
            ok=bool(text.strip()) and "[ERROR]" not in text and "% Invalid" not in text
            if aid=="A2":
                iface="GigabitEthernet0/4" if dev=="IR2" else "GigabitEthernet0/2"
                ok=self.has(text,rf"(?:{iface}|Gi0/[24]).*administratively down")
            elif aid=="A3":
                peer=ISP_PEERS[dev]
                ok=self.bgp_peer_established(text,peer) and \
                   self.has(text,r'Known via\s+"bgp"|B\*\s+0\.0\.0\.0/0')
            elif aid=="A5":
                ok=not self.has(text,r"10\.10[0-3]\.0\.0/16")
            elif aid in {"B1","B2"}:
                addr={"IR1":"1","IR3":"13","BR1":"11","BR2":"12"}[dev]
                ok=self.has(text,rf"172\.20\.100\.{addr}") and self.has(text,r"Tunnel100.*up")
            elif aid in {"C1","C2"}:
                addr={"IR2":"1","IR3":"13","BR1":"11","BR2":"12"}[dev]
                ok=self.has(text,rf"172\.20\.200\.{addr}") and self.has(text,r"Tunnel200.*up")
            elif aid in {"B4","B5"}:
                ok="172.20.100.1" in text and NBMA["IR1"] in text
            elif aid in {"C4","C5"}:
                ok="172.20.200.1" in text and NBMA["IR2"] in text
            elif aid=="B6":
                ok=self.has(text,r"ip nhrp authentication\s+AURORA-C4")
            elif aid=="B7":
                ok=self.has(text,r"ip nhrp holdtime\s+300")
            elif aid=="B8":
                mtu_values=re.findall(
                    r"(?im)^\s*(?:IP\s+)?MTU\s+(?:is\s+)?(\d+)\s+bytes",
                    text)
                mtu_actual="1400" if "1400" in mtu_values else (
                    mtu_values[-1] if mtu_values else "<не найдено>")
                mss_match=re.search(
                    r"(?im)^\s*ip tcp adjust-mss\s+(\d+)\s*$",
                    text)
                mss_actual=mss_match.group(1) if mss_match else "<не найдено>"
                mtu=mtu_actual=="1400"
                mss=mss_actual=="1360"
                tests.extend([mtu,mss])
                labels.extend([
                    f"{dev} Tunnel100 IP MTU: ожидалось 1400; получено {mtu_actual}",
                    f"{dev} Tunnel100 TCP MSS: ожидалось 1360; получено {mss_actual}"])
                continue
            elif aid=="C8":
                mtu_values=re.findall(
                    r"(?im)^\s*(?:IP\s+)?MTU\s+(?:is\s+)?(\d+)\s+bytes",
                    text)
                mtu_actual="1400" if "1400" in mtu_values else (
                    mtu_values[-1] if mtu_values else "<не найдено>")
                # IOS usually omits the configured MSS adjustment from
                # operational interface output.  The command map therefore
                # collects only this line from the interface configuration.
                mss_match=re.search(
                    r"(?:ip tcp adjust-mss|TCP MSS "
                    r"(?:adjust(?:ment)?|adjust-mss)(?: is|:)?)\s*(\d+)",
                    text,
                    re.I)
                mss_actual=mss_match.group(1) if mss_match else "<не найдено>"
                mtu=mtu_actual=="1400"
                mss=mss_actual=="1360"
                tests.extend([mtu,mss])
                labels.extend([
                    f"{dev} Tunnel200 IP MTU: ожидалось 1400; получено {mtu_actual}",
                    f"{dev} Tunnel200 TCP MSS: ожидалось 1360; получено {mss_actual}"])
                continue
            elif aid in {"B9","C9"}:
                ok=sum(1 for spoke in SPOKES if NBMA[spoke] in text)>=3
            elif aid in {"B10","C10"}:
                ok=self.has(text,r"\bUP\b|registered|complete") and self.has(text,r"Tunnel(?:100|200).*up")
            elif aid=="D1":
                ok=all(self.has(text,p) for p in [r"AES.*256",r"SHA256|SHA-256",r"PRF.*SHA256|PRF.*SHA-256",r"group\s+14"])
            elif aid=="D2":
                ok=self.has(text,r"Proposal") and self.has(text,r"Active|Match")
            elif aid=="D4":
                ok=self.has(text,r"pre-share|PSK") and self.has(text,r"IPv4")
            elif aid=="D5":
                encryption_ok=self.has(
                    text,
                    r"esp-aes(?:\s+|-)256|esp-256-aes|AES-CBC-256"
                )
                integrity_ok=self.has(
                    text,
                    r"esp-sha256-hmac|esp-sha-?256|SHA-256"
                )
                transport_ok=self.has(
                    text,
                    r"mode\s+transport|transport\s+mode|\{\s*Transport"
                )
                ok=encryption_ok and integrity_ok and transport_ok
            elif aid=="D6":
                ok="C4-IPSEC" in text
            elif aid in {"D7","D9","D10"}:
                target = NBMA["IR1"] if aid=="D9" else NBMA["IR2"] if aid=="D10" else ""
                ok=self.has(text,r"UP-ACTIVE|READY|ACTIVE") and (not target or target in text)
            elif aid=="D8":
                ok=text.count("tunnel protection ipsec profile C4-IPSEC shared")>=2
            elif aid=="E1":
                ok=self.has(text,r'C4-OVERLAY') and self.has(text,r'AS\s*\(?4040\)?|eigrp\s+4040')
            elif aid=="E2":
                ok=LOOPBACKS[dev] in text and self.has(text,r"Router-ID|Router ID")
            elif aid=="E3":
                # `show ip protocols` does not reliably print named-mode
                # `af-interface default / passive-interface`.  The read-only
                # operational equivalent is the EIGRP interface table: it
                # contains only interfaces on which EIGRP is non-passive.
                active=set()
                for match in re.finditer(
                    r"(?m)^\s*([A-Za-z][A-Za-z0-9./-]*)\s+"
                    r"\d+\s+\d+/\d+\s+\d+/\d+",
                    text
                ):
                    interface=match.group(1)
                    normalized={
                        "tu100":"Tunnel100",
                        "tunnel100":"Tunnel100",
                        "tu200":"Tunnel200",
                        "tunnel200":"Tunnel200",
                    }.get(interface.lower(),interface)
                    active.add(normalized)
                expected=(
                    {"Tunnel100"} if dev=="IR1" else
                    {"Tunnel200"} if dev=="IR2" else
                    {"Tunnel100","Tunnel200"}
                )
                process_ok=(
                    self.has(text,r"EIGRP-IPv4.*AS\s*\(?4040\)?") or
                    self.has(text,r'Routing Protocol is "eigrp 4040"')
                )
                ok=process_ok and active==expected
                actual=", ".join(sorted(active)) if active else "<none>"
                wanted=", ".join(sorted(expected))
                label=f"{dev}: active EIGRP interfaces={actual}; expected={wanted}"
            elif aid in {"E4","E5"}:
                needed=3 if dev in HUBS else 1
                ok=len(re.findall(r"(?m)^\s*\d+\s+\S+\s+\d+\s+\S+",text))>=needed or text.upper().count("TUNNEL")>=needed
            elif aid=="E9":
                ok=self.has(text,r"BW\s+10000 Kbit") and self.has(text,r"DLY\s+(?:10000|100000)\s+usec")
            elif aid=="E10":
                ok=self.has(text,r"Hello.*5") and self.has(text,r"Hold.*15|H\s+\d+")
            elif aid=="E11":
                ok=self.has(text,r"external\s+105") and self.has(text,r"D EX")
            elif aid in {"E12","E13"}:
                prefix="10.102.0.0/16" if aid=="E12" else "10.103.0.0/16"
                ok=prefix in text
            elif aid=="F1":
                ok=self.has(text,r"C4-REALTIME") and self.has(text,r"\bef\b|46") and self.has(text,r"C4-BUSINESS") and self.has(text,r"af31|26")
            elif aid=="F2":
                ok=self.has(
                    text,
                    r"priority(?:\s+percent|\s*:)?\s*15\s*(?:\(%\)|%|\b)"
                )
            elif aid=="F3":
                ok=self.has(
                    text,
                    r"bandwidth(?:\s+percent|\s*:)?\s*30\s*(?:\(%\)|%|\b)"
                )
            elif aid=="F4": ok=self.has(text,r"class-default") and self.has(text,r"fair-queue")
            elif aid=="F5": ok=self.has(text,r"qos pre-classify")
            elif aid=="F6":
                ok=(self.has(
                        text,
                        r"(?:shape\s*(?:\(\s*)?average(?:\s*\))?"
                        r"(?:\s+cir)?\s+5000000"
                        r"|cir\s+5000000(?:\s*\(bps\))?)")
                    and "C4-WAN-QOS" in text)
            elif aid=="F7": ok="C4-WAN-PARENT" in text
            elif aid in {"G1","G2","G3"}:
                number={"G1":"401","G2":"402","G3":"403"}[aid]
                ok=number in text and "172.20.100.1" in text and self.has(text,r"Frequency.*5") and self.has(text,r"Timeout.*1000")
            elif aid=="G4":
                number={"IR3":"401","BR1":"402","BR2":"403"}[dev]
                ok=number in text and self.has(text,r"IP SLA|reachability")
            elif aid=="G5": ok=self.has(text,r"Latest.*OK|State is Up|Reachability is Up")
            elif aid in {"H1","H2"}: ok=self.has(text,r"Total active translations|Pro|Inside global")
            elif aid=="H4": ok="198.51.100.121" in text and "10.101.130.10" in text
            elif aid=="H6": ok=self.has(text,r"synchronized|Clock is synchronized|\*")
            tests.append(ok); labels.append(label)
        return tests,labels

    def check(self, aid):
        if aid=="G5":
            tests=[]
            labels=[]
            for dev,number in (("IR3","401"),("BR1","402"),("BR2","403")):
                sla=self.cmd(
                    dev,f"show ip sla statistics {number}",refresh=True)
                track=self.cmd(dev,f"show track {number}",refresh=True)
                sla_ok=self.has(
                    sla,
                    r"Latest (?:operation )?return code\s*:\s*OK\b")
                track_ok=self.has(
                    track,
                    r"(?m)^\s*(?:State\s+is|State\s*:|Reachability\s+is)"
                    r"\s*Up\b")
                tests.append(sla_ok and track_ok)
                labels.append(
                    f"{dev}: IP SLA {number} latest return code="
                    f"{'OK' if sla_ok else 'NOT OK/MISSING'}; "
                    f"Track {number}={'Up' if track_ok else 'Down/MISSING'}")
            return self.ratio(
                aid,tests,
                "Каждое устройство оценивается отдельно: успешный latest "
                "return code соответствующей IP SLA operation и состояние "
                "связанного track Up.",
                labels)

        if aid=="A3":
            tests=[]
            labels=[]
            for dev in EDGES:
                peer=ISP_PEERS[dev]
                summary=self.cmd(
                    dev,"show bgp ipv4 unicast summary",refresh=True)
                default=self.cmd(
                    dev,"show ip route 0.0.0.0",refresh=True)

                peer_line=""
                for line in summary.splitlines():
                    if re.match(rf"^\s*{re.escape(peer)}\s+",line):
                        peer_line=line.strip()
                        break
                fields=peer_line.split()
                remote_as_ok=(len(fields)>=3 and fields[2]=="65000")
                established=(len(fields)>=10 and fields[-1].isdigit())
                default_bgp=bool(re.search(
                    r'Routing entry for 0\.0\.0\.0/0.*?'
                    r'Known via\s+"bgp\s+\d+".*?'
                    rf'(?:Last update from|\*)\s+{re.escape(peer)}\b',
                    default,re.I|re.S))
                passed=remote_as_ok and established and default_bgp
                tests.append(passed)
                state=(f"Established, PfxRcd={fields[-1]}"
                       if established else
                       f"NOT Established, State={fields[-1] if fields else '<NO ROW>'}")
                labels.append(
                    f"{dev} peer {peer}: remote-AS="
                    f"{'65000' if remote_as_ok else 'WRONG/MISSING'}, "
                    f"state={state}; exact BGP default via peer="
                    f"{'PASS' if default_bgp else 'FAIL'}")
            return self.ratio(
                aid,tests,
                "В IOS в колонке State/PfxRcd число означает Established; "
                "Idle/Active/Connect означает неустановленную сессию. "
                "Для каждого edge дополнительно проверяется exact 0.0.0.0/0 "
                "как BGP route через соответствующего ISP1 peer.",
                labels)

        if aid=="B12":
            def redirect_evidence(text):
                lines=[]
                values=[]
                for line in text.splitlines():
                    if (re.search(r"redirect",line,re.I)
                            and re.search(r"\b(?:tx|sent|transmit(?:ted)?)\b",
                                          line,re.I)):
                        lines.append(line.strip())
                        values.extend(
                            int(value.replace(",",""))
                            for value in re.findall(r"\b\d[\d,]*\b",line))
                return sum(values),lines

            before_text=self.cmd(
                "IR1","show ip nhrp traffic",refresh=True)
            before_count,before_lines=redirect_evidence(before_text)

            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",10)[0]
            except Exception:
                pass
            try:
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",10)[0]
            except Exception:
                pass

            after_text=self.cmd(
                "IR1","show ip nhrp traffic",refresh=True)
            after_count,after_lines=redirect_evidence(after_text)
            br1_nhrp=self.cmd(
                "BR1","show ip nhrp 172.20.100.12 detail",refresh=True)
            br2_nhrp=self.cmd(
                "BR2","show ip nhrp 172.20.100.11 detail",refresh=True)
            br1_cef=self.cmd(
                "BR1","show ip cef 10.103.0.0/16 detail",refresh=True)
            br2_cef=self.cmd(
                "BR2","show ip cef 10.102.0.0/16 detail",refresh=True)

            br1_shortcut=(NBMA["BR2"] in br1_nhrp
                          and self.has(br1_nhrp,r"\bdynamic\b")
                          and self.has(br1_nhrp,r"Tunnel100"))
            br2_shortcut=(NBMA["BR1"] in br2_nhrp
                          and self.has(br2_nhrp,r"\bdynamic\b")
                          and self.has(br2_nhrp,r"Tunnel100"))
            cef_direct=(self.has(br1_cef,r"Tunnel100")
                        and not self.has(br1_cef,r"172\.20\.100\.1\b")
                        and self.has(br2_cef,r"Tunnel100")
                        and not self.has(br2_cef,r"172\.20\.100\.1\b"))
            redirect_growth=after_count>before_count
            accumulated_redirect=after_count>0
            redirect_ok=(redirect_growth
                         or (accumulated_redirect
                             and br1_shortcut and br2_shortcut))
            traffic=pc3_ok and pc4_ok

            redirect_lines=after_lines or before_lines
            redirect_output=(" | ".join(redirect_lines)
                             if redirect_lines else "<redirect TX line not found>")
            def compact_evidence(text,patterns):
                found=[]
                for line in text.splitlines():
                    if any(re.search(pattern,line,re.I)
                           for pattern in patterns):
                        value=line.strip()
                        if value and value not in found:
                            found.append(value)
                return " | ".join(found[:5]) or "<не найдено>"

            checks=[
                (
                    redirect_ok,
                    "IR1 сформировал NHRP redirect",
                    f"TX counter {before_count}→{after_count}; "
                    f"{redirect_output}",
                ),
                (
                    br1_shortcut,
                    "BR1 имеет dynamic NHRP mapping к BR2 через Tunnel100",
                    compact_evidence(
                        br1_nhrp,
                        [r"Tunnel100",r"\bType:",r"NBMA address"]),
                ),
                (
                    br2_shortcut,
                    "BR2 имеет dynamic NHRP mapping к BR1 через Tunnel100",
                    compact_evidence(
                        br2_nhrp,
                        [r"Tunnel100",r"\bType:",r"NBMA address"]),
                ),
                (
                    cef_direct,
                    "CEF на BR1 и BR2 использует direct spoke shortcut",
                    "BR1: "
                    + compact_evidence(br1_cef,[r"nexthop",r"Tunnel100"])
                    + "; BR2: "
                    + compact_evidence(br2_cef,[r"nexthop",r"Tunnel100"]),
                ),
                (
                    traffic,
                    "Sourced ping проходит в обоих направлениях",
                    f"BR1→BR2={'PASS' if pc3_ok else 'FAIL'}; "
                    f"BR2→BR1={'PASS' if pc4_ok else 'FAIL'}",
                ),
            ]
            print(f"\n{base.BLUE}"
                  "Подробный состав оценки B12 "
                  "(5 равных проверок по 0.050):"
                  f"{base.NC}")
            for index,(ok,title,actual) in enumerate(checks,1):
                status="PASS" if ok else "FAIL"
                color=base.GREEN if ok else base.RED
                print(f"{color}[{status}] {index}/5 — {title}{base.NC}")
                print(f"         Фактически: {actual}")

            details=(
                "Пять строк PASS/FAIL выше образуют итоговый счёт. "
                "Два направления sourced ping вместе являются одной "
                "функциональной проверкой. Слово complete в выводе IOS не "
                "требуется: dynamic mapping подтверждается типом, правильным "
                "NBMA и Tunnel100."
            )
            return self.ratio(
                aid,
                [ok for ok,_,_ in checks],
                details,
                [
                    "IR1: NHRP redirect отправлялся или счётчик вырос",
                    "BR1: dynamic mapping к BR2 через Tunnel100",
                    "BR2: dynamic mapping к BR1 через Tunnel100",
                    "BR1/BR2: CEF использует direct Tunnel100 shortcut",
                    "BR1↔BR2 endpoint traffic проходит в обе стороны",
                ])

        if aid=="I7":
            before={
                "BR1":self.peer_session_counters(
                    self.cmd("BR1","show crypto session detail"),
                    NBMA["BR2"]),
                "BR2":self.peer_session_counters(
                    self.cmd("BR2","show crypto session detail"),
                    NBMA["BR1"]),
            }

            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",10)[0]
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",10)[0]
            except Exception:
                pass

            self.cache.clear()
            br1_nhrp=self.cmd("BR1","show ip nhrp 172.20.100.12 detail")
            br1_cef=self.cmd("BR1","show ip cef 10.103.0.0/16 detail")
            br1_crypto=self.cmd("BR1","show crypto session detail")
            br2_nhrp=self.cmd("BR2","show ip nhrp 172.20.100.11 detail")
            br2_cef=self.cmd("BR2","show ip cef 10.102.0.0/16 detail")
            br2_crypto=self.cmd("BR2","show crypto session detail")
            after={
                "BR1":self.peer_session_counters(br1_crypto,NBMA["BR2"]),
                "BR2":self.peer_session_counters(br2_crypto,NBMA["BR1"]),
            }

            br1_mapping=(NBMA["BR2"] in br1_nhrp
                         and self.has(br1_nhrp,r"dynamic")
                         and self.has(br1_nhrp,r"complete")
                         and self.has(br1_nhrp,r"Tunnel100"))
            br2_mapping=(NBMA["BR1"] in br2_nhrp
                         and self.has(br2_nhrp,r"dynamic")
                         and self.has(br2_nhrp,r"complete")
                         and self.has(br2_nhrp,r"Tunnel100"))
            mappings=br1_mapping and br2_mapping
            cef=(self.has(br1_cef,r"Tunnel100")
                 and self.has(br2_cef,r"Tunnel100"))
            traffic=pc3_ok and pc4_ok
            counter_growth=all(
                after[dev][0]
                and after[dev][1]>before[dev][1]
                and after[dev][2]>before[dev][2]
                for dev in ("BR1","BR2")
            )
            details=(
                f"BR1 sourced ping={'PASS' if pc3_ok else 'FAIL'}, "
                f"BR2 sourced ping={'PASS' if pc4_ok else 'FAIL'}; "
                f"recreated NHRP Cloud100: "
                f"BR1={'PASS' if br1_mapping else 'FAIL'}, "
                f"BR2={'PASS' if br2_mapping else 'FAIL'}; "
                f"CEF Tunnel100={'PASS' if cef else 'FAIL'}; "
                f"direct-SA counters BR1 "
                f"{before['BR1'][1:]}→{after['BR1'][1:]}, BR2 "
                f"{before['BR2'][1:]}→{after['BR2'][1:]} "
                f"({'PASS' if counter_growth else 'FAIL'})"
            )
            return self.ratio(
                aid,[traffic,mappings,cef,counter_growth],details,
                ["Bidirectional traffic recreates the shortcut",
                 "Dynamic complete NHRP mappings use Tunnel100",
                 "Remote-summary CEF paths use Tunnel100",
                 "Direct BR1-BR2 IPsec SA counters increase"])

        if aid=="I5":
            site_summary={
                "HQ":"10.100.0.0",
                "IR3":"10.101.0.0",
                "BR1":"10.102.0.0",
                "BR2":"10.103.0.0",
            }
            spoke_overlay={
                "IR3":"172.20.100.13",
                "BR1":"172.20.100.11",
                "BR2":"172.20.100.12",
            }
            started=time.monotonic()

            # The expert restores IR1 G0/3. The checker only observes recovery.
            control_recovered=False
            while time.monotonic()-started<=30.0:
                hub_eigrp=self.cmd(
                    "IR1","show ip eigrp neighbors",refresh=True)
                control_recovered=all(
                    self.eigrp_neighbor_on_tunnel(
                        hub_eigrp,address,"Tunnel100")
                    for address in spoke_overlay.values()
                )
                if control_recovered:
                    break
                time.sleep(1)
            recovery_elapsed=time.monotonic()-started

            tests=[]
            labels=[]
            hub_eigrp=self.cmd(
                "IR1","show ip eigrp neighbors",refresh=True)
            hub_dmvpn=self.cmd("IR1","show dmvpn",refresh=True)
            for dev,address in spoke_overlay.items():
                spoke_eigrp=self.cmd(
                    dev,"show ip eigrp neighbors",refresh=True)
                spoke_dmvpn=self.cmd(dev,"show dmvpn",refresh=True)
                hub_neighbor=self.eigrp_neighbor_on_tunnel(
                    hub_eigrp,address,"Tunnel100")
                spoke_neighbor=self.eigrp_neighbor_on_tunnel(
                    spoke_eigrp,"172.20.100.1","Tunnel100")
                hub_nhrp=any(
                    NBMA[dev] in line and re.search(r"\bUP\b",line,re.I)
                    for line in hub_dmvpn.splitlines())
                spoke_nhrp=any(
                    NBMA["IR1"] in line and re.search(r"\bUP\b",line,re.I)
                    for line in spoke_dmvpn.splitlines())
                passed=(hub_neighbor and spoke_neighbor
                        and hub_nhrp and spoke_nhrp)
                tests.append(passed)
                labels.append(
                    f"IR1↔{dev} primary control-plane: "
                    f"EIGRP={'UP' if hub_neighbor and spoke_neighbor else 'FAIL'}, "
                    f"DMVPN/NHRP={'UP' if hub_nhrp and spoke_nhrp else 'FAIL'}")

            for dev in SPOKES:
                for owner,summary in site_summary.items():
                    if owner==dev:
                        continue
                    route=self.cmd(
                        dev,
                        f"show ip route {summary} 255.255.0.0",
                        refresh=True)
                    cef=self.cmd(
                        dev,
                        f"show ip cef {summary}/16 detail",
                        refresh=True)
                    route_primary=bool(re.search(
                        r"Tunnel100|via\s+172\.20\.100\.1\b",
                        route,re.I))
                    cef_primary=bool(re.search(
                        r"Tunnel100|172\.20\.100\.1\b",
                        cef,re.I))
                    tests.append(route_primary and cef_primary)
                    labels.append(
                        f"{dev}: remote {owner} {summary}/16 — "
                        f"RIB={'Tunnel100' if route_primary else 'NOT Tunnel100'}, "
                        f"CEF={'Tunnel100' if cef_primary else 'NOT Tunnel100'}")

            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",3)[0]
            except Exception:
                pass
            try:
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",3)[0]
            except Exception:
                pass
            within_limit=(control_recovered and recovery_elapsed<=30.0)
            tests.extend([pc3_ok,pc4_ok,within_limit])
            labels.extend([
                "BR1: 10.102.10.1 → 10.103.10.1 sourced ping",
                "BR2: 10.103.10.1 → 10.102.10.1 sourced ping",
                f"Primary EIGRP control-plane recovered in "
                f"{recovery_elapsed:.1f} s (требуется ≤30.0 s)",
            ])
            return self.ratio(
                aid,tests,
                "Read-only post-restoration validation. Скрипт не выполняет "
                "no shutdown; IR1 G0/3 должен быть включён экспертом "
                "непосредственно перед запуском I5.",
                labels)

        if aid=="I4":
            peer_for={"BR1":NBMA["BR2"],"BR2":NBMA["BR1"]}
            before={
                dev:self.peer_session_counters(
                    self.cmd(dev,"show crypto session detail"),peer)
                for dev,peer in peer_for.items()
            }

            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",10)[0]
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",10)[0]
            except Exception:
                pass

            self.cache.clear()
            br1_nhrp=self.cmd("BR1","show ip nhrp 172.20.200.12 detail")
            br1_cef=self.cmd("BR1","show ip cef 10.103.0.0/16 detail")
            br1_crypto=self.cmd("BR1","show crypto session detail")
            br2_nhrp=self.cmd("BR2","show ip nhrp 172.20.200.11 detail")
            br2_cef=self.cmd("BR2","show ip cef 10.102.0.0/16 detail")
            br2_crypto=self.cmd("BR2","show crypto session detail")
            after={
                "BR1":self.peer_session_counters(br1_crypto,NBMA["BR2"]),
                "BR2":self.peer_session_counters(br2_crypto,NBMA["BR1"]),
            }

            br1_mapping=(NBMA["BR2"] in br1_nhrp
                         and self.has(br1_nhrp,r"dynamic")
                         and self.has(br1_nhrp,r"complete")
                         and self.has(br1_nhrp,r"Tunnel200"))
            br2_mapping=(NBMA["BR1"] in br2_nhrp
                         and self.has(br2_nhrp,r"dynamic")
                         and self.has(br2_nhrp,r"complete")
                         and self.has(br2_nhrp,r"Tunnel200"))
            mappings=br1_mapping and br2_mapping
            cef=(self.has(br1_cef,r"Tunnel200")
                 and self.has(br2_cef,r"Tunnel200"))
            traffic=pc3_ok and pc4_ok
            counter_growth=all(
                after[dev][0]
                and after[dev][1]>before[dev][1]
                and after[dev][2]>before[dev][2]
                for dev in ("BR1","BR2")
            )
            details=(
                f"BR1 sourced ping={'PASS' if pc3_ok else 'FAIL'}, "
                f"BR2 sourced ping={'PASS' if pc4_ok else 'FAIL'}; "
                f"NHRP Cloud200: BR1={'PASS' if br1_mapping else 'FAIL'}, "
                f"BR2={'PASS' if br2_mapping else 'FAIL'}; "
                f"CEF Tunnel200={'PASS' if cef else 'FAIL'}; "
                f"shared direct-SA counters BR1 "
                f"{before['BR1'][1:]}→{after['BR1'][1:]}, BR2 "
                f"{before['BR2'][1:]}→{after['BR2'][1:]} "
                f"({'PASS' if counter_growth else 'FAIL'})"
            )
            return self.ratio(
                aid,[traffic,mappings,cef,counter_growth],details,
                ["Bidirectional BR1↔BR2 sourced routed traffic",
                 "Direct dynamic NHRP mappings use Tunnel200",
                 "Remote-summary CEF paths use Tunnel200",
                 "Shared direct BR1-BR2 IPsec SA counters increase"])

        if aid=="D12":
            peer_for={"BR1":NBMA["BR2"],"BR2":NBMA["BR1"]}
            before={}
            for dev,peer in peer_for.items():
                before[dev]=self.peer_session_counters(
                    self.cmd(dev,"show crypto session detail"),peer)

            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",10)[0]
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",10)[0]
            except Exception:
                pass

            self.cache.clear()
            br1_nhrp=self.cmd("BR1","show ip nhrp 172.20.100.12 detail")
            br1_cef=self.cmd("BR1","show ip cef 10.103.0.0/16 detail")
            br1_crypto=self.cmd("BR1","show crypto session detail")
            br2_nhrp=self.cmd("BR2","show ip nhrp 172.20.100.11 detail")
            br2_cef=self.cmd("BR2","show ip cef 10.102.0.0/16 detail")
            br2_crypto=self.cmd("BR2","show crypto session detail")
            after={
                "BR1":self.peer_session_counters(br1_crypto,NBMA["BR2"]),
                "BR2":self.peer_session_counters(br2_crypto,NBMA["BR1"]),
            }

            br1_mapping=(NBMA["BR2"] in br1_nhrp
                         and self.has(br1_nhrp,r"dynamic")
                         and self.has(br1_nhrp,r"complete"))
            br2_mapping=(NBMA["BR1"] in br2_nhrp
                         and self.has(br2_nhrp,r"dynamic")
                         and self.has(br2_nhrp,r"complete"))
            mappings=br1_mapping and br2_mapping
            cef=(self.has(br1_cef,r"Tunnel100")
                 and self.has(br2_cef,r"Tunnel100"))
            counter_growth=all(
                after[dev][0]
                and after[dev][1]>before[dev][1]
                and after[dev][2]>before[dev][2]
                for dev in ("BR1","BR2")
            )
            details=(
                f"BR1 sourced ping={'PASS' if pc3_ok else 'FAIL'}, "
                f"BR2 sourced ping={'PASS' if pc4_ok else 'FAIL'}; "
                f"NHRP BR1/BR2={'PASS' if mappings else 'FAIL'}; "
                f"CEF Tunnel100={'PASS' if cef else 'FAIL'}; "
                f"direct-SA counters BR1 {before['BR1'][1:]}→{after['BR1'][1:]}, "
                f"BR2 {before['BR2'][1:]}→{after['BR2'][1:]} "
                f"({'PASS' if counter_growth else 'FAIL'})"
            )
            return self.ratio(
                aid,[mappings,cef,counter_growth],details,
                ["Direct dynamic NHRP mappings","CEF uses Tunnel100",
                 "Direct BR1-BR2 IPsec SA counters increase"])

        if aid=="D11":
            before={}
            after={}
            direct_peer={"BR1":NBMA["BR2"],"BR2":NBMA["BR1"]}
            for dev in ("BR1","BR2"):
                before[dev]=self.ipsec_peer_snapshot(
                    self.cmd(dev,"show crypto ipsec sa"),direct_peer[dev])

            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",5)[0]
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",5)[0]
            except Exception:
                pass

            # Clear command cache so the second show is actually executed.
            self.cache.clear()
            for dev in ("BR1","BR2"):
                after[dev]=self.ipsec_peer_snapshot(
                    self.cmd(dev,"show crypto ipsec sa"),direct_peer[dev])

            growth={}
            growth_reason={}
            for dev in ("BR1","BR2"):
                old=before[dev]
                new=after[dev]
                counters_grew=(new["encaps"]>old["encaps"]
                               and new["decaps"]>old["decaps"])
                rekeyed=(old["spis"]!=new["spis"]
                         and new["active"]
                         and new["encaps"]>0
                         and new["decaps"]>0)
                growth[dev]=(new["found"] and new["active"]
                             and (counters_grew or rekeyed))
                if counters_grew:
                    growth_reason[dev]="counters increased"
                elif rekeyed:
                    growth_reason[dev]="SA rekey/reset; new active SA has traffic"
                elif not new["found"]:
                    growth_reason[dev]="direct peer SA not found"
                elif not new["active"]:
                    growth_reason[dev]="direct peer SA is not active"
                else:
                    growth_reason[dev]="no counter growth"
            encrypted=pc3_ok and pc4_ok and all(growth.values())

            # A CLI show cannot prove that protocol 47 is absent on the wire.
            # Keep this half explicitly unconfirmed until Expert capture.
            no_clear_gre=False
            details=(
                f"BR1 sourced ping={'PASS' if pc3_ok else 'FAIL'}; "
                f"BR2 sourced ping={'PASS' if pc4_ok else 'FAIL'}; "
                f"BR1 direct peer {direct_peer['BR1']} counters "
                f"({before['BR1']['encaps']},{before['BR1']['decaps']})→"
                f"({after['BR1']['encaps']},{after['BR1']['decaps']}) "
                f"({'PASS' if growth['BR1'] else 'FAIL'}: {growth_reason['BR1']}); "
                f"BR2 direct peer {direct_peer['BR2']} counters "
                f"({before['BR2']['encaps']},{before['BR2']['decaps']})→"
                f"({after['BR2']['encaps']},{after['BR2']['decaps']}) "
                f"({'PASS' if growth['BR2'] else 'FAIL'}: {growth_reason['BR2']}); "
                "WAN capture clear GRE=REQUIRES EXPERT CONFIRMATION"
            )
            return self.ratio(
                aid,[encrypted,no_clear_gre],details,
                ["ESP counters increase","WAN capture has no clear GRE protocol 47"])

        if aid=="B15":
            # Первая половина балла: двусторонняя endpoint connectivity.
            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",3)[0]
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",3)[0]
            except Exception:
                pass
            connectivity=pc3_ok and pc4_ok

            # Вторая половина: direct dynamic NHRP и CEF через Tunnel100.
            br1_nhrp=self.cmd("BR1","show ip nhrp 172.20.100.12 detail")
            br1_cef=self.cmd("BR1","show ip cef 10.103.0.0/16 detail")
            br2_nhrp=self.cmd("BR2","show ip nhrp 172.20.100.11 detail")
            br2_cef=self.cmd("BR2","show ip cef 10.102.0.0/16 detail")
            br1_direct=(NBMA["BR2"] in br1_nhrp
                        and self.has(br1_nhrp,r"dynamic")
                        and self.has(br1_nhrp,r"complete")
                        and self.has(br1_cef,r"Tunnel100"))
            br2_direct=(NBMA["BR1"] in br2_nhrp
                        and self.has(br2_nhrp,r"dynamic")
                        and self.has(br2_nhrp,r"complete")
                        and self.has(br2_cef,r"Tunnel100"))
            shortcut=br1_direct and br2_direct
            details=(f"BR1 sourced ping={'PASS' if pc3_ok else 'FAIL'}; "
                     f"BR2 sourced ping={'PASS' if pc4_ok else 'FAIL'}; "
                     f"BR1 direct NHRP/CEF={'PASS' if br1_direct else 'FAIL'}; "
                     f"BR2 direct NHRP/CEF={'PASS' if br2_direct else 'FAIL'}")
            return self.ratio(
                aid,[connectivity,shortcut],details,
                ["BR1↔BR2 sourced routed connectivity",
                 "BR1↔BR2 direct shortcut"])

        # The expert-controlled failure/QoS/capture tests are never initiated by
        # this checker.  It collects current state and marks it for confirmation.
        if aid=="A4":
            tests=[]; labels=[]
            for source in EDGES:
                for target in EDGES:
                    if source==target:
                        continue
                    output=self.cmd(
                        source,
                        f"ping {NBMA[target]} source {WAN[source]} repeat 3"
                    )
                    tests.append(bool(re.search(
                        r"Success rate is 100 percent",
                        output,re.I)))
                    labels.append(f"{source} -> {target} ({NBMA[target]})")
            return self.ratio(
                aid,tests,
                "20 source-ping проверок: пять routers × четыре удалённых NBMA",
                labels)

        if aid=="B14":
            # Phase 3 creates the spoke-to-spoke shortcut on demand. Generate
            # ordinary endpoint traffic first; no configuration is changed.
            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",5)[0]
            except Exception:
                pass
            try:
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",5)[0]
            except Exception:
                pass
            time.sleep(2)

            br1_cef=self.cmd(
                "BR1","show ip cef 10.103.0.0/16 detail",refresh=True)
            br1_dmvpn=self.cmd("BR1","show dmvpn",refresh=True)
            br2_cef=self.cmd(
                "BR2","show ip cef 10.102.0.0/16 detail",refresh=True)
            br2_dmvpn=self.cmd("BR2","show dmvpn",refresh=True)

            # A Phase-3 shortcut must resolve the remote branch through the
            # remote spoke tunnel address and Tunnel100, not through hub .1.
            br1_cef_ok=("172.20.100.12" in br1_cef and
                        self.has(br1_cef,r"Tunnel100") and
                        not self.has(br1_cef,r"172\.20\.100\.1(?:\s|$)"))
            br2_cef_ok=("172.20.100.11" in br2_cef and
                        self.has(br2_cef,r"Tunnel100") and
                        not self.has(br2_cef,r"172\.20\.100\.1(?:\s|$)"))

            # Dynamic peer to the opposite spoke must exist in Cloud100.
            br1_peer_ok=self.dynamic_dmvpn_peer(
                br1_dmvpn,NBMA["BR2"],"172.20.100.12")
            br2_peer_ok=self.dynamic_dmvpn_peer(
                br2_dmvpn,NBMA["BR1"],"172.20.100.11")
            details=(
                f"Trigger traffic: BR1 sourced ping="
                f"{'PASS' if pc3_ok else 'FAIL'}, BR2 sourced ping="
                f"{'PASS' if pc4_ok else 'FAIL'}. "
                f"BR1 CEF direct={'PASS' if br1_cef_ok else 'FAIL'}; "
                f"BR1 dynamic peer={'PASS' if br1_peer_ok else 'FAIL'}; "
                f"BR2 CEF direct={'PASS' if br2_cef_ok else 'FAIL'}; "
                f"BR2 dynamic peer={'PASS' if br2_peer_ok else 'FAIL'}. "
                "Статическая NHS-запись к 172.20.100.1 не является "
                "dynamic spoke-to-spoke shortcut.")
            return self.ratio(
                aid,
                [br1_cef_ok,br1_peer_ok,br2_cef_ok,br2_peer_ok],
                details,
                [
                    "BR1 CEF -> BR2: next-hop 172.20.100.12/Tunnel100, не hub .1",
                    f"BR1 dynamic peer -> BR2: {NBMA['BR2']} / 172.20.100.12",
                    "BR2 CEF -> BR1: next-hop 172.20.100.11/Tunnel100, не hub .1",
                    f"BR2 dynamic peer -> BR1: {NBMA['BR1']} / 172.20.100.11",
                ])

        if aid=="D3":
            tests=[]; labels=[]
            protected_psk="Skill39@C4"
            for dev in EDGES:
                sa=self.cmd(dev,"show crypto ikev2 sa detailed")
                session=self.sessions.get(dev)
                keyring=""
                if session is not None:
                    # Intentionally bypass cmd()/record_command(): protected
                    # output must never be printed or retained as evidence.
                    raw=session.exec("show running-config | section crypto ikev2 keyring")
                    keyring=base.format_ios_output(
                        raw,"show running-config | section crypto ikev2 keyring")
                active=self.has(sa,r"\b(?:READY|ACTIVE|UP-ACTIVE)\b")
                dynamic=self.has(
                    keyring,
                    r"address\s+0\.0\.0\.0\s+0\.0\.0\.0|address\s+0\.0\.0\.0/0")
                local_key=self.has(
                    keyring,
                    rf"pre-shared-key\s+local\s+(?:0\s+)?{re.escape(protected_psk)}")
                remote_key=self.has(
                    keyring,
                    rf"pre-shared-key\s+remote\s+(?:0\s+)?{re.escape(protected_psk)}")
                tests.append(active and dynamic and local_key and remote_key)
                labels.append(
                    f"{dev}: active SA + dynamic IPv4 peer + exact protected local/remote PSK")
                # Minimise lifetime of the sensitive value in Python objects.
                raw=""; keyring=""
            return self.ratio(
                aid,tests,
                "PSK проверен в памяти; значение и keyring output намеренно не выводятся",
                labels)

        if aid in {"E4","E5"}:
            hub="IR1" if aid=="E4" else "IR2"
            tunnel="Tunnel100" if aid=="E4" else "Tunnel200"
            cloud="100" if aid=="E4" else "200"
            hub_address=f"172.20.{cloud}.1"
            spoke_addresses={"IR3":f"172.20.{cloud}.13",
                             "BR1":f"172.20.{cloud}.11",
                             "BR2":f"172.20.{cloud}.12"}
            hub_output=self.cmd(hub,"show ip eigrp neighbors")
            tests=[]; labels=[]
            for spoke,address in spoke_addresses.items():
                spoke_output=self.cmd(spoke,"show ip eigrp neighbors")
                hub_sees=self.eigrp_neighbor_on_tunnel(
                    hub_output,address,tunnel)
                spoke_sees=self.eigrp_neighbor_on_tunnel(
                    spoke_output,hub_address,tunnel)
                tests.append(hub_sees and spoke_sees)
                labels.append(
                    f"{hub}<->{spoke}: {address}/{hub_address} via {tunnel}")
            return self.ratio(
                aid,tests,
                f"Три двусторонне подтверждённые EIGRP adjacency через {tunnel}",
                labels)

        if aid=="F8":
            tests=[]; labels=[]
            for dev in EDGES:
                interface=WAN[dev]
                peer=ISP_PEERS[dev]

                def counters():
                    output=self.cmd(
                        dev,f"show policy-map interface {interface}",
                        refresh=True)
                    return (
                        self.qos_child_class_packets(output,"C4-REALTIME"),
                        self.qos_child_class_packets(output,"C4-BUSINESS"),
                        self.qos_child_class_packets(output,"class-default"))

                before=counters()
                ef_command=(
                    f"ping {peer} source {interface} dscp 46 repeat 5")
                ef_output=self.cmd(dev,ef_command,refresh=True)
                after_ef=counters()

                af31_command=(
                    f"ping {peer} source {interface} dscp 26 repeat 5")
                af31_output=self.cmd(dev,af31_command,refresh=True)
                after_af31=counters()

                default_command=(
                    f"ping {peer} source {interface} repeat 5")
                default_output=self.cmd(dev,default_command,refresh=True)
                after_default=counters()

                ef_delta=max(0,after_ef[0]-before[0])
                af31_delta=max(0,after_af31[1]-after_ef[1])
                default_delta=max(
                    0,after_default[2]-after_af31[2])
                default_to_ef=max(
                    0,after_default[0]-after_af31[0])
                default_to_af31=max(
                    0,after_default[1]-after_af31[1])
                command_outputs=(ef_output,af31_output,default_output)
                commands_valid=all(
                    "Invalid input" not in output
                    and "Incomplete command" not in output
                    and "Ambiguous command" not in output
                    and "Success rate is" in output
                    for output in command_outputs)
                tests.append(
                    commands_valid
                    and ef_delta>0
                    and af31_delta>0
                    and default_delta>0
                    and default_to_ef==0
                    and default_to_af31==0)
                labels.append(
                    f"{dev} {interface}: приращения EF=+{ef_delta}, "
                    f"AF31=+{af31_delta}, default=+{default_delta}; "
                    f"утечка DSCP0: EF=+{default_to_ef}, "
                    f"AF31=+{default_to_af31}; "
                    f"команды={'OK' if commands_valid else 'ERROR'}")
            return self.ratio(
                aid,tests,
                "Приращения counters child policy C4-WAN-QOS после "
                "sourced ping: DSCP46 -> EF, DSCP26 -> AF31, "
                "DSCP0 -> class-default; по 0,05 за WAN output",
                labels)

        if aid=="H3":
            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",5)[0]
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",5)[0]
            except Exception:
                pass
            tests=[pc3_ok and pc4_ok]
            labels=[
                f"BR1 sourced ping={'PASS' if pc3_ok else 'FAIL'}, "
                f"BR2 sourced ping={'PASS' if pc4_ok else 'FAIL'}"
            ]
            for dev in ("IR3","BR1","BR2"):
                output=self.cmd(dev,"show ip nat translations",refresh=True)
                offending=[]
                for line in output.splitlines():
                    addresses=re.findall(
                        r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])",
                        line)
                    private={
                        address for address in addresses
                        if re.fullmatch(
                            r"10\.10[0-3]\.\d{1,3}\.\d{1,3}",address)
                    }
                    if len(private)>=2:
                        offending.append(line.strip())
                passed=not offending
                tests.append(passed)
                labels.append(
                    f"{dev}: private inter-site translation "
                    f"{'не найдена' if passed else 'НАЙДЕНА: ' + offending[0]}"
                )
                self.cmd(dev,"show ip nat statistics",refresh=True)
            return self.ratio(
                aid,tests,
                "Двусторонний BR1↔BR2 sourced traffic и отсутствие NAT translation "
                "между диапазонами 10.100/16–10.103/16",
                labels)

        if aid=="H4":
            translations=self.cmd(
                "IR3","show ip nat translations",refresh=True)
            statistics=self.cmd(
                "IR3","show ip nat statistics",refresh=True)
            mapping=any(
                "198.51.100.121" in line and "10.101.130.10" in line
                for line in translations.splitlines())
            static_counter=bool(re.search(
                r"\([1-9]\d*\s+static\b|static\s+translations?\s*:\s*[1-9]\d*",
                statistics,re.I))
            nat_ok=mapping and static_counter

            endpoint_results=[]
            for pc in ("PC3","PC4"):
                output=self.cmd(
                    pc,
                    "curl -sS --max-time 5 -o /dev/null "
                    "-w HTTP_STATUS=%{http_code} "
                    "http://198.51.100.121/healthz",
                    refresh=True)
                status_match=re.search(
                    r"HTTP_STATUS=(\d{3})",output,re.I)
                status=int(status_match.group(1)) if status_match else 0
                endpoint_results.append(200<=status<400)

            return self.ratio(
                aid,[nat_ok]+endpoint_results,
                "Static NAT и два независимых HTTP GET /healthz; "
                "protected response body не выводится",
                [
                    "IR3 static 198.51.100.121 -> 10.101.130.10 "
                    f"и static counter ({'FOUND' if mapping else 'NOT FOUND'}; "
                    f"counter={'FOUND' if static_counter else 'NOT FOUND'})",
                    "PC3 HTTP /healthz status 2xx/3xx",
                    "PC4 HTTP /healthz status 2xx/3xx",
                ])

        if aid=="H5":
            tests=[]
            labels=[]
            acl_outputs={}
            interface_outputs={}

            for dev in DEVICES:
                ssh=self.cmd(dev,"show ip ssh",refresh=True)
                vty=self.cmd(
                    dev,"show running-config | section line vty",
                    refresh=True)
                acls=self.cmd(
                    dev,
                    "show access-lists | include IP access list|permit|deny",
                    refresh=True)
                acl_outputs[dev]=acls

                ssh_enabled=(
                    not self.has(ssh,r"SSH\s+(?:is\s+)?disabled")
                    and self.has(
                        ssh,
                        r"SSH\s+Enabled|SSH\s+version\s+(?:1\.99|2)"
                        r"|Version\s+2\.0"))
                acl_name=self.vty_source_acl(vty)
                block=self.acl_block(acls,acl_name) if acl_name else ""
                permit=bool(re.search(r"(?im)^\s*(?:\d+\s+)?permit\b",block))
                explicit_deny=bool(re.search(
                    r"(?im)^\s*(?:\d+\s+)?deny\b",block))
                hits=sum(int(value) for value in re.findall(
                    r"\((\d+)\s+matches?\)",block,re.I))
                ok=ssh_enabled and bool(acl_name) and permit
                tests.append(ok)
                labels.append(
                    f"{dev}: SSH={'ENABLED' if ssh_enabled else 'DISABLED/UNKNOWN'}; "
                    f"VTY inbound ACL={acl_name or '<NONE>'}; "
                    f"permit={'YES' if permit else 'NO'}; "
                    f"explicit deny={'YES' if explicit_deny else 'NO (implicit deny допустим)'}; "
                    f"matches={hits}")

            # The task's GUEST source is 10.100.40.0/24.  Locate the ACL by
            # its actual contents instead of assuming a contestant ACL name,
            # then prove that the same ACL is attached to an IP interface.
            guest_candidates=[]
            for dev,acls in acl_outputs.items():
                headers=list(re.finditer(
                    r"(?im)^(?:Standard|Extended)\s+IP\s+access\s+list\s+(\S+)\s*$",
                    acls))
                for header in headers:
                    name=header.group(1)
                    block=self.acl_block(acls,name)
                    guest_source=bool(re.search(
                        r"10\.100\.40\.(?:0\b|[0-9]{1,3}\b)",block))
                    has_permit=bool(re.search(
                        r"(?im)^\s*(?:\d+\s+)?permit\b",block))
                    has_deny=bool(re.search(
                        r"(?im)^\s*(?:\d+\s+)?deny\b",block))
                    if guest_source and has_permit and has_deny:
                        if dev not in interface_outputs:
                            interface_outputs[dev]=self.cmd(
                                dev,
                                "show ip interface | include is up|"
                                "Inbound access list|Outgoing access list",
                                refresh=True)
                        applied=bool(re.search(
                            rf"(?im)(?:Inbound|Outgoing) access list is\s+"
                            rf"{re.escape(name)}\b",
                            interface_outputs[dev]))
                        guest_candidates.append((dev,name,applied))

            guest_applied=any(item[2] for item in guest_candidates)
            tests.append(guest_applied)
            candidate_text=(
                ", ".join(
                    f"{dev}/{name} ({'APPLIED' if applied else 'NOT APPLIED'})"
                    for dev,name,applied in guest_candidates)
                or "<NONE>")
            labels.append(
                "GUEST 10.100.40.0/24 ACL содержит permit/deny и применён "
                f"к IP interface: {candidate_text}")

            return self.ratio(
                aid,tests,
                "Read-only static validation: SSH/VTY source ACL на каждом "
                "Cisco и применённый GUEST ACL. Активная acceptance matrix "
                "PC2/JUDGE использует защищённые Expert Data и не подменяется "
                "предположениями.",
                labels)

        if aid=="I1":
            # The evaluator is deliberately read-only.  An expert must first
            # shut IR1 G0/3; this block then validates the resulting state
            # instead of changing the contestant configuration itself.
            physical=self.cmd(
                "IR1","show interfaces GigabitEthernet0/3",refresh=True)
            physical_down=bool(re.search(
                r"GigabitEthernet0/3 is administratively down",
                physical,re.I))

            evidence={}
            for dev in EDGES:
                evidence[dev]={
                    "dmvpn":self.cmd(dev,"show dmvpn",refresh=True),
                    "nhrp":self.cmd(dev,"show ip nhrp",refresh=True),
                    "crypto":self.cmd(dev,"show crypto session",refresh=True),
                    "eigrp":self.cmd(
                        dev,"show ip eigrp neighbors",refresh=True),
                    "track":self.cmd(dev,"show track",refresh=True),
                }

            primary_spoke_addresses=(
                "172.20.100.11","172.20.100.12","172.20.100.13")
            ir1_primary_neighbors=any(
                self.eigrp_neighbor_on_tunnel(
                    evidence["IR1"]["eigrp"],address,"Tunnel100")
                for address in primary_spoke_addresses)
            ir1_primary_gone=(
                not ir1_primary_neighbors
                and not any(
                    any(
                        NBMA[spoke] in line
                        and re.search(r"\bUP\b",line,re.I)
                        for line in evidence["IR1"]["dmvpn"].splitlines())
                    for spoke in SPOKES))

            backup_addresses=(
                "172.20.200.11","172.20.200.12","172.20.200.13")
            ir2_backup_count=sum(
                self.eigrp_neighbor_on_tunnel(
                    evidence["IR2"]["eigrp"],address,"Tunnel200")
                for address in backup_addresses)
            ir2_backup_ok=ir2_backup_count==3

            tests=[physical_down,ir1_primary_gone,ir2_backup_ok]
            labels=[
                "IR1 G0/3 administratively down "
                f"({'YES' if physical_down else 'NO — Expert shutdown ещё не выполнен'})",
                "IR1 primary Tunnel100 не имеет EIGRP/DMVPN spoke state "
                f"({'GONE' if ir1_primary_gone else 'STILL PRESENT'})",
                f"IR2 backup Tunnel200 EIGRP neighbors: {ir2_backup_count}/3",
            ]

            for spoke in SPOKES:
                eigrp=evidence[spoke]["eigrp"]
                primary_eigrp=self.eigrp_neighbor_on_tunnel(
                    eigrp,"172.20.100.1","Tunnel100")
                backup_eigrp=self.eigrp_neighbor_on_tunnel(
                    eigrp,"172.20.200.1","Tunnel200")
                dmvpn_primary_active=any(
                    NBMA["IR1"] in line
                    and re.search(r"\bUP\b",line,re.I)
                    for line in evidence[spoke]["dmvpn"].splitlines())
                crypto_primary_active=self.peer_session_counters(
                    evidence[spoke]["crypto"],NBMA["IR1"])[0]
                primary_peer_active=(
                    dmvpn_primary_active or crypto_primary_active)
                ok=(not primary_eigrp
                    and not primary_peer_active
                    and backup_eigrp)
                tests.append(ok)
                labels.append(
                    f"{spoke}: primary Tu100 EIGRP="
                    f"{'PRESENT' if primary_eigrp else 'ABSENT'}, "
                    f"primary DMVPN/IPsec="
                    f"{'PRESENT' if primary_peer_active else 'ABSENT'}, "
                    f"backup Tu200 EIGRP="
                    f"{'PRESENT' if backup_eigrp else 'ABSENT'}")

            affected_tracks=[
                dev for dev in EDGES
                if re.search(
                    r"(?im)^\s*State is Down\b|^\s*State\s*:\s*Down\b",
                    evidence[dev]["track"])
            ]
            tracks_down=bool(affected_tracks)
            tests.append(tracks_down)
            labels.append(
                "Affected track state Down: "
                + (", ".join(affected_tracks) if affected_tracks else "<NONE>"))

            return self.ratio(
                aid,tests,
                "Post-failure read-only validation. Скрипт не выполняет "
                "shutdown/no shutdown; IR1 G0/3 должен быть отключён экспертом "
                "до запуска критерия.",
                labels)

        if aid=="I2":
            site_summary={
                "HQ":"10.100.0.0",
                "IR3":"10.101.0.0",
                "BR1":"10.102.0.0",
                "BR2":"10.103.0.0",
            }
            tests=[]
            labels=[]

            for dev in SPOKES:
                eigrp=self.cmd(
                    dev,"show ip eigrp neighbors",refresh=True)
                dmvpn=self.cmd(dev,"show dmvpn",refresh=True)
                backup_neighbor=self.eigrp_neighbor_on_tunnel(
                    eigrp,"172.20.200.1","Tunnel200")
                backup_nhrp=any(
                    NBMA["IR2"] in line and re.search(r"\bUP\b",line,re.I)
                    for line in dmvpn.splitlines())
                backup_control=backup_neighbor and backup_nhrp
                tests.append(backup_control)
                labels.append(
                    f"{dev}: backup control-plane — "
                    f"EIGRP 172.20.200.1/Tu200="
                    f"{'UP' if backup_neighbor else 'MISSING'}, "
                    f"DMVPN peer {NBMA['IR2']}="
                    f"{'UP' if backup_nhrp else 'MISSING'}")

                for owner,summary in site_summary.items():
                    if owner==dev:
                        continue
                    route=self.cmd(
                        dev,
                        f"show ip route {summary} 255.255.0.0",
                        refresh=True)
                    cef=self.cmd(
                        dev,
                        f"show ip cef {summary}/16 detail",
                        refresh=True)
                    route_backup=bool(re.search(
                        r"Tunnel200|via\s+172\.20\.200\.1\b",
                        route,re.I))
                    cef_backup=bool(re.search(
                        r"Tunnel200|172\.20\.200\.1\b",
                        cef,re.I))
                    passed=route_backup and cef_backup
                    tests.append(passed)
                    labels.append(
                        f"{dev}: remote {owner} summary {summary}/16 — "
                        f"RIB={'Tunnel200' if route_backup else 'NOT Tunnel200'}, "
                        f"CEF={'Tunnel200' if cef_backup else 'NOT Tunnel200'}")

            started=time.monotonic()
            pc3_ok=pc4_ok=False
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",3)[0]
            except Exception:
                pc3_ok=False
            try:
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",3)[0]
            except Exception:
                pc4_ok=False
            elapsed=time.monotonic()-started

            tests.extend([pc3_ok,pc4_ok,pc3_ok and pc4_ok and elapsed<=30.0])
            labels.extend([
                "BR1: 10.102.10.1 → 10.103.10.1 sourced ping",
                "BR2: 10.103.10.1 → 10.102.10.1 sourced ping",
                f"Две functional probes завершены за {elapsed:.1f} s "
                "(требуется ≤30.0 s)",
            ])

            return self.ratio(
                aid,tests,
                "Read-only post-failure validation: backup adjacency, RIB/CEF "
                "для девяти remote summaries и двусторонний endpoint traffic. "
                "Для измерения именно convergence time критерий следует запускать "
                "сразу после внешнего shutdown IR1 G0/3.",
                labels)

        if aid=="I3":
            tests=[]
            labels=[]
            for dev,number in (("IR3","401"),("BR1","402"),("BR2","403")):
                track=self.cmd(dev,f"show track {number}",refresh=True)
                sla_config=self.cmd(
                    dev,f"show ip sla configuration {number}",refresh=True)
                sla_stats=self.cmd(
                    dev,f"show ip sla statistics {number}",refresh=True)

                track_exists=bool(re.search(
                    rf"(?im)^\s*Track\s+{number}\b",track))
                state_down=bool(re.search(
                    r"(?im)^\s*(?:State is|State\s*:)\s*Down\b",track))
                correct_sla=bool(re.search(
                    rf"(?im)\bIP SLA\s+{number}\b|\bSLA\s+{number}\b",
                    track))
                correct_target=(
                    "172.20.100.1" in sla_config
                    and bool(re.search(
                        r"Tunnel100|source.*Tu(?:nnel)?100",
                        sla_config,re.I)))
                latest_failed=bool(re.search(
                    r"Timeout|No connection|Unreachable|Over threshold|failed",
                    sla_stats,re.I))

                operational=track_exists and state_down and correct_sla
                tests.extend([operational,correct_target])
                labels.extend([
                    f"{dev}: Track{number} — "
                    f"exists={'YES' if track_exists else 'NO'}, "
                    f"state={'DOWN' if state_down else 'NOT DOWN'}, "
                    f"IP SLA binding={'CORRECT' if correct_sla else 'WRONG'}",
                    f"{dev}: IP SLA {number} target/source — "
                    f"172.20.100.1 via Tunnel100="
                    f"{'YES' if correct_target else 'NO'}; "
                    f"latest failure indication="
                    f"{'YES' if latest_failed else 'NOT SHOWN'}",
                ])

            return self.ratio(
                aid,tests,
                "Read-only post-failure validation трёх operational tracks. "
                "Состояние Down и правильная SLA-привязка проверяются "
                "автоматически. Фактическое время перехода ≤15 s можно измерить "
                "только при запуске критерия одновременно с внешним отказом; "
                "скрипт сам отказ не создаёт.",
                labels)

        if aid=="I6":
            tests=[]
            labels=[]
            for dev,number in (("IR3","401"),("BR1","402"),("BR2","403")):
                track=self.cmd(dev,f"show track {number}",refresh=True)
                sla_config=self.cmd(
                    dev,f"show ip sla configuration {number}",refresh=True)
                sla_stats=self.cmd(
                    dev,f"show ip sla statistics {number}",refresh=True)
                track_exists=bool(re.search(
                    rf"(?im)^\s*Track\s+{number}\b",track))
                state_up=bool(re.search(
                    r"(?im)^\s*(?:State is|State\s*:)\s*Up\b",track))
                correct_sla=bool(re.search(
                    rf"(?im)\bIP SLA\s+{number}\b|\bSLA\s+{number}\b",
                    track))
                correct_target=(
                    "172.20.100.1" in sla_config
                    and bool(re.search(
                        r"Tunnel100|source.*Tu(?:nnel)?100",
                        sla_config,re.I)))
                latest_success=bool(re.search(
                    r"Latest operation return code\s*:\s*OK|"
                    r"Return code\s*:\s*OK|Success|completed successfully",
                    sla_stats,re.I))
                operational=track_exists and state_up and correct_sla
                response=correct_target and latest_success
                tests.extend([operational,response])
                labels.extend([
                    f"{dev}: Track{number} — "
                    f"exists={'YES' if track_exists else 'NO'}, "
                    f"state={'UP' if state_up else 'NOT UP'}, "
                    f"IP SLA binding={'CORRECT' if correct_sla else 'WRONG'}",
                    f"{dev}: IP SLA {number} recovered response — "
                    f"172.20.100.1 via Tunnel100="
                    f"{'YES' if correct_target else 'NO'}, "
                    f"latest result={'SUCCESS' if latest_success else 'NOT SUCCESS'}",
                ])
            return self.ratio(
                aid,tests,
                "Read-only post-recovery validation трёх operational tracks. "
                "Состояние Up и успешный SLA response проверяются автоматически. "
                "Фактическое восстановление ≤15 s измеримо только при запуске "
                "критерия одновременно с внешним восстановлением IR1; скрипт "
                "сам интерфейс не включает.",
                labels)

        if aid=="I8":
            # Read-only snapshot. The checker never issues shutdown/no shutdown;
            # those actions remain external to the grading script.
            br1_t100=self.cmd("BR1","show interfaces Tunnel100",refresh=True)
            br1_route_ir3=self.cmd(
                "BR1","show ip route 10.101.0.0 255.255.0.0",refresh=True)
            br1_cef_ir3=self.cmd(
                "BR1","show ip cef 10.101.0.0/16 detail",refresh=True)
            br1_route_br2=self.cmd(
                "BR1","show ip route 10.103.0.0 255.255.0.0",refresh=True)
            br1_cef_br2=self.cmd(
                "BR1","show ip cef 10.103.0.0/16 detail",refresh=True)
            ir3_neighbors=self.cmd("IR3","show ip eigrp neighbors",refresh=True)
            ir3_cef_br2=self.cmd(
                "IR3","show ip cef 10.103.0.0/16 detail",refresh=True)
            br2_neighbors=self.cmd("BR2","show ip eigrp neighbors",refresh=True)
            br2_cef_ir3=self.cmd(
                "BR2","show ip cef 10.101.0.0/16 detail",refresh=True)

            br1_t100_down=bool(re.search(
                r"Tunnel100\s+is\s+administratively\s+down|"
                r"Tunnel100\s+is\s+down,\s+line protocol is down",
                br1_t100,re.I))
            br1_t100_up=bool(re.search(
                r"Tunnel100\s+is\s+up,\s+line protocol is up",
                br1_t100,re.I))

            def route_uses_backup(route_text:str,cef_text:str)->bool:
                return bool(re.search(
                    r"(?:Tunnel200|172\.20\.200\.1)",
                    route_text+"\n"+cef_text,re.I))

            def stays_primary(neighbors:str,cef_text:str)->bool:
                return (self.eigrp_neighbor_on_tunnel(
                            neighbors,"172.20.100.1","Tunnel100")
                        and bool(re.search(
                            r"(?:Tunnel100|172\.20\.100\.1)",cef_text,re.I)))

            br1_to_ir3_backup=route_uses_backup(br1_route_ir3,br1_cef_ir3)
            br1_to_br2_backup=route_uses_backup(br1_route_br2,br1_cef_br2)
            ir3_primary=stays_primary(ir3_neighbors,ir3_cef_br2)
            br2_primary=stays_primary(br2_neighbors,br2_cef_ir3)
            try:
                pc3_ok=self.ios_sourced_ping(
                    "BR1","10.103.10.1","10.102.10.1",3)[0]
            except Exception:
                pc3_ok=False
            try:
                pc4_ok=self.ios_sourced_ping(
                    "BR2","10.102.10.1","10.103.10.1",3)[0]
            except Exception:
                pc4_ok=False

            properties=[
                ("BR1","Tunnel100 находится Down после внешнего shutdown",
                 br1_t100_down),
                ("BR1","сеть IR3 10.101.0.0/16 используется через Tunnel200",
                 br1_to_ir3_backup),
                ("BR1","сеть BR2 10.103.0.0/16 используется через Tunnel200",
                 br1_to_br2_backup),
                ("IR3","primary EIGRP/CEF остаётся через Tunnel100",
                 ir3_primary),
                ("BR2","primary EIGRP/CEF остаётся через Tunnel100",
                 br2_primary),
                ("BR1","ping source 10.102.10.1 до 10.103.10.1 успешен",
                 pc3_ok),
                ("BR2","ping source 10.103.10.1 до 10.102.10.1 успешен",
                 pc4_ok),
            ]
            tests=[passed for _,_,passed in properties]
            labels=[device for device,_,_ in properties]

            print(f"\n{base.BLUE}Текущая фаза I8:{base.NC} "
                  f"{'FAILURE (BR1 Tunnel100 Down)' if br1_t100_down else ('RECOVERED/NORMAL (BR1 Tunnel100 Up)' if br1_t100_up else 'UNKNOWN')}")
            print(f"{base.BLUE}Результаты по отдельным свойствам I8:{base.NC}")
            for device,description,passed in properties:
                color=base.GREEN if passed else base.RED
                status="PASS" if passed else "FAIL"
                print(f"{color}[{status}] {device}: {description}{base.NC}")

            if not br1_t100_down:
                print(f"{base.YELLOW}[INFO] I8 оценивает состояние во время "
                      "внешнего shutdown BR1 Tunnel100. Сейчас Tunnel100 "
                      f"{'Up' if br1_t100_up else 'не распознан как Down'}; "
                      "скрипт намеренно не изменяет конфигурацию.{base.NC}")
            return self.ratio(
                aid,tests,
                "Оценена read-only фаза отказа: только BR1 должен перейти "
                "на Tunnel200, IR3/BR2 остаются в primary cloud, endpoint "
                "traffic сохраняется. После внешнего no shutdown повторно "
                "запустите I6/I8 для подтверждения возврата BR1 на Tunnel100; "
                "скрипт сам интерфейс не переключает.",
                labels)

        if aid=="H8":
            tests=[]
            labels=[]

            # DNS acceptance is deliberately independent from NAT/ACL tests:
            # every listed endpoint must resolve the task-defined service name
            # to its specified address.
            for dev in ("IR1","BR1","BR2"):
                try:
                    ok,output=self.ios_sourced_ping(
                        dev,"ops.c4.skill39.local",LOOPBACKS[dev],2)
                    resolved="10.101.130.10" in output
                    passed=ok and resolved
                except Exception:
                    passed=False
                tests.append(passed)
                labels.append(
                    f"{dev} source {LOOPBACKS[dev]}: "
                    "ops.c4.skill39.local → 10.101.130.10")

            try:
                pc1_svr1=self.ios_sourced_ping(
                    "IR1","10.101.130.10",LOOPBACKS["IR1"],3)[0]
            except Exception:
                pc1_svr1=False
            tests.append(pc1_svr1)
            labels.append(
                f"IR1 source {LOOPBACKS['IR1']} → SVR1 10.101.130.10")

            for device,address in LOOPBACKS.items():
                try:
                    reachable=self.ios_sourced_ping(
                        "IR3",address,LOOPBACKS["IR3"],3)[0]
                except Exception:
                    reachable=False
                tests.append(reachable)
                labels.append(
                    f"IR3 source {LOOPBACKS['IR3']} → "
                    f"{device} Loopback0 {address}")

            return self.ratio(
                aid,tests,
                "3 DNS tests с IR1/BR1/BR2 + IR1→SVR1 + "
                "IR3→11 Cisco Loopback0; "
                "балл пропорционален 15 независимым результатам",
                labels)

        if aid=="C11":
            backup_nodes=("IR2","IR3","BR1","BR2")
            tunnel200={
                "IR2":"172.20.200.1",
                "IR3":"172.20.200.13",
                "BR1":"172.20.200.11",
                "BR2":"172.20.200.12",
            }

            def snapshot():
                data={}
                for dev in backup_nodes:
                    data[dev]={}
                    for key,command in (
                        ("interface","show interfaces Tunnel200"),
                        ("dmvpn","show dmvpn"),
                        ("eigrp","show ip eigrp neighbors"),
                        ("crypto","show crypto session detail"),
                    ):
                        try:
                            data[dev][key]=self.cmd(
                                dev,command,refresh=True)
                        except Exception as exc:
                            data[dev][key]=f"[ERROR] {exc}"
                return data

            print(
                f"{base.CYAN}[C11] Сбор первого read-only снимка; затем "
                f"наблюдение стабильности backup cloud: 60 секунд..."
                f"{base.NC}",
                flush=True)
            first=snapshot()
            time.sleep(60)
            second=snapshot()

            def tunnel_up(sample,dev):
                text=sample[dev]["interface"]+"\n"+sample[dev]["dmvpn"]
                return self.has(
                    text,
                    r"Tunnel(?:1)?200\s+is\s+up(?:,|\s*/\s*)\s*"
                    r"(?:line protocol is\s+)?up")

            def registrations_up(sample):
                hub=sample["IR2"]["dmvpn"]
                return all(self.dmvpn_peer_up(
                    hub,NBMA[spoke],tunnel200[spoke])
                    for spoke in SPOKES)

            def eigrp_pair_up(sample,spoke):
                return (
                    self.eigrp_neighbor_on_tunnel(
                        sample["IR2"]["eigrp"],
                        tunnel200[spoke],"Tunnel200")
                    and self.eigrp_neighbor_on_tunnel(
                        sample[spoke]["eigrp"],
                        tunnel200["IR2"],"Tunnel200")
                )

            def ipsec_pair_up(sample,spoke):
                spoke_up=self.peer_session_counters(
                    sample[spoke]["crypto"],NBMA["IR2"])[0]
                hub_up=self.peer_session_counters(
                    sample["IR2"]["crypto"],NBMA[spoke])[0]
                return spoke_up and hub_up

            tests=[
                all(tunnel_up(sample,dev)
                    for sample in (first,second)
                    for dev in backup_nodes),
                registrations_up(first) and registrations_up(second),
            ]
            labels=[
                "Tunnel1200 (логический Tunnel200) на IR2/IR3/BR1/BR2 "
                "был up/up в начале "
                "и через 60 секунд",
                "IR2 видел три UP DMVPN/NHRP registration в обоих снимках",
            ]
            for spoke in SPOKES:
                tests.append(
                    eigrp_pair_up(first,spoke)
                    and eigrp_pair_up(second,spoke))
                labels.append(
                    f"Backup EIGRP IR2↔{spoke} по Tunnel1200 оставался Up")
            for spoke in SPOKES:
                tests.append(
                    ipsec_pair_up(first,spoke)
                    and ipsec_pair_up(second,spoke))
                labels.append(
                    f"IKEv2/IPsec IR2↔{spoke} оставался UP-ACTIVE")

            return self.ratio(
                aid,tests,
                "Два независимых read-only снимка с интервалом 60 секунд; "
                "проверены Tunnel200, три регистрации, три EIGRP adjacency "
                "и три двусторонне видимые IKEv2/IPsec session. "
                "Формирование shortcut после отказа сюда не включено: "
                "оно оценивается в I4.",
                labels)

        expert_only={"D11","F9","F10",
                     "I9","I10"}
        records=self.run_commands(aid)
        if aid=="H7":
            tests=[]
            labels=[]
            details=[]
            property_rows=[]
            for dev in EDGES:
                snmp_config,snmp_activity=self.h7_snmp_state(records[dev])
                flow_config,flow_activity=self.h7_flow_state(records[dev])
                properties=(
                    ("SNMPv3 authPriv настроен",snmp_config),
                    ("JUDGE-SRV фактически опрашивал устройство",snmp_activity),
                    ("NetFlow monitor/exporter привязан к WAN и SVR1",flow_config),
                    ("Есть успешно экспортированные flow records",flow_activity),
                )
                for description,passed in properties:
                    tests.append(passed)
                    labels.append(dev)
                    property_rows.append((dev,description,passed))
                details.append(
                    f"{dev}: SNMPv3={'OK' if snmp_config else 'FAIL'}, "
                    f"polling={'SEEN' if snmp_activity else 'NOT_SEEN'}, "
                    f"NetFlow={'OK' if flow_config else 'FAIL'}, "
                    f"exports={'SEEN' if flow_activity else 'NOT_SEEN'}")

            print(f"\n{base.BLUE}Результаты по отдельным свойствам H7:{base.NC}")
            for dev,description,passed in property_rows:
                color=base.GREEN if passed else base.RED
                status="PASS" if passed else "FAIL"
                print(f"{color}[{status}] {dev}: {description}{base.NC}")

            return self.ratio(
                aid,tests,
                "; ".join(details)+
                ". Точное получение system OID на JUDGE-SRV и UDP flow "
                "на SVR1 можно независимо подтвердить готовыми read-only "
                "командами, напечатанными выше.",
                labels)
        if aid in expert_only:
            evidence=any(v.strip() and "[ERROR]" not in v for v in records.values())
            return self.skip(aid,
                "Собраны read-only данные. Итог требует Expert Test/endpoint traffic/capture; "
                f"доступное evidence={'есть' if evidence else 'нет'}.")

        tests,labels=self.generic_state(aid,records)
        if not tests:
            return self.skip(aid,"Требуется функциональное подтверждение по указанным готовым командам.")
        if aid in {"B8","C8"}:
            print(f"\n{base.BLUE}Результаты по отдельным свойствам:{base.NC}")
            for passed,label in zip(tests,labels):
                status="PASS" if passed else "FAIL"
                color=base.GREEN if passed else base.RED
                print(f"{color}[{status}] {label}{base.NC}")
        return self.ratio(aid,tests,labels=labels)

    def ratio(self, aid, tests, details="", labels=None):
        """Оценивает подпроверки и подробно расшифровывает каждый PART."""
        values = [bool(value) for value in tests]
        source_labels = list(labels or [])
        full_labels = []
        for index in range(len(values)):
            if index < len(source_labels) and str(source_labels[index]).strip():
                full_labels.append(str(source_labels[index]).strip())
            else:
                full_labels.append(f"Подпроверка {index + 1}")

        passed = sum(values)
        total = len(values)
        if 0 < passed < total:
            breakdown = [
                "Расшифровка частичного результата:",
                *[
                    f"[{'PASS' if value else 'FAIL'}] {index + 1}/{total}: {label}"
                    for index, (value, label) in enumerate(zip(values, full_labels))
                ],
                (
                    f"Итого подтверждено: {passed}/{total}; "
                    f"не подтверждено: {total - passed}/{total}."
                ),
            ]
            breakdown_text = "\n".join(breakdown)
            details_text = "" if details is None else str(details).strip()
            details = (
                f"{details_text}\n{breakdown_text}"
                if details_text
                else breakdown_text
            )

        return super().ratio(
            aid,
            values,
            details=details,
            labels=full_labels,
        )

    def print_result(self,result):
        color={"PASS":base.GREEN,"PART":base.PURPLE,"FAIL":base.RED,"SKIP":base.YELLOW}[result.status]
        fraction=f" ({result.passed}/{result.total})" if result.total else ""
        print(f"\n{base.CYAN}Результат аспекта:{base.NC}")
        print(f"{color}[{result.status}] {result.aspect.id} {result.score:.3f}/{result.aspect.mark:.3f}"
              f"{fraction} — {result.aspect.title}{base.NC}")
        details_text = str(result.details or "").strip()
        if (
            result.status == "PART"
            and "Расшифровка частичного результата:" not in details_text
        ):
            total = int(result.total or 0)
            passed = int(result.passed or 0)
            fallback = "\n".join(
                [
                    "Расшифровка частичного результата:",
                    f"[PASS] Подтверждено подпроверок: {passed}/{total}.",
                    f"[FAIL] Не подтверждено подпроверок: {total - passed}/{total}.",
                ]
            )
            details_text = (
                f"{details_text}\n{fallback}"
                if details_text
                else fallback
            )
        if details_text:
            for line in details_text.splitlines():
                print("  " + line)

    def report(self):
        totals=defaultdict(float); maximums=defaultdict(float)
        print(f"\n{base.PURPLE}{'#'*90}\nC4 Marking Scheme Report\n{'#'*90}{base.NC}")
        for r in self.results:
            section=r.aspect.id[0]; totals[section]+=r.score; maximums[section]+=r.aspect.mark
            color={"PASS":base.GREEN,"PART":base.PURPLE,"FAIL":base.RED,"SKIP":base.YELLOW}[r.status]
            fraction=f" ({r.passed}/{r.total})" if r.total else ""
            print(f"{color}[{r.status:4}] {r.aspect.number:03d} {r.aspect.id:3} "
                  f"{r.score:.3f}/{r.aspect.mark:.3f}{fraction} — {r.aspect.title}{base.NC}")
        for section in "ABCDEFGHI":
            print(f"  {section}: {totals[section]:.3f}/{maximums[section]:.3f}")
        print(f"{base.CYAN}TOTAL: {sum(totals.values()):.3f}/{sum(maximums.values()):.3f}{base.NC}")

def start_number(value):
    value=value.upper()
    if value.isdigit() and 1<=int(value)<=100: return int(value)
    if value in BY_ID: return BY_ID[value].number
    found=next((a.number for a in ASPECTS if a.id.startswith(value)),None)
    if found:return found
    raise ValueError("Используйте A-I, ID аспекта или порядковый номер 1-100")

def arguments():
    parser=argparse.ArgumentParser(description="WSC2026 C4 PNETLab read-only IOS scorer")
    parser.add_argument("--start",default="A",help="A-I, aspect ID или 1-100")
    parser.add_argument("--session-id",type=int,help="выбрать активную сессию по ID")
    parser.add_argument(
        "--no-pause", "--continuous", "-c",
        dest="no_pause",
        action="store_true",
        help="не ожидать нажатия Enter между критериями",
    )
    return parser.parse_args()

def main():
    args=arguments(); start=start_number(args.start)
    print(f"{base.GREEN}C4 checker version: {C4_CHECKER_VERSION}{base.NC}")
    if args.no_pause:
        print(f"{base.CYAN}Режим: непрерывная проверка без пауз между критериями.{base.NC}")
    else:
        print(f"{base.CYAN}Режим: пауза с ожиданием Enter после каждого критерия.{base.NC}")
    print(f"Script: {Path(__file__).resolve()}")
    with open(HERE/"creds.json",encoding="utf-8") as file: creds=json.load(file)
    cookie=base.login(creds["pnet_url"],creds["username"],creds["password"])
    try:
        sid=c3.choose_running_session(creds["pnet_url"],cookie,args.session_id)
        base.join_session(creds["pnet_url"],sid,cookie)
        consoles=base.build_node_console_map(base.get_nodes(creds["pnet_url"],cookie).json())
        scorer=Scorer(consoles,creds,disruptive=False)
        try:
            scorer.connect()
            scorer.run(start,pause=not args.no_pause)
            scorer.report()
        finally: scorer.close()
    finally:
        try: base.logout(creds["pnet_url"])
        except Exception: pass

if __name__=="__main__":
    main()
