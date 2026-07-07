#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
c1_check_ios.py — единый scorer для Training C1 по
05_C1_CIS_Marking_Scheme_NEW.xlsx.

Скрипт:
- подключается к активной PNETLab-сессии;
- собирает show-выводы с Cisco IOS/IOSvL2 устройств;
- начисляет баллы по measurable aspects A-F;
- печатает итоговую таблицу PASS/PART/FAIL/SKIP.

Запуск:
  python c1_check_ios.py                  # с критерия A, пауза после каждого аспекта
  python c1_check_ios.py --start C        # с критерия C
  python c1_check_ios.py --start C2       # с под-критерия C2
  python c1_check_ios.py --start 23       # с aspect/row 23
  python c1_check_ios.py --no-pause       # без пауз

SKIP используется только для аспектов, которые нельзя честно подтвердить
из IOS-консолей без доступа к Linux PC/SVR или эталонного снапшота.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import ipaddress
import json
import re
import sys
from collections import defaultdict

from pnetlab_lib import login, logout, join_session, get_nodes
from checker_lib import (
    RED,
    GREEN,
    YELLOW,
    BLUE,
    PURPLE,
    CYAN,
    NC,
    build_node_console_map,
    canonical_ifname,
    format_ios_output,
    get_running_session_id_by_substring,
    IOSConsoleSession,
    tcp_exec_ios_command,
)

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")


CREDS_FILE = "creds.json"
TOPO_FILE = "topo.json"
TARGET_LAB_NAME_SUBSTR = "module-c"

DOMAIN_NAME = "camp-c1.local"
ADMIN_USER = "admin"
ADMIN_PASSWORD_HINT = "Skill39@C1"
TIMEZONE_LINE = "clock timezone ALMT 5 0"
SVR1_IP = "10.70.30.10"
SVR2_IP = "10.70.30.20"
ENTERPRISE_AS = "65100"
ISP_AS = "65000"
PUBLIC_NAT_PREFIX = "198.51.100.32/28"

MANAGED_DEVICES = [
    "IR1",
    "IR2",
    "IR3",
    "CR1",
    "CR2",
    "DS1",
    "DS2",
    "DS3",
    "DS4",
    "AS1",
    "AS2",
    "AS3",
    "AS4",
    "BR1",
    "BR2",
]

ALL_CISCO_DEVICES = ["ISP1"] + MANAGED_DEVICES

SWITCHES = ["DS1", "DS2", "DS3", "DS4", "AS1", "AS2", "AS3", "AS4"]
DIST_SWITCHES = ["DS1", "DS2", "DS3", "DS4"]
OSPF_DEVICES = ["IR1", "IR2", "IR3", "CR1", "CR2", "DS1", "DS2", "DS3", "DS4"]
EDGE_DEVICES = ["IR1", "IR2", "IR3"]
EIGRP_DEVICES = ["IR1", "IR2", "BR1", "BR2"]
NAT_DEVICES = ["IR1", "IR2", "IR3", "BR1", "BR2"]

LOOPBACK0 = {
    "IR1": "10.255.1.1",
    "IR2": "10.255.1.2",
    "IR3": "10.255.1.3",
    "CR1": "10.255.1.11",
    "CR2": "10.255.1.12",
    "DS1": "10.255.1.21",
    "DS2": "10.255.1.22",
    "DS3": "10.255.1.31",
    "DS4": "10.255.1.32",
    "BR1": "10.255.2.1",
    "BR2": "10.255.2.2",
}

VLAN_EXPECTED = {
    "DS1": {10: "HQ-STAFF", 20: "HQ-USERS", 30: "HQ-SERVICES", 50: "HQ-MGMT", 999: "NATIVE"},
    "DS2": {10: "HQ-STAFF", 20: "HQ-USERS", 30: "HQ-SERVICES", 50: "HQ-MGMT", 999: "NATIVE"},
    "AS1": {10: "HQ-STAFF", 20: "HQ-USERS", 30: "HQ-SERVICES", 50: "HQ-MGMT", 999: "NATIVE"},
    "AS2": {10: "HQ-STAFF", 20: "HQ-USERS", 30: "HQ-SERVICES", 50: "HQ-MGMT", 999: "NATIVE"},
    "DS3": {30: "DC-SERVERS", 50: "DC-MGMT", 999: "NATIVE"},
    "DS4": {30: "DC-SERVERS", 50: "DC-MGMT", 999: "NATIVE"},
    "AS3": {10: "USERS", 50: "MGMT", 999: "NATIVE"},
    "AS4": {10: "USERS", 50: "MGMT", 999: "NATIVE"},
}

HQ_TRUNK_PORTS = {
    "DS1": ["GigabitEthernet0/1", "GigabitEthernet0/2"],
    "DS2": ["GigabitEthernet0/1", "GigabitEthernet0/2"],
    "AS1": ["GigabitEthernet0/0", "GigabitEthernet0/1"],
    "AS2": ["GigabitEthernet0/0", "GigabitEthernet0/1"],
}
HQ_TRUNK_ALLOWED = {10, 20, 30, 50, 999}

DC_TRUNK_PORTS = {
    "DS3": ["GigabitEthernet0/1"],
    "DS4": ["GigabitEthernet0/1"],
}
DC_TRUNK_ALLOWED = {30, 50, 999}

BRANCH_TRUNK_SWITCH_PORTS = {
    "AS3": ["GigabitEthernet0/0"],
    "AS4": ["GigabitEthernet0/0"],
}
BRANCH_TRUNK_ALLOWED = {10, 50, 999}

ACCESS_PORTS = {
    "AS1": {"GigabitEthernet0/2": 10},
    "AS2": {"GigabitEthernet0/2": 20},
    "AS3": {"GigabitEthernet0/1": 10},
    "AS4": {"GigabitEthernet0/1": 10},
    "DS3": {"GigabitEthernet0/2": 30},
    "DS4": {"GigabitEthernet0/2": 30},
}

PC_ACCESS_PORTS = {
    "AS1": {"GigabitEthernet0/2": 10},
    "AS2": {"GigabitEthernet0/2": 20},
    "AS3": {"GigabitEthernet0/1": 10},
    "AS4": {"GigabitEthernet0/1": 10},
}

ENDPOINT_ACCESS_PORTS = {
    "AS1": ["GigabitEthernet0/2"],
    "AS2": ["GigabitEthernet0/2"],
    "AS3": ["GigabitEthernet0/1"],
    "AS4": ["GigabitEthernet0/1"],
    "DS3": ["GigabitEthernet0/2"],
    "DS4": ["GigabitEthernet0/2"],
}

ETHERCHANNEL_MEMBERS = {
    "DS1": ["GigabitEthernet1/0", "GigabitEthernet1/1"],
    "DS2": ["GigabitEthernet1/0", "GigabitEthernet1/1"],
}

HSRP_EXPECTED = {
    "DS1": {
        10: ("10.10.10.1", "Active"),
        20: ("10.10.20.1", None),
        30: ("10.10.30.1", "Active"),
        50: ("10.10.50.1", "Active"),
    },
    "DS2": {
        10: ("10.10.10.1", None),
        20: ("10.10.20.1", "Active"),
        30: ("10.10.30.1", None),
        50: ("10.10.50.1", None),
    },
    "DS3": {
        30: ("10.70.30.1", "Active"),
        50: ("10.70.50.1", "Active"),
    },
    "DS4": {
        30: ("10.70.30.1", "Standby"),
        50: ("10.70.50.1", "Standby"),
    },
}

OSPF_NEIGHBOR_IDS = {
    "IR1": {"10.255.1.2", "10.255.1.11", "10.255.1.12"},
    "IR2": {"10.255.1.1", "10.255.1.3", "10.255.1.11", "10.255.1.12"},
    "IR3": {"10.255.1.2", "10.255.1.31", "10.255.1.32"},
    "CR1": {"10.255.1.1", "10.255.1.2", "10.255.1.12", "10.255.1.21", "10.255.1.22"},
    "CR2": {"10.255.1.1", "10.255.1.2", "10.255.1.11", "10.255.1.21", "10.255.1.22"},
    "DS1": {"10.255.1.11", "10.255.1.12"},
    "DS2": {"10.255.1.11", "10.255.1.12"},
    "DS3": {"10.255.1.3"},
    "DS4": {"10.255.1.3"},
}

OSPF_AREA_INTERFACES = {
    "IR1": {
        "GigabitEthernet0/0": "0",
        "GigabitEthernet0/1": "0",
        "GigabitEthernet0/2": "0",
    },
    "IR2": {
        "GigabitEthernet0/0": "0",
        "GigabitEthernet0/1": "0",
        "GigabitEthernet0/2": "0",
        "GigabitEthernet0/4": "0",
    },
    "IR3": {
        "GigabitEthernet0/0": "70",
        "GigabitEthernet0/1": "70",
        "GigabitEthernet0/2": "0",
    },
    "CR1": {
        "GigabitEthernet0/0": "0",
        "GigabitEthernet0/1": "0",
        "GigabitEthernet0/2": "0",
        "GigabitEthernet0/3": "0",
        "GigabitEthernet0/4": "0",
    },
    "CR2": {
        "GigabitEthernet0/0": "0",
        "GigabitEthernet0/1": "0",
        "GigabitEthernet0/2": "0",
        "GigabitEthernet0/3": "0",
        "GigabitEthernet0/4": "0",
    },
    "DS1": {
        "GigabitEthernet0/0": "0",
        "GigabitEthernet0/3": "0",
        "Vlan10": "10",
        "Vlan20": "10",
        "Vlan30": "10",
        "Vlan50": "10",
    },
    "DS2": {
        "GigabitEthernet0/0": "0",
        "GigabitEthernet0/3": "0",
        "Vlan10": "10",
        "Vlan20": "10",
        "Vlan30": "10",
        "Vlan50": "10",
    },
    "DS3": {
        "GigabitEthernet0/0": "70",
        "Vlan30": "70",
        "Vlan50": "70",
    },
    "DS4": {
        "GigabitEthernet0/0": "70",
        "Vlan30": "70",
        "Vlan50": "70",
    },
}

EBGP_NEIGHBORS = {
    "IR1": "203.0.113.1",
    "IR2": "203.0.113.5",
    "IR3": "203.0.113.9",
}

IBGP_NEIGHBORS = {
    "IR1": ["10.255.1.2", "10.255.1.3"],
    "IR2": ["10.255.1.1", "10.255.1.3"],
    "IR3": ["10.255.1.1", "10.255.1.2"],
}

INTERNAL_SUMMARIES = ["10.10.0.0/16", "10.70.0.0/16", "10.21.0.0/16", "10.22.0.0/16"]
HQ_DC_SPECIFICS = [
    "10.10.10.0/24",
    "10.10.20.0/24",
    "10.10.30.0/24",
    "10.10.50.0/24",
    "10.70.30.0/24",
    "10.70.50.0/24",
]


@dataclass(frozen=True)
class Aspect:
    row: int
    criterion: str
    max_mark: float
    title: str


@dataclass
class Result:
    aspect: Aspect
    status: str
    score: float
    details: str
    raw_details: str = ""
    passed: int | None = None
    total: int | None = None


@dataclass
class CommandRecord:
    row: int
    device: str
    command: str
    output: str
    cached: bool = False


