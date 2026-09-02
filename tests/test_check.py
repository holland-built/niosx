#!/usr/bin/env python3
"""deploy --no-wait and ./niosx check. Run: python3 tests/test_check.py

Stubbed: no Proxmox host, no tenant.
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import case, report

VM = "name: tester-250\nnet0: virtio=aa:bb:cc:dd:ee:ff,bridge=vmbr0\n"
CHECK = "check-niosx.sh"
PIN = ("--vmid", "250", "--name", "tester-250")


def pending_dns(ws):
    os.makedirs(ws.pending_dir, exist_ok=True)
    json.dump({"vmid": "250", "name": "tester-250", "services": "dns",
               "pve": "root@stub-proxmox.invalid"},
              open(os.path.join(ws.pending_dir, "250.json"), "w"))


def record_written(ws):
    path = os.path.join(ws.pending_dir, "250.json")
    if not os.path.exists(path):
        return ["no pending record at %s" % path]
    d = json.load(open(path))
    if d.get("services") != "dns" or d.get("name") != "tester-250":
        return ["pending record says %r" % d]
    return []


def record_cleared(ws):
    path = os.path.join(ws.pending_dir, "250.json")
    return ["pending record still there: %s" % path] if os.path.exists(path) else []


# ---- deploy --no-wait returns as soon as the VM is running ----
case("--no-wait starts the VM and returns without waiting for services",
     args=("--services", "dns", "--no-wait") + PIN, rc=0, after=record_written,
     has=["not waiting", "./niosx check"],
     log_has=["QM-START"], log_hasnt=["TOFU"])
case("without --no-wait the deploy goes on to start services",
     args=("--services", "dns") + PIN,
     env={"STUB_HOST_REGISTERED": "1", "STUB_QM_CONFIG_AFTER_CREATE": VM},
     has=["Adding services once it registers", "deployed and running: dns"],
     log_has=["TOFU: apply -auto-approve"])

# ---- check reports what is true now ----
case("nothing pending says so",
     script=CHECK, has=["nothing pending"])
case("a node that has not registered yet is still registering",
     script=CHECK, setup=pending_dns, env={"STUB_QM_CONFIG": VM},
     has=["still registering"], log_hasnt=["TOFU: apply"])
case("a registered node is reported ready, and is not touched",
     script=CHECK, setup=pending_dns,
     env={"STUB_QM_CONFIG": VM, "STUB_HOST_REGISTERED": "1"},
     has=["ready. Finish with:", "./niosx check 250 --finish"],
     log_hasnt=["TOFU: apply"])
case("--finish starts the waiting services and clears the record",
     script=CHECK, args=("--finish",), setup=pending_dns,
     env={"STUB_QM_CONFIG": VM, "STUB_HOST_REGISTERED": "1"},
     after=record_cleared, has=["starting: dns", "record cleared"],
     log_has=["TOFU: apply -auto-approve"])
case("a node whose VM is gone is called out, not silently retried",
     script=CHECK, setup=pending_dns,
     has=["vm:gone", "Remove the record"], log_hasnt=["TOFU: apply"])
case("checking one VMID ignores the others",
     script=CHECK, args=("999",), setup=pending_dns, env={"STUB_QM_CONFIG": VM},
     has=["nothing pending for VMID 999"])
case("a bad VMID is refused",
     script=CHECK, args=("abc",), rc=1, has=["VMID must be a number"])

sys.exit(report())
