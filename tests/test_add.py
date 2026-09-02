#!/usr/bin/env python3
"""./niosx add — wait for registration, rename, record, apply.

Run: python3 tests/test_add.py    (stubbed; no host, no tenant, and the real
terraform/niosx_hosts.json is never touched — NIOSX_HOSTS_JSON points the
script *and* Terraform at a temp copy.)
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import case, report

VM = "name: tester-250\nnet0: virtio=aa:bb:cc:dd:ee:ff,bridge=vmbr0\n"
REGISTERED = {"STUB_QM_CONFIG": VM, "STUB_HOST_REGISTERED": "1"}
ADD = "add-services.sh"


def recorded(ws):
    """The host and its services must end up in the file Terraform reads."""
    try:
        d = json.load(open(ws.hosts_json))
    except Exception as e:
        return ["niosx_hosts.json unreadable: %s" % e]
    host = d.get("tester-250")
    if not host:
        return ["tester-250 missing from %s" % ws.hosts_json]
    problems = []
    if host.get("pool_id") != "infra/pool/p1":
        problems.append("pool_id is %r, wanted the infra/pool/ prefixed form" % host.get("pool_id"))
    if host.get("services") != ["dns", "dhcp"]:
        problems.append("services are %r" % host.get("services"))
    return problems


case("a host that has registered is renamed, recorded and applied",
     script=ADD, args=("250", "tester-250", "dns,dhcp"), env=REGISTERED,
     rc=0, after=recorded,
     has=["registered. pool_id = infra/pool/p1", "renamed host in CSP to tester-250",
          "starting services on tester-250: dns,dhcp"],
     log_has=["TOFU: apply -auto-approve"])
case("the bare pool_id from the API is stored prefixed",
     script=ADD, args=("250", "tester-250", "dns"), env=REGISTERED,
     has=["pool_id = infra/pool/p1"])
case("'none' is refused rather than applied as a service",
     script=ADD, args=("250", "tester-250", "none"), rc=1,
     has=["no services requested"], log_hasnt=["TOFU"])
case("a service the tenant does not offer is refused",
     script=ADD, args=("250", "tester-250", "banana"), env=REGISTERED, rc=1,
     has=["is not offered by this tenant"], log_hasnt=["TOFU"])
case("a bad VMID is refused before anything is queried",
     script=ADD, args=("abc", "tester-250", "dns"), rc=1,
     has=["VMID must be a number"], log_hasnt=["TOFU"])
case("a host name with shell characters is refused",
     script=ADD, args=("250", 'x;reboot', "dns"), rc=1,
     has=["contains characters that are not allowed"], log_hasnt=["TOFU"])
case("a join token in place of the API key is caught",
     script=ADD, args=("250", "tester-250", "dns"),
     setup=lambda ws: open(ws.secrets, "w").write('infoblox_api_key = "wrong-secret.ibjt"\n'),
     rc=1, has=["JOIN TOKEN, not a CSP API key"], log_hasnt=["TOFU"])

sys.exit(report())