ASPECTS = {
    1: Aspect(1, "A", 0.5, "Hostname/domain/admin/enable на всех устройствах"),
    2: Aspect(2, "A", 0.5, "SSHv2, RSA, VTY без Telnet"),
    3: Aspect(3, "A", 0.25, "Timezone ALMT UTC+5"),
    4: Aspect(4, "A", 0.75, "IPv4 addressing, Loopback0, SVI up/up"),
    5: Aspect(5, "A", 1.0, "SVR2 ping/SSH до всех Cisco"),
    6: Aspect(6, "B", 0.3, "VLAN names"),
    7: Aspect(7, "B", 0.2, "VTP CAMP-C1 transparent"),
    8: Aspect(8, "B", 0.3, "HQ trunks"),
    9: Aspect(9, "B", 0.15, "DC trunk"),
    10: Aspect(10, "B", 0.15, "Branch trunks"),
    11: Aspect(11, "B", 0.4, "Access ports"),
    12: Aspect(12, "B", 0.5, "Port-channel12 LACP trunk"),
    13: Aspect(13, "B", 0.5, "Rapid-PVST HQ roots"),
    14: Aspect(14, "B", 0.5, "DC STP root/secondary"),
    15: Aspect(15, "B", 0.6, "PortFast/BPDU Guard/port-security"),
    16: Aspect(16, "B", 0.4, "CDP endpoint off, Cisco-Cisco on"),
    17: Aspect(17, "C", 0.25, "ip routing и SVI up/up"),
    18: Aspect(18, "C", 0.75, "HQ HSRP"),
    19: Aspect(19, "C", 0.75, "DC HSRP"),
    20: Aspect(20, "C", 0.75, "OSPF process 10 neighbors/router-id"),
    21: Aspect(21, "C", 0.75, "OSPF area plan"),
    22: Aspect(22, "C", 0.25, "OSPF passive/p2p"),
    23: Aspect(23, "C", 0.75, "HQ OSPF summary 10.10.0.0/16"),
    24: Aspect(24, "C", 0.75, "DC OSPF summary 10.70.0.0/16"),
    25: Aspect(25, "D", 0.75, "eBGP IR1/IR2/IR3 to ISP1"),
    26: Aspect(26, "D", 0.75, "iBGP full-mesh via Loopback0"),
    27: Aspect(27, "D", 0.5, "Enterprise AS 65100 stable"),
    28: Aspect(28, "D", 0.5, "Default route IR1 primary / IR2 backup"),
    29: Aspect(29, "D", 0.5, "IR3 not HQ primary default"),
    30: Aspect(30, "D", 1.0, "ISP route leak prevention"),
    31: Aspect(31, "E", 0.5, "Tunnel101 IR1-BR1"),
    32: Aspect(32, "E", 0.5, "Tunnel102 IR2-BR2"),
    33: Aspect(33, "E", 0.5, "EIGRP C1-OVERLAY neighbors/stub"),
    34: Aspect(34, "E", 0.5, "Branch/HQ/DC summaries"),
    35: Aspect(35, "E", 0.5, "Branch anti-leak specifics absent"),
    36: Aspect(36, "E", 0.5, "OSPF to EIGRP tag 10010"),
    37: Aspect(37, "E", 0.5, "EIGRP to OSPF tag 10020"),
    38: Aspect(38, "E", 0.5, "Redistribution loop prevention"),
    39: Aspect(39, "F", 0.5, "DHCP relay"),
    40: Aspect(40, "F", 0.5, "PC DHCP addresses"),
    41: Aspect(41, "F", 0.4, "DNS from PC1-PC4"),
    42: Aspect(42, "F", 0.35, "NTP sync"),
    43: Aspect(43, "F", 0.25, "IR1 primary PAT 198.51.100.33"),
    44: Aspect(44, "F", 0.15, "IR2 backup PAT 198.51.100.34"),
    45: Aspect(45, "F", 0.15, "BR1/BR2 local PAT"),
    46: Aspect(46, "F", 0.25, "IR3 static NAT SVR1"),
    47: Aspect(47, "F", 0.2, "NAT exemption"),
    48: Aspect(48, "F", 0.35, "VTY ACL"),
    49: Aspect(49, "F", 0.2, "User VLAN SSH deny to SVR1/SVR2"),
    50: Aspect(50, "F", 0.2, "ACL do not break services"),
    51: Aspect(51, "F", 0.25, "Syslog"),
    52: Aspect(52, "F", 0.25, "SNMPv3"),
    53: Aspect(53, "F", 0.25, "NetFlow"),
    54: Aspect(54, "F", 0.2, "Static route restrictions"),
    55: Aspect(55, "F", 0.2, "Interfaces up/up and saved config"),
    56: Aspect(56, "F", 0.2, "Final functional checks"),
    57: Aspect(57, "F", 0.15, "ISP1/SVR1/SVR2 integrity"),
}

ASPECT_EXPECTED = {
    1: "На всех managed Cisco: hostname по схеме, ip domain-name camp-c1.local, username admin privilege 15 secret, enable secret.",
    2: "SSHv2 включен; VTY разрешает только SSH; Telnet не разрешен transport input.",
    3: "На всех managed Cisco настроена timezone ALMT UTC+5.",
    4: "Все IP из topo.json присутствуют на нужных интерфейсах, интерфейсы up/up.",
    5: "SVR2/JUDGE должен иметь ping и SSH до всех managed Cisco. IOS-only scorer помечает как SKIP.",
    6: "На switch-ах созданы VLAN с именами из VLAN-плана.",
    7: "На DS1-DS4 и AS1-AS4 VTP domain CAMP-C1, mode transparent.",
    8: "HQ trunks DS/AS в trunking, native VLAN 999, allowed VLAN 10,20,30,50,999.",
    9: "DC trunk DS3-DS4 в trunking, native VLAN 999, allowed VLAN 30,50,999.",
    10: "Branch trunk/subinterfaces переносят VLAN 10,50,999.",
    11: "Access-порты PC/SVR назначены в VLAN из физической схемы.",
    12: "Po12 между DS1/DS2 собран LACP, members bundled, trunk native 999 и allowed VLAN HQ.",
    13: "Rapid-PVST; DS1 root для VLAN 10/30/50, DS2 root для VLAN20.",
    14: "DS3 root для DC VLAN 30/50, DS4 secondary/следующий priority.",
    15: "На PC access-портах: PortFast, BPDU Guard, port-security max 2, sticky/static MAC.",
    16: "CDP выключен на endpoint-портах и виден на Cisco-Cisco линках.",
    17: "На DS1-DS4 включён ip routing; требуемые SVI up/up.",
    18: "HQ HSRP: VIP .1, group=VLAN ID, DS1 active для 10/30/50, DS2 active для 20, preempt.",
    19: "DC HSRP: VIP .1, group=VLAN ID, DS3 active, DS4 standby, preempt.",
    20: "OSPF process 10, router-id=Loopback0, все ожидаемые соседи FULL.",
    21: "OSPF area plan: HQ/transit area 0, HQ VLAN area 10, DC links/VLAN area 70.",
    22: "passive-interface default, no passive только на routed links, p2p network type на P2P.",
    23: "DS1/DS2 summary 10.10.0.0/16 в area 0, summary виден на core/edge.",
    24: "IR3 summary 10.70.0.0/16 в area 0, summary виден на HQ core/edge.",
    25: "eBGP IR1/IR2/IR3 к ISP1 Established, AS 65100/65000, timers 10/30, password.",
    26: "iBGP full-mesh IR1/IR2/IR3 через Loopback0, update-source Loopback0, next-hop-self.",
    27: "На IR1/IR2/IR3 router bgp 65100, требуемые peers Established.",
    28: "Default route распространяется в OSPF; IR1 primary, IR2 backup.",
    29: "IR3 не является preferred default gateway для HQ при доступных IR1/IR2.",
    30: "ISP1 видит только public NAT prefix 198.51.100.32/28; внутренних/WAN/tunnel leaks нет.",
    31: "Tunnel101 IR1-BR1 up/up, IP 172.16.101.1/30 и 172.16.101.2/30, ping успешен.",
    32: "Tunnel102 IR2-BR2 up/up, IP 172.16.102.1/30 и 172.16.102.2/30, ping успешен.",
    33: "EIGRP C1-OVERLAY AS100: соседства только через Tunnel101/102; BR1/BR2 stub.",
    34: "IR1/IR2 видят branch summaries; BR1/BR2 видят HQ/DC summaries.",
    35: "На BR1/BR2 есть только HQ/DC summaries, без отдельных HQ/DC /24 specifics.",
    36: "OSPF->EIGRP redistribution на IR1/IR2 через route-map с tag 10010.",
    37: "EIGRP->OSPF redistribution на IR1/IR2 через route-map с tag 10020.",
    38: "route-map предотвращает re-redistribution через match tag 10010 и 10020.",
    39: "ip helper-address 10.70.30.20 на DS1/DS2 Vlan10/20 и BR1/BR2 .10.",
    40: "PC1-PC4 получают DHCP IP/gateway/DNS по плану. IOS-only scorer помечает как SKIP.",
    41: "DNS-запросы с PC1-PC4 к SVR1 успешны. IOS-only scorer помечает как SKIP.",
    42: "Все managed Cisco синхронизированы NTP с 10.70.30.10.",
    43: "IR1 primary PAT для HQ клиентов использует 198.51.100.33.",
    44: "IR2 backup PAT для HQ клиентов использует 198.51.100.34.",
    45: "BR1/BR2 имеют local PAT overload через WAN, inside на user subinterface, outside на WAN.",
    46: "IR3 имеет static NAT 10.70.30.10 <-> 198.51.100.35.",
    47: "NAT ACL/route-map исключают internal-to-internal corporate traffic.",
    48: "VTY access-class разрешает SSH с SVR2/management, VTY ssh-only.",
    49: "PC1-PC4 не имеют SSH к SVR1/SVR2, но сервисы работают. IOS-only scorer помечает как SKIP.",
    50: "ACL не ломают HSRP/OSPF/EIGRP/DHCP/NTP/Syslog.",
    51: "Syslog на 10.70.30.10, severity warnings или строже, source-interface, timestamps.",
    52: "SNMPv3 user c1snmp authPriv, SHA/SHA-256, AES, ACL только SVR1/SVR2.",
    53: "NetFlow на IR1/IR2/IR3 export 10.70.30.10:2055, source Loopback0, flow включен.",
    54: "Нет запрещённых static routes; разрешены только BR defaults, Null0 aggregate/GRE underlay.",
    55: "Все требуемые интерфейсы, Po12 и tunnels up/up; startup-config содержит актуальный hostname.",
    56: "Финальные функциональные тесты раздела 10 проходят. IOS-only scorer помечает как SKIP.",
    57: "ISP1/SVR1/SVR2 идентичны эталонному снапшоту. Без снапшота scorer помечает как SKIP.",
}

CRITERION_START_ROW = {
    "A": 1,
    "B": 6,
    "C": 17,
    "D": 25,
    "E": 31,
    "F": 39,
}

SUBCRITERION_START_ROW = {
    "A1": 1,
    "A2": 4,
    "B1": 6,
    "B2": 12,
    "B3": 15,
    "C1": 17,
    "C2": 20,
    "C3": 23,
    "D1": 25,
    "D2": 28,
    "D3": 30,
    "E1": 31,
    "E2": 33,
    "E3": 36,
    "F1": 39,
    "F2": 41,
    "F3": 43,
    "F4": 48,
    "F5": 51,
    "F6": 54,
}


