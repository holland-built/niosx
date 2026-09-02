#!/usr/bin/env python3
"""Teardown and inventory. Run: python3 tests/test_teardown.py

Every case is --dry-run or read-only, against the stubs in tests/stubs.
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import case, report

VM = "name: tester-250\nnet0: virtio=aa:bb:cc:dd:ee:ff,bridge=vmbr0\n"


def with_journal(ws):
    """Simulate a teardown that was killed half way through."""
    d = os.path.join(ws.dir, "teardown")
    os.makedirs(d, exist_ok=True)
    json.dump({"vmid": "250", "pve": "root@stub", "label": "tester-250",
               "mac": "aa:bb:cc:dd:ee:ff", "csp_id": "infra/host/1", "pool": "p1"},
              open(os.path.join(d, "250.json"), "w"))


# ---- the journal is read, not just written ----
case("an interrupted teardown is reported on the next run",
     script="teardown-niosx.sh", args=("250", "--dry-run"), setup=with_journal,
     env={"STUB_QM_CONFIG": VM},
     has=["a previous teardown of VMID 250 did not finish", "label   : tester-250",
          "each step re-runs safely"])
case("a clean run says nothing about journals",
     script="teardown-niosx.sh", args=("250", "--dry-run"), env={"STUB_QM_CONFIG": VM},
     hasnt=["did not finish"])
case("./niosx list surfaces the interrupted teardown",
     script="list-niosx.sh", setup=with_journal,
     has=["== Interrupted teardowns ==", "vmid 250", "./niosx teardown 250"])
case("./niosx list says so when there are none",
     script="list-niosx.sh", has=["== Interrupted teardowns ==", "(none)"])

# ---- the guard rails ----
case("--all is refused", script="teardown-niosx.sh", args=("250", "--all"), rc=2,
     has=["is not supported"])
case("a label with shell or regex characters is refused",
     script="teardown-niosx.sh", args=("250", "--label", 'a"b$c', "--dry-run"), rc=2,
     has=["contains characters that are not allowed"])
case("--dry-run changes nothing on the host",
     script="teardown-niosx.sh", args=("250", "--dry-run"), env={"STUB_QM_CONFIG": VM},
     has=["(--dry-run: nothing changed)"], log_hasnt=["REMOTE-SCRIPT"])

# ---- shapes the live API really returns (found on 2026-09-02) ----
# A query that matches nothing answers {} with no "results" key. Read as a
# failed lookup, teardown refused to run at all.
case("a host that is not in the Portal is 'not registered', not a failed lookup",
     script="teardown-niosx.sh", args=("250", "--dry-run"), env={"STUB_QM_CONFIG": VM},
     has=["not registered"], hasnt=["CSP lookup failed"])
case("./niosx list shows the services a host is really running",
     script="list-niosx.sh", env={"STUB_HOST_REGISTERED": "1"},
     has=["dhcp,dns"])

sys.exit(report())
