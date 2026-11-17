#!/usr/bin/env python3
"""Generate per-device config_db.json for the SONiC IP CLOS lab.

Reads configs/base_config_db.default.json (image default) and writes:
  configs/sonic-spine1/config_db.json
  configs/sonic-spine2/config_db.json
  configs/sonic-leaf1/config_db.json
  configs/sonic-leaf2/config_db.json

Topology mirrors inventory/fabric.yaml (links section).

Build notes (master.1273518-6f800f3d4, FRR 10.7.1 sonic):
- No BGP_GLOBALS / no `config bgp network` in this build. Route
  advertisement = STATIC_ROUTE entries, auto-redistributed into BGP
  by bgpcfgd (managers_static_rt.py, ROUTE_ADVERTISE_ENABLE_TAG=1).
- ECMP requires /etc/sonic/constants.yml bgp.maximum_paths.ipv4/ipv6: 2
  (image default 514 is rejected by FRR at runtime; see
  runbooks/04-fabric-config.md). The PORT table must stay 32 entries
  (kernel-NIC mapping depends on it).
"""
import json
import os

BASE = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "configs", "base_config_db.default.json"))

# Faster lab timers than image default (180/60) — quicker ECMP flap visibility.
PEER_KEEPALIVE = "30"
PEER_HOLDTIME = "90"

# links: (port, own /31 IP, peer /31 IP or None, peer name, peer ASN)
DEVICES = {
    "spine1": {
        "hostname": "spine1",
        "type": "SpineRouter",
        "asn": "65001",
        "loopback": "10.1.0.1/32",
        "links": [
            ("Ethernet0",  "10.0.1.0",  "10.0.1.1",  "leaf1a", "65002"),
            ("Ethernet4",  "10.0.2.0",  "10.0.2.1",  "leaf1b", "65002"),
            ("Ethernet8",  "10.0.3.0",  "10.0.3.1",  "leaf2a", "65002"),
            ("Ethernet12", "10.0.4.0",  "10.0.4.1",  "leaf2b", "65002"),
        ],
        "static_routes": {
            "10.1.0.1/32": {"blackhole": "true"},
        },
    },
    "spine2": {
        "hostname": "spine2",
        "type": "SpineRouter",
        "asn": "65001",
        "loopback": "10.1.0.2/32",
        "links": [
            ("Ethernet0",  "10.0.5.0",  "10.0.5.1",  "leaf1a", "65002"),
            ("Ethernet4",  "10.0.6.0",  "10.0.6.1",  "leaf1b", "65002"),
            ("Ethernet8",  "10.0.7.0",  "10.0.7.1",  "leaf2a", "65002"),
            ("Ethernet12", "10.0.8.0",  "10.0.8.1",  "leaf2b", "65002"),
        ],
        "static_routes": {
            "10.1.0.2/32": {"blackhole": "true"},
        },
    },
    "leaf1": {
        "hostname": "leaf1",
        "type": "LeafRouter",
        "asn": "65002",
        "loopback": "10.1.0.3/32",
        "links": [
            ("Ethernet0",  "10.0.1.1",  "10.0.1.0",  "spine1a", "65001"),
            ("Ethernet4",  "10.0.2.1",  "10.0.2.0",  "spine1b", "65001"),
            ("Ethernet8",  "10.0.5.1",  "10.0.5.0",  "spine2a", "65001"),
            ("Ethernet12", "10.0.6.1",  "10.0.6.0",  "spine2b", "65001"),
            ("Ethernet16", "10.0.9.0",  None,        None,      None),
        ],
        "static_routes": {
            "10.1.0.3/32":   {"blackhole": "true"},
            "10.0.9.0/31":   {"blackhole": "true"},
            "10.1.0.99/32":  {"nexthop": "10.0.9.1"},
        },
    },
    "leaf2": {
        "hostname": "leaf2",
        "type": "LeafRouter",
        "asn": "65002",
        "loopback": "10.1.0.4/32",
        "links": [
            ("Ethernet0",  "10.0.3.1",  "10.0.3.0",  "spine1a", "65001"),
            ("Ethernet4",  "10.0.4.1",  "10.0.4.0",  "spine1b", "65001"),
            ("Ethernet8",  "10.0.7.1",  "10.0.7.0",  "spine2a", "65001"),
            ("Ethernet12", "10.0.8.1",  "10.0.8.0",  "spine2b", "65001"),
            ("Ethernet16", "10.0.10.0", None,        None,      None),
        ],
        "static_routes": {
            "10.1.0.4/32":   {"blackhole": "true"},
            "10.0.10.0/31":  {"blackhole": "true"},
            "10.1.0.100/32": {"nexthop": "10.0.10.1"},
        },
    },
}


def build(base, spec):
    cfg = {k: v for k, v in base.items()}

    dm = dict(base["DEVICE_METADATA"]["localhost"])
    dm["hostname"] = spec["hostname"]
    dm["type"] = spec["type"]
    dm["bgp_asn"] = spec["asn"]
    cfg["DEVICE_METADATA"] = {"localhost": dm}

    cfg["LOOPBACK_INTERFACE"] = {
        "Loopback0": {},
        "Loopback0|" + spec["loopback"]: {},
    }

    ifaces = {}
    neighbors = {}
    for port, own_ip, peer_ip, name, peer_asn in spec["links"]:
        ifaces[port] = {}
        ifaces[port + "|" + own_ip] = {}
        if peer_ip is not None:
            neighbors[peer_ip] = {
                "rrclient": 0,
                "name": name,
                "local_addr": own_ip,
                "nhopself": 0,
                "holdtime": PEER_HOLDTIME,
                "asn": peer_asn,
                "keepalive": PEER_KEEPALIVE,
            }
    cfg["INTERFACE"] = ifaces
    cfg["BGP_NEIGHBOR"] = neighbors
    # PORT / FLEX_COUNTER_TABLE / DEVICE_NEIGHBOR intentionally untouched.
    cfg["STATIC_ROUTE"] = spec["static_routes"]

    assert len(cfg["PORT"]) == 32, "PORT table must stay 32 entries"
    return cfg


def main():
    with open(BASE) as f:
        base = json.load(f)
    for name, spec in DEVICES.items():
        out = os.path.normpath(os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "..", "configs", "sonic-" + name, "config_db.json"))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w") as f:
            json.dump(build(base, spec), f, indent=4)
            f.write("\n")
        print("wrote", out)


if __name__ == "__main__":
    main()