def load_json_file(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def first_line(text: str, default: str = "") -> str:
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()
    return default


def normalize_area(area: str) -> str:
    area = str(area).strip()
    if area == "0.0.0.0":
        return "0"
    return area


def mask_from_prefix(prefix_len: int) -> str:
    return str(ipaddress.IPv4Network(f"0.0.0.0/{prefix_len}").netmask)


def ip_to_wildcard(prefix: str) -> tuple[str, str]:
    net = ipaddress.ip_network(prefix, strict=False)
    wildcard = ipaddress.IPv4Address(int(net.hostmask))
    return str(net.network_address), str(wildcard)


def parse_vlan_set(text: str) -> set[int] | None:
    text = (text or "").strip().lower()
    if not text or text == "none":
        return set()
    if text in {"all", "1-4094"}:
        return None
    result: set[int] = set()
    for part in text.replace(" ", "").split(","):
        if not part:
            continue
        if "-" in part:
            start_s, end_s = part.split("-", 1)
            if start_s.isdigit() and end_s.isdigit():
                result.update(range(int(start_s), int(end_s) + 1))
        elif part.isdigit():
            result.add(int(part))
    return result


def vlan_set_contains(allowed: set[int] | None, expected: set[int]) -> bool:
    return allowed is None or expected.issubset(allowed)


def section_lines(config: str, header_regex: str) -> list[str]:
    pattern = re.compile(header_regex, re.IGNORECASE)
    lines = config.splitlines()
    out: list[str] = []
    collecting = False
    for line in lines:
        stripped = line.strip()
        if pattern.fullmatch(stripped):
            collecting = True
            out = [line]
            continue
        if collecting:
            if stripped and not line.startswith((" ", "\t")) and stripped != "!":
                break
            out.append(line)
    return out


def parse_interface_sections(config: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for line in config.splitlines():
        if line.startswith("interface "):
            current = canonical_ifname(line.split(None, 1)[1].strip())
            sections[current] = [line]
            continue
        if current is not None:
            if line.strip() and not line.startswith((" ", "\t", "!")):
                current = None
                continue
            sections[current].append(line)
    return {k: "\n".join(v) for k, v in sections.items()}


def parse_ip_interface_brief(output: str) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    for raw in output.splitlines():
        line = raw.strip()
        if not line or line.lower().startswith("interface"):
            continue
        parts = line.split()
        if len(parts) < 6:
            continue
        iface = canonical_ifname(parts[0])
        protocol = parts[-1].lower()
        status = " ".join(parts[4:-1]).lower()
        result[iface] = {"ip": parts[1], "status": status, "protocol": protocol}
    return result


def parse_vlan_brief(output: str) -> dict[int, str]:
    vlans: dict[int, str] = {}
    for raw in output.splitlines():
        line = raw.strip()
        m = re.match(r"^(\d{1,4})\s+(\S+)\s+", line)
        if m:
            vlans[int(m.group(1))] = m.group(2)
    return vlans


def parse_trunk_output(output: str) -> dict[str, dict[str, object]]:
    trunks: dict[str, dict[str, object]] = {}
    section = ""
    for raw in output.splitlines():
        line = raw.rstrip()
        if not line.strip():
            section = ""
            continue
        if "Native vlan" in line and line.lstrip().startswith("Port"):
            section = "status"
            continue
        if "Vlans allowed on trunk" in line:
            section = "allowed"
            continue
        if "Vlans allowed and active" in line or "Vlans in spanning tree" in line:
            section = "ignore"
            continue
        if line.lstrip().startswith("Port") or set(line.strip()) == {"-"}:
            continue

        parts = line.split()
        if not parts:
            continue
        iface = canonical_ifname(parts[0])
        if section == "status" and len(parts) >= 5:
            trunks.setdefault(iface, {})["status"] = parts[-2].lower()
            trunks.setdefault(iface, {})["native"] = parts[-1]
        elif section == "allowed" and len(parts) >= 2:
            trunks.setdefault(iface, {})["allowed"] = parse_vlan_set(parts[1])
    return trunks


def parse_vtp_status(output: str) -> dict[str, str]:
    data = {}
    for line in output.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip().lower()] = value.strip()
    return data


def parse_standby_brief(output: str) -> dict[int, dict[str, str]]:
    groups: dict[int, dict[str, str]] = {}
    for line in output.splitlines():
        if not line.strip() or line.lower().lstrip().startswith(("interface", "p indicates")):
            continue
        parts = line.split()
        if len(parts) < 5 or not parts[1].isdigit():
            continue
        group = int(parts[1])
        state = ""
        for token in parts:
            if token.lower() in {"active", "standby", "speak", "listen", "init"}:
                state = token.capitalize()
                break
        ips = re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", line)
        vip = ips[-1] if ips else ""
        groups[group] = {"state": state, "vip": vip}
    return groups


def parse_ospf_neighbors(output: str) -> set[str]:
    neighbors = set()
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", parts[0]) and "FULL" in parts[2].upper():
            neighbors.add(parts[0])
    return neighbors


def parse_ospf_interface_brief(output: str) -> dict[str, str]:
    areas: dict[str, str] = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4 or parts[0].lower().startswith("interface"):
            continue
        if not parts[1].isdigit():
            continue
        areas[canonical_ifname(parts[0])] = normalize_area(parts[2])
    return areas


def parse_bgp_summary(output: str) -> dict[str, dict[str, str]]:
    peers: dict[str, dict[str, str]] = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 9:
            continue
        if not re.match(r"^\d+\.\d+\.\d+\.\d+$", parts[0]):
            continue
        peers[parts[0]] = {
            "as": parts[2],
            "state": parts[-1],
            "established": str(parts[-1]).isdigit(),
        }
    return peers


def route_has_prefix(route_output: str, prefix: str) -> bool:
    net = ipaddress.ip_network(prefix, strict=False)
    patterns = [
        re.escape(f"{net.network_address}/{net.prefixlen}"),
        re.escape(f"{net.network_address}"),
    ]
    return any(re.search(p, route_output) for p in patterns)


def config_contains_ip_nat_for(config: str, ip: str) -> bool:
    return bool(re.search(rf"\b{re.escape(ip)}\b", config)) and "ip nat" in config


def ios_short_ifname(iface: str) -> str:
    canon = canonical_ifname(iface)
    mapping = {
        "GigabitEthernet": "Gi",
        "FastEthernet": "Fa",
        "TenGigabitEthernet": "Te",
        "Port-channel": "Po",
        "Tunnel": "Tu",
        "Loopback": "Lo",
        "Vlan": "Vl",
    }
    for full, short in mapping.items():
        if canon.startswith(full):
            return short + canon[len(full):]
    return canon


def ifname_include_pattern(ifaces) -> str:
    terms: list[str] = []
    for iface in ifaces:
        canon = canonical_ifname(str(iface))
        short = ios_short_ifname(canon)
        for term in (canon, short):
            if term and term not in terms:
                terms.append(term)
    return "|".join(terms)


class C1Scorer:
    def __init__(
        self,
        node_console_map: dict[str, tuple[str, int]],
        topo: dict,
        enable_password: str | None,
        device_username: str | None = None,
        device_password: str | None = None,
    ):
        self.node_console_map = node_console_map
        self.topo = topo
        self.enable_password = enable_password
        self.device_username = device_username
        self.device_password = device_password
        self.outputs: dict[str, dict[str, str]] = defaultdict(dict)
        self.results: list[Result] = []
        self.current_row: int | None = None
        self.command_log: list[CommandRecord] = []
        self.sessions: dict[str, IOSConsoleSession] = {}
        self.session_errors: dict[str, str] = {}
        self.sessions_initialized = False
        self.live_rows: set[int] = set()
        self.live_device_outcomes: dict[int, dict[str, str]] = defaultdict(dict)
        self.live_printed_record_ids: set[int] = set()

    def log_command(self, dev: str, cmd: str, output: str, cached: bool = False) -> None:
        if self.current_row is None:
            return
        self.command_log.append(
            CommandRecord(
                row=self.current_row,
                device=dev,
                command=cmd,
                output=output or "",
                cached=cached,
            )
        )

    def run(self, dev: str, cmd: str, fallback_cmd: str | None = None) -> str:
        if cmd in self.outputs[dev]:
            output = self.outputs[dev][cmd]
            self.log_command(dev, cmd, output, cached=True)
            return output
        if dev not in self.node_console_map:
            self.outputs[dev][cmd] = ""
            self.log_command(dev, cmd, "[NODE NOT FOUND]", cached=False)
            return ""
        try:
            if self.sessions_initialized:
                session = self.sessions.get(dev)
                if session is None:
                    reason = self.session_errors.get(dev, "persistent session is not open")
                    raise RuntimeError(reason)
                raw = session.exec(cmd)
            else:
                host, port = self.node_console_map[dev]
                raw = tcp_exec_ios_command(
                    host,
                    port,
                    cmd,
                    self.enable_password,
                    device_label=dev,
                    device_username=self.device_username,
                    device_password=self.device_password,
                )
            output = format_ios_output(raw, cmd)
            if fallback_cmd and "% Invalid input" in output:
                self.log_command(dev, cmd, output, cached=False)
                if self.sessions_initialized:
                    session = self.sessions.get(dev)
                    if session is None:
                        reason = self.session_errors.get(dev, "persistent session is not open")
                        raise RuntimeError(reason)
                    raw = session.exec(fallback_cmd)
                else:
                    host, port = self.node_console_map[dev]
                    raw = tcp_exec_ios_command(
                        host,
                        port,
                        fallback_cmd,
                        self.enable_password,
                        device_label=dev,
                        device_username=self.device_username,
                        device_password=self.device_password,
                    )
                output = format_ios_output(raw, fallback_cmd)
                self.outputs[dev][fallback_cmd] = output
                self.log_command(dev, fallback_cmd, output, cached=False)
            else:
                self.log_command(dev, cmd, output, cached=False)
        except Exception as exc:
            output = f"[COMMAND ERROR] {exc}"
            self.log_command(dev, cmd, output, cached=False)
        self.outputs[dev][cmd] = output
        return output

    def connect_devices(self) -> None:
        self.sessions_initialized = True
        targets = [dev for dev in ALL_CISCO_DEVICES if dev in self.node_console_map]
        print(f"{CYAN}[+] Открываю постоянные консоли к Cisco-устройствам: {len(targets)} шт.{NC}")
        for dev in targets:
            host, port = self.node_console_map[dev]
            session = IOSConsoleSession(
                host,
                port,
                self.enable_password,
                device_label=dev,
                device_username=self.device_username,
                device_password=self.device_password,
            )
            try:
                session.connect()
                self.sessions[dev] = session
            except Exception as exc:
                self.session_errors[dev] = str(exc)
                print(f"{RED}[!] {dev}: не удалось открыть постоянную консоль: {exc}{NC}")

        missing = [dev for dev in ALL_CISCO_DEVICES if dev not in self.node_console_map]
        if missing:
            print(f"{YELLOW}[!] Нет console URL для устройств: {', '.join(missing)}{NC}")

    def close_devices(self) -> None:
        if not self.sessions:
            return
        print(f"{CYAN}[+] Закрываю постоянные консоли...{NC}")
        for dev, session in list(self.sessions.items()):
            try:
                session.close()
            except Exception as exc:
                print(f"{YELLOW}[!] {dev}: ошибка закрытия консоли: {exc}{NC}")

    def config(self, dev: str) -> str:
        raise RuntimeError("Use filtered config helpers: run_config_include/run_config_section/iface_section")

    def run_config_include(self, dev: str, pattern: str) -> str:
        return self.run(dev, f"show running-config | include {pattern}")

    def run_config_section(self, dev: str, pattern: str) -> str:
        return self.run(dev, f"show running-config | section {pattern}")

    def ospf_section(self, dev: str) -> str:
        return self.run_config_section(dev, "^router ospf 10")

    def bgp_section(self, dev: str) -> str:
        return self.run_config_section(dev, f"^router bgp {ENTERPRISE_AS}")

    def eigrp_section(self, dev: str) -> str:
        return self.run_config_section(dev, "^router eigrp C1-OVERLAY")

    def route_map_filtered(self, dev: str) -> str:
        return self.run(dev, "show route-map | include route-map|match tag|set tag|10010|10020")

    def ip_route_include(self, dev: str, patterns: list[str]) -> str:
        return self.run(dev, f"show ip route | include {'|'.join(patterns)}")

    def ospf_route_include(self, dev: str, prefix: str) -> str:
        return self.run(dev, f"show ip route ospf | include {prefix}")

    def startup_config(self, dev: str) -> str:
        return self.run(dev, "show startup-config | include ^hostname")

    def ip_brief(self, dev: str, interfaces=None) -> dict[str, dict[str, str]]:
        interface_list = list(interfaces or self.topo.get("nodes", {}).get(dev, {}).get("interfaces", {}))
        if not interface_list:
            return {}
        pattern = ifname_include_pattern(interface_list)
        return parse_ip_interface_brief(self.run(dev, f"show ip interface brief | include {pattern}"))

    def vlan_brief(self, dev: str, vlans) -> dict[int, str]:
        pattern = "|".join(f"^{int(vlan)} " for vlan in vlans)
        return parse_vlan_brief(self.run(dev, f"show vlan brief | include {pattern}"))

    def trunk_output(self, dev: str, ports) -> dict[str, dict[str, object]]:
        pattern = "Port|Native vlan|Vlans allowed on trunk|" + ifname_include_pattern(ports)
        return parse_trunk_output(self.run(dev, f"show interfaces trunk | include {pattern}"))

    def port_channel_trunk(self, dev: str, channel_id: int) -> dict[str, dict[str, object]]:
        name = f"Port-channel{channel_id}"
        pattern = f"Port|Native vlan|Vlans allowed on trunk|{name}|Po{channel_id}"
        return parse_trunk_output(self.run(dev, f"show interfaces port-channel {channel_id} trunk | include {pattern}"))

    def ospf_neighbors(self, dev: str, neighbors) -> set[str]:
        pattern = "|".join(sorted(neighbors))
        return parse_ospf_neighbors(self.run(dev, f"show ip ospf neighbor | include {pattern}"))

    def ospf_interfaces(self, dev: str, interfaces) -> dict[str, str]:
        pattern = ifname_include_pattern(interfaces)
        return parse_ospf_interface_brief(self.run(dev, f"show ip ospf interface brief | include {pattern}"))

    def iface_sections(self, dev: str) -> dict[str, str]:
        interfaces = self.topo.get("nodes", {}).get(dev, {}).get("interfaces", {})
        return {canonical_ifname(iface): self.iface_section(dev, iface) for iface in interfaces}

    def iface_section(self, dev: str, iface: str) -> str:
        canon = canonical_ifname(iface)
        return self.run(
            dev,
            f"show running-config interface {canon}",
            fallback_cmd=f"show running-config | section ^interface {canon}",
        )

    def bgp_summary(self, dev: str, peers=None) -> dict[str, dict[str, str]]:
        peer_list = list(peers or [])
        if not peer_list:
            return {}
        pattern = "|".join(peer_list)
        out = self.run(
            dev,
            f"show bgp ipv4 unicast summary | include {pattern}",
            fallback_cmd=f"show ip bgp summary | include {pattern}",
        )
        return parse_bgp_summary(out)

    def format_details(self, details: list[str] | str, limit: int = 14) -> tuple[str, str]:
        if isinstance(details, list):
            items = [str(item) for item in details if str(item)]
            raw_text = "; ".join(items)
            visible = items[:limit]
            if len(items) > limit:
                visible.append(f"... ({len(items) - limit} more)")
            return "; ".join(visible), raw_text
        text = str(details or "")
        return text, text

    def partial_counts_from_live(self, row: int) -> tuple[int, int] | None:
        outcomes = self.live_device_outcomes.get(row, {})
        passed = sum(1 for status in outcomes.values() if status == "PASS")
        total = sum(1 for status in outcomes.values() if status in {"PASS", "FAIL"})
        if total:
            return passed, total
        return None

    def add(
        self,
        row: int,
        ok: bool,
        details: list[str] | str = "",
        passed: int | None = None,
        total: int | None = None,
    ) -> None:
        aspect = ASPECTS[row]
        text, raw_text = self.format_details(details)
        counts = (passed, total) if passed is not None and total is not None else self.partial_counts_from_live(row)
        count_passed = count_total = None
        status = "PASS" if ok else "FAIL"
        score = aspect.max_mark if ok else 0.0

        if counts:
            count_passed, count_total = counts
            if count_total > 0:
                if count_passed == count_total and ok:
                    status = "PASS"
                    score = aspect.max_mark
                elif 0 < count_passed < count_total:
                    status = "PART"
                    score = aspect.max_mark * (count_passed / count_total)
                    note = f"частичный балл: {count_passed}/{count_total}"
                    text = f"{text}; {note}" if text else note
                    raw_text = f"{raw_text}; {note}" if raw_text else note

        self.results.append(Result(aspect, status, score, text, raw_text, count_passed, count_total))

    def skip(self, row: int, reason: str) -> None:
        self.results.append(Result(ASPECTS[row], "SKIP", 0.0, reason, reason))

    # ---------- A ----------

    def check_1_basic_identity(self) -> None:
        bad = []
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(
                dev,
                f"^hostname|^ip domain-name|^username {ADMIN_USER}|^enable secret",
            )
            expected_hostname = re.search(rf"(?m)^hostname\s+{re.escape(dev)}\s*$", cfg)
            domain = re.search(rf"(?m)^ip domain-name\s+{re.escape(DOMAIN_NAME)}\s*$", cfg)
            user = re.search(r"(?m)^username\s+admin\s+privilege\s+15\s+secret\b", cfg)
            secret = re.search(r"(?m)^enable\s+secret\b", cfg)
            if not (expected_hostname and domain and user and secret):
                dev_bad.append(dev)
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(1, not bad, [f"missing/incorrect: {', '.join(bad)}"] if bad else "all managed devices OK")

    def check_2_ssh_vty(self) -> None:
        bad = []
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            ssh_cfg = self.run_config_include(dev, "^ip ssh version 2")
            ssh = self.run(dev, "show ip ssh")
            vty_sections = self.run_config_section(dev, "^line vty")
            ssh_v2 = "SSH Enabled - version 2.0" in ssh or re.search(r"(?m)^ip ssh version 2\b", ssh_cfg)
            vty_ssh = "transport input ssh" in vty_sections
            telnet_absent = "transport input telnet" not in vty_sections and "transport input all" not in vty_sections
            if not (ssh_v2 and vty_ssh and telnet_absent):
                dev_bad.append(dev)
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(2, not bad, [f"SSH/VTY issue: {', '.join(bad)}"] if bad else "SSHv2 and VTY ssh-only OK")

    def check_3_timezone(self) -> None:
        bad = []
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(dev, "^clock timezone")
            clock = self.run(dev, "show clock detail")
            if TIMEZONE_LINE not in cfg and "ALMT" not in clock:
                dev_bad.append(dev)
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(3, not bad, [f"timezone issue: {', '.join(bad)}"] if bad else "ALMT UTC+5 OK")

    def check_4_addressing(self) -> None:
        bad = []
        topo_nodes = self.topo.get("nodes", {})
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            if dev not in topo_nodes:
                dev_bad.append(f"{dev}: absent in topo.json")
                self.report_device_result(dev, False, dev_bad, start)
                bad.extend(dev_bad)
                continue
            expected = topo_nodes[dev].get("interfaces", {})
            brief = self.ip_brief(dev, expected)
            for iface, cidr in expected.items():
                canon = canonical_ifname(iface)
                actual = brief.get(canon)
                expected_ip = str(ipaddress.ip_interface(cidr).ip)
                if not actual:
                    dev_bad.append(f"{dev} {canon}: absent")
                    continue
                if actual["ip"] != expected_ip:
                    dev_bad.append(f"{dev} {canon}: {actual['ip']} != {expected_ip}")
                    continue
                if actual["status"] != "up" or actual["protocol"] != "up":
                    dev_bad.append(f"{dev} {canon}: {actual['status']}/{actual['protocol']}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(4, not bad, bad)

    def check_5_management_reachability(self) -> None:
        self.skip(5, "Требуется функциональный ping/SSH именно с Linux SVR2/JUDGE; IOS-консоли этого не подтверждают.")

    # ---------- B ----------

    def check_6_vlans(self) -> None:
        bad = []
        for dev, expected in VLAN_EXPECTED.items():
            start = self.live_device_start()
            dev_bad = []
            actual = self.vlan_brief(dev, expected)
            for vlan, name in expected.items():
                if actual.get(vlan, "").upper() != name.upper():
                    dev_bad.append(f"{dev} VLAN{vlan}: {actual.get(vlan, '-')}, expected {name}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(6, not bad, bad)

    def check_7_vtp(self) -> None:
        bad = []
        for dev in SWITCHES:
            start = self.live_device_start()
            dev_bad = []
            status = parse_vtp_status(self.run(dev, "show vtp status"))
            mode = status.get("vtp operating mode", "")
            domain = status.get("vtp domain name", "")
            if mode.lower() != "transparent" or domain.upper() != "CAMP-C1":
                dev_bad.append(f"{dev}: mode={mode or '-'}, domain={domain or '-'}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(7, not bad, bad)

    def _check_trunk_ports(self, dev_ports: dict[str, list[str]], expected_vlans: set[int]) -> list[str]:
        bad = []
        for dev, ports in dev_ports.items():
            start = self.live_device_start()
            dev_bad = []
            trunks = self.trunk_output(dev, ports)
            for port in ports:
                data = trunks.get(canonical_ifname(port), {})
                if data.get("status") != "trunking":
                    dev_bad.append(f"{dev} {port}: not trunking")
                    continue
                if str(data.get("native", "")) != "999":
                    dev_bad.append(f"{dev} {port}: native {data.get('native', '-')}")
                if not vlan_set_contains(data.get("allowed"), expected_vlans):
                    dev_bad.append(f"{dev} {port}: allowed {data.get('allowed', '-')}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        return bad

    def check_8_hq_trunks(self) -> None:
        bad = self._check_trunk_ports(HQ_TRUNK_PORTS, HQ_TRUNK_ALLOWED)
        self.add(8, not bad, bad)

    def check_9_dc_trunk(self) -> None:
        bad = self._check_trunk_ports(DC_TRUNK_PORTS, DC_TRUNK_ALLOWED)
        self.add(9, not bad, bad)

    def check_10_branch_trunks(self) -> None:
        bad = self._check_trunk_ports(BRANCH_TRUNK_SWITCH_PORTS, BRANCH_TRUNK_ALLOWED)
        for dev, tunnel_iface in {"BR1": "GigabitEthernet0/1", "BR2": "GigabitEthernet0/1"}.items():
            start = self.live_device_start()
            dev_bad = []
            for vlan in (10, 50):
                sec = self.iface_section(dev, f"{tunnel_iface}.{vlan}")
                if f"encapsulation dot1Q {vlan}" not in sec:
                    dev_bad.append(f"{dev} {tunnel_iface}.{vlan}: dot1Q missing")
            native_ok = "encapsulation dot1Q 999 native" in self.iface_section(dev, f"{tunnel_iface}.999")
            if not native_ok:
                dev_bad.append(f"{dev}: native VLAN 999 subinterface missing")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(10, not bad, bad)

    def check_11_access_ports(self) -> None:
        bad = []
        for dev, ports in ACCESS_PORTS.items():
            start = self.live_device_start()
            dev_bad = []
            for iface, vlan in ports.items():
                sec = self.iface_section(dev, iface)
                if "switchport mode access" not in sec or f"switchport access vlan {vlan}" not in sec:
                    dev_bad.append(f"{dev} {iface}: access VLAN {vlan} not configured")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(11, not bad, bad)

    def check_12_etherchannel(self) -> None:
        bad = []
        for dev, members in ETHERCHANNEL_MEMBERS.items():
            start = self.live_device_start()
            dev_bad = []
            lacp_cfg = self.run_config_include(dev, "channel-protocol lacp|channel-group 12 mode active")
            eth_filter = "Po12|" + ifname_include_pattern(members)
            eth = self.run(dev, f"show etherchannel summary | include {eth_filter}")
            trunks = self.port_channel_trunk(dev, 12)
            po = trunks.get("Port-channel12", {})
            if not re.search(r"\bPo12\(.?SU\)", eth):
                dev_bad.append(f"{dev}: Po12 not SU")
            for member in members:
                if re.search(rf"{re.escape(member.replace('GigabitEthernet', 'Gi'))}\(P\)", eth) is None:
                    sec = self.iface_section(dev, member)
                    if "channel-group 12 mode active" not in sec:
                        dev_bad.append(f"{dev} {member}: not bundled/LACP active")
            if po.get("status") != "trunking" or str(po.get("native", "")) != "999":
                dev_bad.append(f"{dev}: Po12 trunk/native999 issue")
            if not vlan_set_contains(po.get("allowed"), HQ_TRUNK_ALLOWED):
                dev_bad.append(f"{dev}: Po12 allowed VLAN issue")
            if "channel-protocol lacp" not in lacp_cfg and "mode active" not in lacp_cfg:
                dev_bad.append(f"{dev}: LACP active not visible")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(12, not bad, bad)

    def _stp_priorities(self, dev: str) -> dict[int, int]:
        cfg = self.run_config_include(dev, "^spanning-tree vlan")
        priorities: dict[int, int] = defaultdict(lambda: 32768)
        for line in cfg.splitlines():
            m = re.search(r"spanning-tree vlan ([0-9,\-]+) priority (\d+)", line)
            if not m:
                continue
            vlans = parse_vlan_set(m.group(1)) or set()
            for vlan in vlans:
                priorities[vlan] = int(m.group(2))
        return priorities

    def check_13_stp_hq(self) -> None:
        bad = []
        for dev in ("DS1", "DS2"):
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(dev, "^spanning-tree mode|^spanning-tree vlan")
            summary = self.run(dev, "show spanning-tree summary")
            if "rapid-pvst" not in (cfg + summary).lower():
                dev_bad.append(f"{dev}: rapid-pvst not visible")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        p1 = self._stp_priorities("DS1")
        p2 = self._stp_priorities("DS2")
        ds1_bad = []
        ds2_bad = []
        for vlan in (10, 30, 50):
            if p1[vlan] >= p2[vlan]:
                msg = f"VLAN{vlan}: DS1 priority {p1[vlan]} >= DS2 {p2[vlan]}"
                ds1_bad.append(msg)
                bad.append(msg)
        if p2[20] >= p1[20]:
            msg = f"VLAN20: DS2 priority {p2[20]} >= DS1 {p1[20]}"
            ds2_bad.append(msg)
            bad.append(msg)
        if ds1_bad:
            self.report_device_result("DS1", False, ds1_bad, self.live_device_start())
        if ds2_bad:
            self.report_device_result("DS2", False, ds2_bad, self.live_device_start())
        self.add(13, not bad, bad)

    def check_14_stp_dc(self) -> None:
        start3 = self.live_device_start()
        p3 = self._stp_priorities("DS3")
        start4 = self.live_device_start()
        p4 = self._stp_priorities("DS4")
        bad = []
        ds3_bad = []
        for vlan in (30, 50):
            if p3[vlan] >= p4[vlan]:
                msg = f"VLAN{vlan}: DS3 priority {p3[vlan]} >= DS4 {p4[vlan]}"
                ds3_bad.append(msg)
                bad.append(msg)
        self.report_device_result("DS3", not ds3_bad, ds3_bad, start3)
        self.report_device_result("DS4", True, "", start4)
        self.add(14, not bad, bad)

    def check_15_port_security(self) -> None:
        bad = []
        for dev, ports in PC_ACCESS_PORTS.items():
            start = self.live_device_start()
            dev_bad = []
            for iface in ports:
                sec = self.iface_section(dev, iface)
                if "spanning-tree portfast" not in sec:
                    dev_bad.append(f"{dev} {iface}: no portfast")
                if "spanning-tree bpduguard enable" not in sec:
                    dev_bad.append(f"{dev} {iface}: no bpduguard")
                if "switchport port-security" not in sec:
                    dev_bad.append(f"{dev} {iface}: no port-security")
                if "switchport port-security maximum 2" not in sec:
                    dev_bad.append(f"{dev} {iface}: max != 2")
                if "switchport port-security mac-address sticky" not in sec and not re.search(
                    r"switchport port-security mac-address\s+[0-9a-f.]{14}", sec, re.I
                ):
                    dev_bad.append(f"{dev} {iface}: no sticky/static secure MAC")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(15, not bad, bad)

    def check_16_cdp(self) -> None:
        bad = []
        for dev, ports in ENDPOINT_ACCESS_PORTS.items():
            start = self.live_device_start()
            dev_bad = []
            for iface in ports:
                if "no cdp enable" not in self.iface_section(dev, iface):
                    dev_bad.append(f"{dev} {iface}: CDP not disabled")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        for dev in SWITCHES:
            start = self.live_device_start()
            dev_bad = []
            neigh = self.run(dev, "show cdp neighbors | include DS|AS|CR|IR|BR")
            if not re.search(r"\b(DS|AS|CR|IR|BR)\d?\b", neigh):
                dev_bad.append(f"{dev}: no Cisco-Cisco CDP neighbors visible")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(16, not bad, bad)

    # ---------- C ----------

    def check_17_l3_routing(self) -> None:
        bad = []
        for dev in DIST_SWITCHES:
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(dev, "^ip routing")
            svi_interfaces = [iface for iface in OSPF_AREA_INTERFACES[dev] if iface.startswith("Vlan")]
            brief = self.ip_brief(dev, svi_interfaces)
            if not re.search(r"(?m)^ip routing\s*$", cfg):
                dev_bad.append(f"{dev}: no ip routing")
            for iface in OSPF_AREA_INTERFACES[dev]:
                if iface.startswith("Vlan"):
                    state = brief.get(iface)
                    if not state or state["status"] != "up" or state["protocol"] != "up":
                        dev_bad.append(f"{dev} {iface}: not up/up")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(17, not bad, bad)

    def _check_hsrp(self, row: int, devices: list[str]) -> None:
        bad = []
        for dev in devices:
            start = self.live_device_start()
            dev_bad = []
            hsrp_ifaces = [f"Vlan{group}" for group in HSRP_EXPECTED[dev]]
            brief = parse_standby_brief(
                self.run(dev, f"show standby brief | include {ifname_include_pattern(hsrp_ifaces)}")
            )
            cfg = self.run_config_include(dev, "standby")
            for group, (vip, state) in HSRP_EXPECTED[dev].items():
                data = brief.get(group)
                if not data:
                    dev_bad.append(f"{dev} group {group}: absent")
                    continue
                if data["vip"] != vip:
                    dev_bad.append(f"{dev} group {group}: VIP {data['vip']} != {vip}")
                if state and data["state"] != state:
                    dev_bad.append(f"{dev} group {group}: state {data['state']} != {state}")
                if not re.search(rf"standby\s+{group}\s+preempt\b", cfg):
                    dev_bad.append(f"{dev} group {group}: no preempt")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(row, not bad, bad)

    def check_18_hq_hsrp(self) -> None:
        self._check_hsrp(18, ["DS1", "DS2"])

    def check_19_dc_hsrp(self) -> None:
        self._check_hsrp(19, ["DS3", "DS4"])

    def check_20_ospf_basic(self) -> None:
        bad = []
        for dev in OSPF_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            ospf_sec = self.ospf_section(dev)
            if not ospf_sec:
                dev_bad.append(f"{dev}: no router ospf 10")
            rid = LOOPBACK0.get(dev)
            if rid and f"router-id {rid}" not in ospf_sec:
                dev_bad.append(f"{dev}: router-id != {rid}")
            actual = self.ospf_neighbors(dev, OSPF_NEIGHBOR_IDS[dev])
            missing = OSPF_NEIGHBOR_IDS[dev] - actual
            if missing:
                dev_bad.append(f"{dev}: missing FULL neighbors {','.join(sorted(missing))}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(20, not bad, bad)

    def check_21_ospf_area_plan(self) -> None:
        bad = []
        for dev, expected in OSPF_AREA_INTERFACES.items():
            start = self.live_device_start()
            dev_bad = []
            actual = self.ospf_interfaces(dev, expected)
            for iface, area in expected.items():
                got = actual.get(canonical_ifname(iface))
                if normalize_area(str(got)) != area:
                    dev_bad.append(f"{dev} {iface}: area {got or '-'} != {area}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(21, not bad, bad)

    def check_22_ospf_passive_p2p(self) -> None:
        bad = []
        for dev in OSPF_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            ospf_sec = self.ospf_section(dev)
            if "passive-interface default" not in ospf_sec:
                dev_bad.append(f"{dev}: no passive-interface default")
            for iface, area in OSPF_AREA_INTERFACES[dev].items():
                if iface.startswith("Vlan"):
                    continue
                if f"no passive-interface {iface}" not in ospf_sec and f"no passive-interface {iface.replace('GigabitEthernet', 'Gi')}" not in ospf_sec:
                    dev_bad.append(f"{dev} {iface}: no no-passive")
                if "ip ospf network point-to-point" not in self.iface_section(dev, iface):
                    dev_bad.append(f"{dev} {iface}: no point-to-point type")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(22, not bad, bad)

    def check_23_hq_ospf_summary(self) -> None:
        bad = []
        for dev in ("DS1", "DS2"):
            start = self.live_device_start()
            dev_bad = []
            ospf_sec = self.ospf_section(dev)
            if "area 10 range 10.10.0.0 255.255.0.0" not in ospf_sec:
                dev_bad.append(f"{dev}: no area 10 range 10.10.0.0/16")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        for dev in ("CR1", "CR2", "IR1", "IR2", "IR3"):
            start = self.live_device_start()
            dev_bad = []
            route = self.ospf_route_include(dev, "10.10.0.0")
            if not route_has_prefix(route, "10.10.0.0/16"):
                dev_bad.append(f"{dev}: 10.10.0.0/16 not in OSPF routes")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(23, not bad, bad)

    def check_24_dc_ospf_summary(self) -> None:
        start = self.live_device_start()
        ospf_sec = self.ospf_section("IR3")
        bad = []
        ir3_bad = []
        if "area 70 range 10.70.0.0 255.255.0.0" not in ospf_sec:
            ir3_bad.append("IR3: no area 70 range 10.70.0.0/16")
        self.report_device_result("IR3", not ir3_bad, ir3_bad, start)
        bad.extend(ir3_bad)
        for dev in ("CR1", "CR2", "IR1", "IR2"):
            start = self.live_device_start()
            dev_bad = []
            route = self.ospf_route_include(dev, "10.70.0.0")
            if not route_has_prefix(route, "10.70.0.0/16"):
                dev_bad.append(f"{dev}: 10.70.0.0/16 not in OSPF routes")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(24, not bad, bad)

    # ---------- D ----------

    def check_25_ebgp(self) -> None:
        bad = []
        for dev, neighbor in EBGP_NEIGHBORS.items():
            start = self.live_device_start()
            dev_bad = []
            bgp_sec = self.bgp_section(dev)
            summary = self.bgp_summary(dev, [neighbor])
            peer = summary.get(neighbor)
            if not peer or not peer["established"]:
                dev_bad.append(f"{dev}: eBGP {neighbor} not established")
            if f"neighbor {neighbor} remote-as {ISP_AS}" not in bgp_sec:
                dev_bad.append(f"{dev}: remote-as for {neighbor}")
            if f"neighbor {neighbor} timers 10 30" not in bgp_sec:
                dev_bad.append(f"{dev}: timers for {neighbor}")
            if f"neighbor {neighbor} password" not in bgp_sec:
                dev_bad.append(f"{dev}: password for {neighbor}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(25, not bad, bad)

    def check_26_ibgp(self) -> None:
        bad = []
        for dev, peers in IBGP_NEIGHBORS.items():
            start = self.live_device_start()
            dev_bad = []
            bgp_sec = self.bgp_section(dev)
            summary = self.bgp_summary(dev, peers)
            for peer_ip in peers:
                peer = summary.get(peer_ip)
                if not peer or not peer["established"]:
                    dev_bad.append(f"{dev}: iBGP {peer_ip} not established")
                if f"neighbor {peer_ip} remote-as {ENTERPRISE_AS}" not in bgp_sec:
                    dev_bad.append(f"{dev}: iBGP remote-as {peer_ip}")
                if f"neighbor {peer_ip} update-source Loopback0" not in bgp_sec:
                    dev_bad.append(f"{dev}: update-source {peer_ip}")
                if f"neighbor {peer_ip} next-hop-self" not in bgp_sec:
                    dev_bad.append(f"{dev}: next-hop-self {peer_ip}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(26, not bad, bad)

    def check_27_bgp_as_stability(self) -> None:
        bad = []
        for dev in EDGE_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            bgp_sec = self.bgp_section(dev)
            if not re.search(rf"(?m)^router bgp {ENTERPRISE_AS}\s*$", bgp_sec):
                dev_bad.append(f"{dev}: router bgp {ENTERPRISE_AS} missing")
            checked_peers = list(EBGP_NEIGHBORS.values()) + IBGP_NEIGHBORS[dev]
            for peer_ip, peer in self.bgp_summary(dev, checked_peers).items():
                if peer_ip in EBGP_NEIGHBORS.values() or peer_ip in IBGP_NEIGHBORS[dev]:
                    if not peer["established"]:
                        dev_bad.append(f"{dev}: peer {peer_ip} state {peer['state']}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(27, not bad, bad)

    def check_28_default_route_control(self) -> None:
        bad = []
        for dev in ("DS1", "DS2", "DS3", "DS4", "CR1", "CR2"):
            start = self.live_device_start()
            dev_bad = []
            route = self.run(dev, "show ip route 0.0.0.0")
            if "0.0.0.0/0" not in route and "Gateway of last resort" not in route:
                dev_bad.append(f"{dev}: no default route")
            if "ospf" not in route.lower() and "O*" not in route:
                dev_bad.append(f"{dev}: default route not OSPF-visible")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        start = self.live_device_start()
        ir1_ospf = self.ospf_section("IR1")
        ir1_bad = []
        if "default-information originate" not in ir1_ospf:
            ir1_bad.append("IR1: no OSPF default-information originate")
        self.report_device_result("IR1", not ir1_bad, ir1_bad, start)
        bad.extend(ir1_bad)

        start = self.live_device_start()
        ir2_ospf = self.ospf_section("IR2")
        ir2_bad = []
        if "default-information originate" not in ir2_ospf:
            ir2_bad.append("IR2: no OSPF default-information originate")
        self.report_device_result("IR2", not ir2_bad, ir2_bad, start)
        bad.extend(ir2_bad)
        self.add(28, not bad, bad)

    def check_29_ir3_not_default(self) -> None:
        bad = []
        start = self.live_device_start()
        ir3_bad = []
        ir3_ospf = self.ospf_section("IR3")
        if "default-information originate" in ir3_ospf and "metric" not in ir3_ospf:
            ir3_bad.append("IR3 originates default without explicit non-primary metric")
        self.report_device_result("IR3", not ir3_bad, ir3_bad, start)
        bad.extend(ir3_bad)
        for dev in ("CR1", "CR2", "DS1", "DS2"):
            start = self.live_device_start()
            dev_bad = []
            route = self.run(dev, "show ip route 0.0.0.0")
            if "10.10.0.42" in route or "10.255.1.3" in route:
                dev_bad.append(f"{dev}: default appears to prefer IR3")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(29, not bad, bad)

    def check_30_route_leak(self) -> None:
        bad = []
        start = self.live_device_start()
        isp_bad = []
        leak_pattern = "198.51.100.32|10.10.0.0|10.70.0.0|10.21.0.0|10.22.0.0|172.16.101.0|172.16.102.0|203.0.113.0"
        bgp = self.run(
            "ISP1",
            f"show bgp ipv4 unicast | include {leak_pattern}",
            fallback_cmd=f"show ip bgp | include {leak_pattern}",
        )
        if PUBLIC_NAT_PREFIX not in bgp and "198.51.100.32" not in bgp:
            isp_bad.append("ISP1: public NAT prefix absent")
        forbidden = [
            "10.10.0.0",
            "10.70.0.0",
            "10.21.0.0",
            "10.22.0.0",
            "172.16.101.0",
            "172.16.102.0",
            "203.0.113.0",
        ]
        for prefix in forbidden:
            if prefix in bgp:
                isp_bad.append(f"ISP1: forbidden prefix visible {prefix}")
        self.report_device_result("ISP1", not isp_bad, isp_bad, start)
        bad.extend(isp_bad)
        for dev in EDGE_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(dev, "198.51.100.32|ip prefix-list|route-map|network")
            if "198.51.100.32" not in cfg:
                dev_bad.append(f"{dev}: public NAT prefix/filter not visible in config")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(30, not bad, bad)

    # ---------- E ----------

    def _check_tunnel(self, row: int, left: str, right: str, tunnel: str, left_ip: str, right_ip: str) -> None:
        bad = []
        for dev, ip in ((left, left_ip), (right, right_ip)):
            start = self.live_device_start()
            dev_bad = []
            brief = self.ip_brief(dev, [tunnel])
            data = brief.get(tunnel)
            if not data:
                dev_bad.append(f"{dev} {tunnel}: absent")
                self.report_device_result(dev, False, dev_bad, start)
                bad.extend(dev_bad)
                continue
            if data["ip"] != ip:
                dev_bad.append(f"{dev} {tunnel}: IP {data['ip']} != {ip}")
            if data["status"] != "up" or data["protocol"] != "up":
                dev_bad.append(f"{dev} {tunnel}: {data['status']}/{data['protocol']}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        start = self.live_device_start()
        left_bad = []
        ping = self.run(left, f"ping {right_ip} source {left_ip} repeat 3 timeout 1")
        if "Success rate is 100 percent" not in ping and "Success rate is 80 percent" not in ping:
            left_bad.append(f"{left}: ping {right_ip} from {left_ip} failed")
        self.report_device_result(left, not left_bad, left_bad, start)
        bad.extend(left_bad)
        self.add(row, not bad, bad)

    def check_31_tunnel101(self) -> None:
        self._check_tunnel(31, "IR1", "BR1", "Tunnel101", "172.16.101.1", "172.16.101.2")

    def check_32_tunnel102(self) -> None:
        self._check_tunnel(32, "IR2", "BR2", "Tunnel102", "172.16.102.1", "172.16.102.2")

    def check_33_eigrp_neighbors(self) -> None:
        bad = []
        expected = {
            "IR1": ("172.16.101.2", "Tunnel101"),
            "BR1": ("172.16.101.1", "Tunnel101"),
            "IR2": ("172.16.102.2", "Tunnel102"),
            "BR2": ("172.16.102.1", "Tunnel102"),
        }
        for dev in EIGRP_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            eigrp_sec = self.eigrp_section(dev)
            prot = self.run(dev, "show ip protocols | include C1-OVERLAY|AS|EIGRP|Stub|stub")
            neigh_filter = "Tunnel101|Tunnel102|172.16.101.1|172.16.101.2|172.16.102.1|172.16.102.2"
            neigh = self.run(
                dev,
                f"show eigrp address-family ipv4 neighbors | include {neigh_filter}",
                fallback_cmd=f"show ip eigrp neighbors | include {neigh_filter}",
            )
            if "router eigrp C1-OVERLAY" not in eigrp_sec and "C1-OVERLAY" not in prot:
                dev_bad.append(f"{dev}: EIGRP named mode C1-OVERLAY not visible")
            if "autonomous-system 100" not in eigrp_sec and "AS(100)" not in prot and "AS 100" not in prot:
                dev_bad.append(f"{dev}: EIGRP AS100 not visible")
            peer_ip, iface = expected[dev]
            if peer_ip not in neigh or iface not in neigh:
                dev_bad.append(f"{dev}: neighbor {peer_ip} on {iface} missing")
            extra_tunnels = [t for t in ("Tunnel101", "Tunnel102") if t != iface and t in neigh]
            if extra_tunnels:
                dev_bad.append(f"{dev}: unexpected EIGRP tunnel {','.join(extra_tunnels)}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        for dev in ("BR1", "BR2"):
            start = self.live_device_start()
            dev_bad = []
            eigrp_sec = self.eigrp_section(dev)
            prot = self.run(dev, "show ip protocols | include Stub|stub|EIGRP")
            if "eigrp stub" not in eigrp_sec.lower() and "stub" not in prot.lower():
                dev_bad.append(f"{dev}: EIGRP stub not visible")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(33, not bad, bad)

    def check_34_eigrp_summaries(self) -> None:
        bad = []
        for dev, prefix in (("IR1", "10.21.0.0/16"), ("IR2", "10.22.0.0/16")):
            start = self.live_device_start()
            dev_bad = []
            route = self.ip_route_include(dev, [prefix.split("/")[0]])
            if not route_has_prefix(route, prefix):
                dev_bad.append(f"{dev}: missing branch summary {prefix}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        for dev in ("BR1", "BR2"):
            start = self.live_device_start()
            dev_bad = []
            route = self.ip_route_include(dev, ["10.10.0.0", "10.70.0.0"])
            for prefix in ("10.10.0.0/16", "10.70.0.0/16"):
                if not route_has_prefix(route, prefix):
                    dev_bad.append(f"{dev}: missing summary {prefix}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(34, not bad, bad)

    def check_35_branch_anti_leak(self) -> None:
        bad = []
        route_patterns = ["10.10.0.0", "10.70.0.0"] + [prefix.split("/")[0] for prefix in HQ_DC_SPECIFICS]
        for dev in ("BR1", "BR2"):
            start = self.live_device_start()
            dev_bad = []
            route = self.ip_route_include(dev, route_patterns)
            for prefix in ("10.10.0.0/16", "10.70.0.0/16"):
                if not route_has_prefix(route, prefix):
                    dev_bad.append(f"{dev}: summary absent {prefix}")
            for prefix in HQ_DC_SPECIFICS:
                if route_has_prefix(route, prefix):
                    dev_bad.append(f"{dev}: leaked specific {prefix}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(35, not bad, bad)

    def check_36_ospf_to_eigrp_tag(self) -> None:
        bad = []
        for dev in ("IR1", "IR2"):
            start = self.live_device_start()
            dev_bad = []
            eigrp_sec = self.eigrp_section(dev)
            route_map = self.route_map_filtered(dev)
            if "redistribute ospf 10" not in eigrp_sec or "route-map" not in eigrp_sec:
                dev_bad.append(f"{dev}: redistribute ospf 10 route-map missing")
            if "set tag 10010" not in route_map and "set tag 10010" not in eigrp_sec:
                dev_bad.append(f"{dev}: tag 10010 missing")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(36, not bad, bad)

    def check_37_eigrp_to_ospf_tag(self) -> None:
        bad = []
        for dev in ("IR1", "IR2"):
            start = self.live_device_start()
            dev_bad = []
            ospf_sec = self.ospf_section(dev)
            route_map = self.route_map_filtered(dev)
            if "redistribute eigrp" not in ospf_sec or "route-map" not in ospf_sec:
                dev_bad.append(f"{dev}: redistribute eigrp route-map missing")
            if "set tag 10020" not in route_map and "set tag 10020" not in ospf_sec:
                dev_bad.append(f"{dev}: tag 10020 missing")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(37, not bad, bad)

    def check_38_redistribution_loop_prevention(self) -> None:
        bad = []
        for dev in ("IR1", "IR2"):
            start = self.live_device_start()
            dev_bad = []
            text = self.ospf_section(dev) + "\n" + self.eigrp_section(dev) + "\n" + self.route_map_filtered(dev)
            if "match tag 10010" not in text:
                dev_bad.append(f"{dev}: no deny/match tag 10010")
            if "match tag 10020" not in text:
                dev_bad.append(f"{dev}: no deny/match tag 10020")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(38, not bad, bad)

    # ---------- F ----------

    def check_39_dhcp_relay(self) -> None:
        bad = []
        for dev in ("DS1", "DS2"):
            start = self.live_device_start()
            dev_bad = []
            for iface in ("Vlan10", "Vlan20"):
                sec = self.iface_section(dev, iface)
                if f"ip helper-address {SVR2_IP}" not in sec:
                    dev_bad.append(f"{dev} {iface}: helper missing")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        for dev in ("BR1", "BR2"):
            start = self.live_device_start()
            dev_bad = []
            sec = self.iface_section(dev, "GigabitEthernet0/1.10")
            if f"ip helper-address {SVR2_IP}" not in sec:
                dev_bad.append(f"{dev} G0/1.10: helper missing")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(39, not bad, bad)

    def check_40_pc_dhcp(self) -> None:
        self.skip(40, "Требуется выполнение команд на Linux PC1-PC4; текущий IOS scorer не имеет надёжного Linux-login.")

    def check_41_dns_from_pcs(self) -> None:
        self.skip(41, "Требуются dig-запросы с Linux PC1-PC4; без Linux-доступа результат нельзя подтвердить.")

    def check_42_ntp(self) -> None:
        bad = []
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            status = self.run(dev, "show ntp status")
            assoc = self.run(dev, f"show ntp associations | include {SVR1_IP}")
            ntp_cfg = self.run_config_include(dev, f"^ntp server|^ntp source|{SVR1_IP}")
            if "Clock is synchronized" not in status and "synchronised" not in status.lower():
                dev_bad.append(f"{dev}: clock not synchronized")
            if SVR1_IP not in assoc and SVR1_IP not in ntp_cfg:
                dev_bad.append(f"{dev}: association/server {SVR1_IP} missing")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(42, not bad, bad)

    def check_43_ir1_pat(self) -> None:
        cfg = self.run_config_include("IR1", "ip nat inside source|198.51.100.33|overload|access-list|ip access-list|route-map")
        nat = self.run("IR1", "show ip nat translations | include 198.51.100.33")
        ok = config_contains_ip_nat_for(cfg + nat, "198.51.100.33") and "overload" in cfg
        self.add(43, ok, "IR1 198.51.100.33 PAT visible" if ok else "IR1 PAT 198.51.100.33 not visible")

    def check_44_ir2_pat(self) -> None:
        cfg = self.run_config_include("IR2", "ip nat inside source|198.51.100.34|overload|access-list|ip access-list|route-map")
        nat = self.run("IR2", "show ip nat translations | include 198.51.100.34")
        ok = config_contains_ip_nat_for(cfg + nat, "198.51.100.34") and "overload" in cfg
        self.add(44, ok, "IR2 198.51.100.34 PAT visible" if ok else "IR2 PAT 198.51.100.34 not visible")

    def check_45_branch_pat(self) -> None:
        bad = []
        for dev in ("BR1", "BR2"):
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(dev, "ip nat inside source|overload")
            if "ip nat inside source" not in cfg or "overload" not in cfg:
                dev_bad.append(f"{dev}: overload PAT missing")
            if "ip nat outside" not in self.iface_section(dev, "GigabitEthernet0/0"):
                dev_bad.append(f"{dev}: WAN not nat outside")
            if "ip nat inside" not in self.iface_section(dev, "GigabitEthernet0/1.10"):
                dev_bad.append(f"{dev}: user subinterface not nat inside")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(45, not bad, bad)

    def check_46_static_nat_svr1(self) -> None:
        text = self.run_config_include("IR3", f"ip nat inside source|{SVR1_IP}|198.51.100.35")
        text += "\n" + self.run("IR3", f"show ip nat translations | include {SVR1_IP}|198.51.100.35")
        ok = SVR1_IP in text and "198.51.100.35" in text and "ip nat" in text
        self.add(46, ok, "IR3 static NAT SVR1 visible" if ok else "IR3 static NAT 10.70.30.10 <-> 198.51.100.35 missing")

    def check_47_nat_exemption(self) -> None:
        bad = []
        internal_nets = ["10.10.0.0", "10.70.0.0", "10.21.0.0", "10.22.0.0"]
        for dev in NAT_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(
                dev,
                "ip nat inside source|route-map|access-list|ip access-list|10.10.0.0|10.70.0.0|10.21.0.0|10.22.0.0",
            )
            nat_lines = "\n".join(line for line in cfg.splitlines() if "ip nat inside source" in line)
            if "route-map" not in nat_lines and "list" not in nat_lines:
                dev_bad.append(f"{dev}: NAT rule has no ACL/route-map reference")
                self.report_device_result(dev, False, dev_bad, start)
                bad.extend(dev_bad)
                continue
            deny_or_match = False
            for net in internal_nets:
                if net in cfg:
                    deny_or_match = True
                    break
            if not deny_or_match:
                dev_bad.append(f"{dev}: internal networks not visible in NAT exemption ACL/route-map")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(47, not bad, bad)

    def check_48_vty_acl(self) -> None:
        bad = []
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            vty_sections = self.run_config_section(dev, "^line vty")
            acl_cfg = self.run_config_include(dev, f"access-list|ip access-list|{SVR2_IP}")
            if "transport input ssh" not in vty_sections:
                dev_bad.append(f"{dev}: VTY not ssh-only")
            if "access-class" not in vty_sections:
                dev_bad.append(f"{dev}: no VTY access-class")
            if SVR2_IP not in acl_cfg:
                dev_bad.append(f"{dev}: ACL does not visibly permit SVR2 {SVR2_IP}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(48, not bad, bad)

    def check_49_user_vlan_ssh_to_servers(self) -> None:
        self.skip(49, "Требуются отрицательные SSH-тесты с PC1-PC4 к SVR1/SVR2 и сервисные проверки с Linux.")

    def check_50_acl_services_not_broken(self) -> None:
        must_pass_rows = {18, 19, 20, 33, 39, 42, 51}
        failed = [r.aspect.row for r in self.results if r.aspect.row in must_pass_rows and r.status != "PASS"]
        self.add(50, not failed, f"Dependent checks failed/skipped: {failed}" if failed else "HSRP/OSPF/EIGRP/DHCP/NTP/Syslog checks OK")

    def check_51_syslog(self) -> None:
        bad = []
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(dev, "^logging|^service timestamps log")
            if f"logging host {SVR1_IP}" not in cfg and f"logging {SVR1_IP}" not in cfg:
                dev_bad.append(f"{dev}: no logging host {SVR1_IP}")
            if not re.search(r"(?m)^logging trap (warnings|warning|4|errors|critical|alerts|emergencies)\b", cfg):
                dev_bad.append(f"{dev}: logging trap warnings-or-stricter not visible")
            if "service timestamps log" not in cfg:
                dev_bad.append(f"{dev}: no log timestamps")
            expected_source = "Loopback0" if dev in LOOPBACK0 else "Vlan50"
            if f"logging source-interface {expected_source}" not in cfg and "logging source-interface" not in cfg:
                dev_bad.append(f"{dev}: no logging source-interface")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(51, not bad, bad)

    def check_52_snmpv3(self) -> None:
        bad = []
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(dev, f"snmp|{SVR1_IP}|{SVR2_IP}|access-list|ip access-list")
            user = self.run(dev, "show snmp user | include c1snmp|authPriv|SHA|AES|priv")
            group = self.run(dev, "show snmp group | include c1snmp|v3|authPriv|priv")
            text = cfg + "\n" + user + "\n" + group
            if "c1snmp" not in text:
                dev_bad.append(f"{dev}: no c1snmp user")
            if "authPriv" not in text and "priv" not in text.lower():
                dev_bad.append(f"{dev}: no authPriv")
            if "SHA" not in text.upper():
                dev_bad.append(f"{dev}: no SHA auth")
            if "AES" not in text.upper():
                dev_bad.append(f"{dev}: no AES privacy")
            if SVR1_IP not in cfg and SVR2_IP not in cfg:
                dev_bad.append(f"{dev}: no visible SVR1/SVR2 SNMP ACL")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(52, not bad, bad)

    def check_53_netflow(self) -> None:
        bad = []
        for dev in EDGE_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            cfg = self.run_config_include(dev, f"flow|ip route-cache flow|ip flow|Loopback0|{SVR1_IP}|2055")
            flow = self.run(
                dev,
                f"show ip flow export | include {SVR1_IP}|2055|Loopback0|source|destination|Export",
                fallback_cmd=f"show flow exporter | include {SVR1_IP}|2055|Loopback0|source|destination|Export",
            )
            text = cfg + "\n" + flow
            if SVR1_IP not in text or "2055" not in text:
                dev_bad.append(f"{dev}: collector {SVR1_IP}:2055 missing")
            if "Loopback0" not in text:
                dev_bad.append(f"{dev}: source Loopback0 missing")
            if "ip flow ingress" not in cfg and "ip flow monitor" not in cfg and "ip route-cache flow" not in cfg:
                dev_bad.append(f"{dev}: flow not enabled on interfaces")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(53, not bad, bad)

    def check_54_static_routes(self) -> None:
        bad = []
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            route_cfg = self.run_config_include(dev, "^ip route")
            routes = [line.strip() for line in route_cfg.splitlines() if line.strip().startswith("ip route ")]
            for line in routes:
                allowed = False
                if "Null0" in line and "198.51.100.32" in line:
                    allowed = True
                if dev in ("BR1", "BR2") and re.search(r"ip route\s+0\.0\.0\.0\s+0\.0\.0\.0\s+203\.0\.113\.", line):
                    allowed = True
                if dev in EDGE_DEVICES and ("203.0.113.14" in line or "203.0.113.18" in line):
                    allowed = True
                if not allowed:
                    dev_bad.append(f"{dev}: {line}")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(54, not bad, bad)

    def check_55_interfaces_and_saved(self) -> None:
        bad = []
        topo_nodes = self.topo.get("nodes", {})
        for dev in MANAGED_DEVICES:
            start = self.live_device_start()
            dev_bad = []
            expected_ifaces = topo_nodes.get(dev, {}).get("interfaces", {})
            brief = self.ip_brief(dev, expected_ifaces)
            for iface in expected_ifaces:
                data = brief.get(canonical_ifname(iface))
                if not data or data["status"] != "up" or data["protocol"] != "up":
                    dev_bad.append(f"{dev} {iface}: not up/up")
            if dev in ("DS1", "DS2"):
                po = parse_ip_interface_brief(self.run(dev, "show ip interface brief | include Port-channel12"))
                if not po:
                    dev_bad.append(f"{dev}: Port-channel12 absent")
                elif any(v["status"] != "up" or v["protocol"] != "up" for v in po.values()):
                    dev_bad.append(f"{dev}: Port-channel12 not up/up")
            startup = self.startup_config(dev)
            if f"hostname {dev}" not in startup:
                dev_bad.append(f"{dev}: startup-config missing or not saved")
            self.report_device_result(dev, not dev_bad, dev_bad, start)
            bad.extend(dev_bad)
        self.add(55, not bad, bad)

    def check_56_final_functional(self) -> None:
        self.skip(56, "Итоговые тесты требуют одновременного запуска команд с PC1-PC4/SVR2 и проверки сервисов Linux.")

    def check_57_infrastructure_integrity(self) -> None:
        self.skip(57, "Нет эталонного снапшота ISP1/SVR1/SVR2 и Linux-доступа к SVR1/SVR2; автоматом не сравниваю.")

    def check_plan(self) -> list[tuple[int, object]]:
        return [
            (1, self.check_1_basic_identity),
            (2, self.check_2_ssh_vty),
            (3, self.check_3_timezone),
            (4, self.check_4_addressing),
            (5, self.check_5_management_reachability),
            (6, self.check_6_vlans),
            (7, self.check_7_vtp),
            (8, self.check_8_hq_trunks),
            (9, self.check_9_dc_trunk),
            (10, self.check_10_branch_trunks),
            (11, self.check_11_access_ports),
            (12, self.check_12_etherchannel),
            (13, self.check_13_stp_hq),
            (14, self.check_14_stp_dc),
            (15, self.check_15_port_security),
            (16, self.check_16_cdp),
            (17, self.check_17_l3_routing),
            (18, self.check_18_hq_hsrp),
            (19, self.check_19_dc_hsrp),
            (20, self.check_20_ospf_basic),
            (21, self.check_21_ospf_area_plan),
            (22, self.check_22_ospf_passive_p2p),
            (23, self.check_23_hq_ospf_summary),
            (24, self.check_24_dc_ospf_summary),
            (25, self.check_25_ebgp),
            (26, self.check_26_ibgp),
            (27, self.check_27_bgp_as_stability),
            (28, self.check_28_default_route_control),
            (29, self.check_29_ir3_not_default),
            (30, self.check_30_route_leak),
            (31, self.check_31_tunnel101),
            (32, self.check_32_tunnel102),
            (33, self.check_33_eigrp_neighbors),
            (34, self.check_34_eigrp_summaries),
            (35, self.check_35_branch_anti_leak),
            (36, self.check_36_ospf_to_eigrp_tag),
            (37, self.check_37_eigrp_to_ospf_tag),
            (38, self.check_38_redistribution_loop_prevention),
            (39, self.check_39_dhcp_relay),
            (40, self.check_40_pc_dhcp),
            (41, self.check_41_dns_from_pcs),
            (42, self.check_42_ntp),
            (43, self.check_43_ir1_pat),
            (44, self.check_44_ir2_pat),
            (45, self.check_45_branch_pat),
            (46, self.check_46_static_nat_svr1),
            (47, self.check_47_nat_exemption),
            (48, self.check_48_vty_acl),
            (49, self.check_49_user_vlan_ssh_to_servers),
            # Row 50 depends on row 51, so row 51 is intentionally executed first.
            (51, self.check_51_syslog),
            (50, self.check_50_acl_services_not_broken),
            (52, self.check_52_snmpv3),
            (53, self.check_53_netflow),
            (54, self.check_54_static_routes),
            (55, self.check_55_interfaces_and_saved),
            (56, self.check_56_final_functional),
            (57, self.check_57_infrastructure_integrity),
        ]

    def print_result(self, result: Result) -> None:
        color = self.status_color(result.status)
        mark = f"{result.score:.2f}/{result.aspect.max_mark:.2f}"
        if result.status == "PART" and result.passed is not None and result.total:
            mark = f"{mark} ({result.passed}/{result.total})"
        print(
            f"{color}[{result.status:4}] Row {result.aspect.row:02d} "
            f"({result.aspect.criterion}) {mark} - {result.aspect.title}{NC}"
        )
        if result.details:
            print(f"       {result.details}")

    def devices_from_records(self, records: list[CommandRecord]) -> list[str]:
        devices: list[str] = []
        for record in records:
            if record.device not in devices:
                devices.append(record.device)
        return devices

    def live_device_start(self) -> int:
        return len(self.command_log)

    def print_expected(self, row: int) -> None:
        expected = ASPECT_EXPECTED.get(row, ASPECTS[row].title)
        print(f"\n{CYAN}Ожидаемый результат:{NC}")
        print(f"  {expected}")

    def device_mentioned_in_details(self, dev: str, details: str) -> bool:
        return bool(re.search(rf"(?<![A-Za-z0-9_-]){re.escape(dev)}(?![A-Za-z0-9_-])", details))

    def infer_device_outcomes(self, result: Result, records: list[CommandRecord]) -> dict[str, str]:
        live = self.live_device_outcomes.get(result.aspect.row)
        if live:
            return dict(live)
        devices = self.devices_from_records(records)
        if not devices:
            return {}
        if result.status == "PASS":
            return {dev: "PASS" for dev in devices}
        if result.status == "SKIP":
            return {dev: "SKIP" for dev in devices}

        details = result.raw_details or result.details
        mentioned_failures = {dev for dev in devices if self.device_mentioned_in_details(dev, details)}
        if result.status == "PART":
            if not mentioned_failures:
                return {}
            return {dev: ("FAIL" if dev in mentioned_failures else "PASS") for dev in devices}
        if not mentioned_failures:
            return {dev: "FAIL" for dev in devices}
        return {dev: ("FAIL" if dev in mentioned_failures else "PASS") for dev in devices}

    def status_color(self, status: str) -> str:
        if status == "PASS":
            return GREEN
        if status == "PART":
            return PURPLE
        if status == "SKIP":
            return CYAN
        return RED

    def print_device_outcomes_summary(self, outcomes: dict[str, str]) -> None:
        if not outcomes:
            return
        pass_count = sum(1 for status in outcomes.values() if status == "PASS")
        check_count = sum(1 for status in outcomes.values() if status in {"PASS", "FAIL"})
        if check_count:
            color = GREEN if pass_count == check_count else PURPLE if pass_count else RED
            note = " (частичный балл)" if 0 < pass_count < check_count else ""
            print(f"  {color}Итого по устройствам: {pass_count}/{check_count} PASS{note}{NC}")

    def print_device_command_block(
        self,
        dev: str,
        status: str,
        records: list[CommandRecord],
        details: list[str] | str = "",
    ) -> None:
        color = self.status_color(status)
        print(f"\n{color}--- {dev} [{status}] ---{NC}")
        if not records:
            print("(команды для устройства не выполнялись)")
        for idx, record in enumerate(records, start=1):
            cached_note = " cached" if record.cached else ""
            print(f"{BLUE}Команда [{idx}]: {record.command}{cached_note}{NC}")
            output = record.output.rstrip()
            print(output if output else "(пустой вывод)")

        text, _ = self.format_details(details)
        if text:
            print(f"Детали {dev}: {text}")
        print(f"{color}Итог {dev}: {status}{NC}")

    def report_device_result(
        self,
        dev: str,
        ok: bool,
        details: list[str] | str = "",
        start_index: int | None = None,
    ) -> None:
        if self.current_row is None:
            return
        status = "PASS" if ok else "FAIL"
        records = self.command_log[start_index or 0 :]
        records = [record for record in records if record.row == self.current_row and record.device == dev]
        self.print_device_command_block(dev, status, records, details)
        self.live_rows.add(self.current_row)
        previous = self.live_device_outcomes[self.current_row].get(dev)
        if previous == "FAIL" or status == "FAIL":
            self.live_device_outcomes[self.current_row][dev] = "FAIL"
        elif previous == "SKIP" or status == "SKIP":
            self.live_device_outcomes[self.current_row][dev] = "SKIP"
        else:
            self.live_device_outcomes[self.current_row][dev] = "PASS"
        for record in records:
            self.live_printed_record_ids.add(id(record))

    def print_device_outcomes(self, result: Result, records: list[CommandRecord]) -> None:
        outcomes = self.infer_device_outcomes(result, records)
        if not outcomes:
            return

        print(f"\n{CYAN}Результат по устройствам:{NC}")
        for dev, status in outcomes.items():
            color = self.status_color(status)
            print(f"  {color}[{status:4}] {dev}{NC}")
        self.print_device_outcomes_summary(outcomes)

    def print_aspect_evidence(self, row: int, records: list[CommandRecord], result: Result | None = None) -> None:
        print(f"\n{CYAN}Команды проверки:{NC}")
        if not records:
            print("  Команды на устройствах не выполнялись для этого аспекта.")
            return

        seen: set[tuple[str, str, bool]] = set()
        for record in records:
            key = (record.device, record.command, record.cached)
            if key in seen:
                continue
            seen.add(key)
            cached_note = " (cached)" if record.cached else ""
            print(f"  {record.device}: {record.command}{cached_note}")

        outcomes = self.infer_device_outcomes(result, records) if result else {}
        unprinted_records = [record for record in records if id(record) not in self.live_printed_record_ids]
        if row in self.live_rows and not unprinted_records:
            print(f"\n{CYAN}Вывод команд с устройств:{NC}")
            print("  Вывод команд уже напечатан выше по мере проверки каждого устройства.")
            self.print_device_outcomes_summary(outcomes)
            return

        by_device: dict[str, list[CommandRecord]] = defaultdict(list)
        for record in unprinted_records:
            by_device[record.device].append(record)

        print(f"\n{CYAN}Вывод команд с устройств:{NC}")
        for dev in self.devices_from_records(unprinted_records):
            status = outcomes.get(dev)
            if status:
                color = self.status_color(status)
                print(f"{color}--- {dev} [{status}] ---{NC}")
            else:
                color = BLUE
                print(f"{BLUE}--- {dev} ---{NC}")

            for idx, record in enumerate(by_device[dev], start=1):
                cached_note = " cached" if record.cached else ""
                print(f"{BLUE}Команда [{idx}]: {record.command}{cached_note}{NC}")
                output = record.output.rstrip()
                print(output if output else "(пустой вывод)")

            if status:
                print(f"{color}Итог {dev}: {status}{NC}")

        self.print_device_outcomes_summary(outcomes)

    def pause_after_aspect(self) -> None:
        try:
            input(f"{YELLOW}\nНажмите Enter для следующего аспекта...{NC}")
        except EOFError:
            pass

    def run_from(self, start_row: int = 1, pause: bool = True) -> None:
        plan = [(row, check) for row, check in self.check_plan() if row >= start_row]
        if not plan:
            print(f"{RED}[!] Нет аспектов для запуска с row/aspect {start_row}{NC}")
            return

        print(
            f"{CYAN}[+] Запуск C1 scorer с aspect/row {start_row}. "
            f"Паузы: {'включены' if pause else 'выключены'}{NC}"
        )

        for row, check in plan:
            aspect = ASPECTS[row]
            print(f"\n{PURPLE}{'=' * 105}{NC}")
            print(f"{PURPLE}Row {row:02d} ({aspect.criterion}) - {aspect.title}{NC}")
            print(f"{PURPLE}{'=' * 105}{NC}")
            self.print_expected(row)
            before = len(self.results)
            cmd_before = len(self.command_log)
            self.current_row = row
            try:
                check()
            except Exception as exc:
                self.add(row, False, f"Unhandled checker error: {exc}")
            finally:
                self.current_row = None
            aspect_records = self.command_log[cmd_before:]
            aspect_results = self.results[before:]
            primary_result = aspect_results[-1] if aspect_results else None
            self.print_aspect_evidence(row, aspect_records, primary_result)
            for result in aspect_results:
                self.print_result(result)
            if pause:
                self.pause_after_aspect()

    def run_all(self, pause: bool = True) -> None:
        self.run_from(1, pause=pause)

    def print_report(self) -> None:
        print(f"\n{PURPLE}{'#' * 105}{NC}")
        print(f"{PURPLE}C1 Marking Scheme Report{NC}")
        print(f"{PURPLE}{'#' * 105}{NC}\n")

        ordered_results = sorted(self.results, key=lambda item: item.aspect.row)
        for result in ordered_results:
            color = self.status_color(result.status)
            mark = f"{result.score:.2f}/{result.aspect.max_mark:.2f}"
            if result.status == "PART" and result.passed is not None and result.total:
                mark = f"{mark} ({result.passed}/{result.total})"
            print(
                f"{color}[{result.status:4}] Row {result.aspect.row:02d} "
                f"({result.aspect.criterion}) {mark} - {result.aspect.title}{NC}"
            )
            if result.details:
                print(f"       {result.details}")

        totals = defaultdict(float)
        maximums = defaultdict(float)
        skipped = defaultdict(float)
        partial = defaultdict(bool)
        for result in ordered_results:
            totals[result.aspect.criterion] += result.score
            maximums[result.aspect.criterion] += result.aspect.max_mark
            if result.status == "PART":
                partial[result.aspect.criterion] = True
            if result.status == "SKIP":
                skipped[result.aspect.criterion] += result.aspect.max_mark

        print(f"\n{PURPLE}Итог по критериям:{NC}")
        grand_total = 0.0
        grand_max = 0.0
        for criterion in "ABCDEF":
            grand_total += totals[criterion]
            grand_max += maximums[criterion]
            skip_note = f", SKIP {skipped[criterion]:.2f}" if skipped[criterion] else ""
            if not maximums[criterion]:
                color = CYAN
            elif partial[criterion]:
                color = PURPLE
            elif skipped[criterion]:
                color = YELLOW
            elif totals[criterion] == maximums[criterion]:
                color = GREEN
            elif totals[criterion]:
                color = PURPLE
            else:
                color = RED
            print(f"  {color}{criterion}: {totals[criterion]:.2f}/{maximums[criterion]:.2f}{skip_note}{NC}")
        if not grand_max:
            total_color = CYAN
        elif grand_total == grand_max:
            total_color = GREEN
        elif grand_total:
            total_color = PURPLE
        else:
            total_color = RED
        print(f"\n{total_color}TOTAL: {grand_total:.2f}/{grand_max:.2f}{NC}")
        if any(r.status == "SKIP" for r in ordered_results):
            print(
                f"{YELLOW}Примечание: SKIP-баллы не начислены. Эти пункты требуют Linux PC/SVR "
                "или эталонного снапшота, которых текущий IOS-only scorer не может подтвердить честно."
                f"{NC}"
            )


def resolve_start_row(value: str) -> int:
    selector = (value or "A").strip().upper()
    if selector.isdigit():
        row = int(selector)
        if row not in ASPECTS:
            raise ValueError("номер аспекта должен быть в диапазоне 1-57")
        return row
    if selector in SUBCRITERION_START_ROW:
        return SUBCRITERION_START_ROW[selector]
    if selector in CRITERION_START_ROW:
        return CRITERION_START_ROW[selector]
    raise ValueError("используйте A-F, A1-F6 или номер аспекта 1-57")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="C1 unified scorer for 05_C1_CIS_Marking_Scheme_NEW.xlsx"
    )
    parser.add_argument(
        "--start",
        default="A",
        help="С какого места начать: A-F, A1-F6 или номер aspect/row 1-57. По умолчанию A.",
    )
    parser.add_argument(
        "--no-pause",
        action="store_true",
        help="Не ждать Enter после каждого аспекта.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        start_row = resolve_start_row(args.start)
    except ValueError as exc:
        print(f"{RED}[!] Некорректный --start '{args.start}': {exc}{NC}")
        return

    try:
        creds = load_json_file(CREDS_FILE)
    except FileNotFoundError:
        print(f"{RED}[!] Не найден файл {CREDS_FILE}{NC}")
        return

    try:
        topo = load_json_file(TOPO_FILE)
    except FileNotFoundError:
        print(f"{RED}[!] Не найден файл {TOPO_FILE}{NC}")
        return

    pnet_url = creds.get("pnet_url")
    username = creds.get("username")
    password = creds.get("password")
    enable_password = creds.get("enable_password")
    device_username = creds.get("device_username")
    device_password = creds.get("device_password")

    if not pnet_url or not username or not password:
        print(f"{RED}[!] В {CREDS_FILE} не заполнены pnet_url/username/password{NC}")
        return

    print(f"{CYAN}[+] Логин в PNETLab как {username}{NC}")
    cookie = login(pnet_url, username, password)

    try:
        session_id = get_running_session_id_by_substring(pnet_url, cookie, TARGET_LAB_NAME_SUBSTR)
        print(f"{BLUE}[+] Используем lab_session_id={session_id}{NC}")

        print(f"{BLUE}[+] Присоединяемся к сессии...{NC}")
        join_session(pnet_url, session_id, cookie)

        print(f"{BLUE}[+] Получаем список нод...{NC}")
        nodes_json = get_nodes(pnet_url, cookie).json()
        node_console_map = build_node_console_map(nodes_json)

        missing = [dev for dev in MANAGED_DEVICES if dev not in node_console_map]
        if missing:
            print(f"{YELLOW}[!] В PNETLab не найдены Cisco-ноды из схемы: {', '.join(missing)}{NC}")

        scorer = C1Scorer(
            node_console_map,
            topo,
            enable_password,
            device_username=device_username,
            device_password=device_password,
        )
        try:
            scorer.connect_devices()
            scorer.run_from(start_row, pause=not args.no_pause)
            scorer.print_report()
        finally:
            scorer.close_devices()

    finally:
        print(f"{CYAN}[+] Logout из PNETLab{NC}")
        try:
            logout(pnet_url)
        except Exception as exc:
            print(f"{RED}[!] Ошибка при logout: {exc}{NC}")


if __name__ == "__main__":
    main()
