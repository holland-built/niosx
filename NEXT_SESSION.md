# Prompt for a fresh session

Paste everything in the block below into a new Claude Code session.

---

```
Work on the NIOS-X on Proxmox tooling at ~/AI/HomeSystems/niosx
(public repo: github.com/holland-built/niosx). Read HANDOFF.md and README.md first,
then run ./niosx test (30s, touches nothing).

WHAT IT IS
One command builds an Infoblox NIOS-X On-Prem VM on Proxmox, lets it self-register
to the Infoblox Portal (CSP) via a cloud-init join token, renames it, and starts
chosen services via OpenTofu. Audience: ~700 Infoblox sales engineers sharing ONE
CSP tenant, mostly network people rather than developers.

  ./niosx deploy | add | teardown | list | test
  ./niosx deploy --resume <vmid>     # finish a half-built node

DONE AND VERIFIED LIVE
- Full lifecycle twice: VM 202 (dns,dhcp) and VM 201 (dns,ntp), both built then
  torn down completely, with a second host provably untouched each time.
- One host is currently live (see `./niosx list`) running DNS + DHCP. Leave it up.
- Next VMID is 205 (never-reuse counter at /etc/niosx/last_vmid on the Proxmox host).
- 2026-09-02: interactive path driven through a real pty at last (39 assertions in
  tests/), which turned up a command injection through the Name prompt — a name of
  x;reboot ran `reboot` as root on the Proxmox host. Fixed, plus --resume, live
  service validation, tenant-wide name check, enforced OWNER, and the teardown
  journal is finally read. See "Fixed on 2026-09-02" in HANDOFF.md.

REMAINING WORK, most valuable first
1. --resume has never finished a genuinely half-built VM. Every shape is covered
   by stubbed tests; kill a real deploy after `qm create` and resume it.
2. Windows is documented as WSL2-only and the two known traps (CRLF config,
   spaces in the image filename) are now handled and tested, but nobody has run
   any of it on Windows. Needs a real machine.
3. `./niosx add` is not covered by the test suite: it writes
   terraform/niosx_hosts.json at a fixed path, so a test would touch the real
   file. Give it a NIOSX_HOSTS_JSON override, then test the wait/rename/apply path.
4. The tenant name check uses `_filter=display_name=="..."` on detail_hosts. If
   the API does not support that filter it prints "name check: skipped" — confirm
   against the live tenant which branch actually runs.
5. HANDOFF.md carried a real internal IP until 2026-09-02. It is gone from the
   working tree but still in git history (commit c657dbe) of a PUBLIC repo.
   Decide: leave it (RFC1918, low value) or rewrite history.

HARD-WON FACTS — do not relearn these (all verified against the live API)
- NEVER set an SMBIOS serial. A made-up serial makes the appliance wait to be
  claimed as purchased hardware; it never uses the join token and never dials CSP,
  with no error anywhere. No serial = registers in ~100 seconds.
- Two different secrets: the join token ends in .ibjt (Portal > System >
  Administration > Join Tokens) and is used by the appliance; the CSP API key
  (Portal > your name > API Keys) is used by Terraform. Swapped gives HTTP 401.
- pool_id is nested at detail_hosts[].pool.pool_id and returned bare; the provider
  requires it prefixed "infra/pool/<id>" or apply fails with "inconsistent result
  after apply".
- Hosts register under a generated name ZTP_<join-token-name>_<digits>. Match hosts
  by MAC using a server-side _filter, never by name, and never client-side paging:
  /api/infra/v1/hosts returned 101 records while detail_hosts returned 500+.
- A failed apply leaves resources tainted; `tofu untaint` rather than letting the
  next apply destroy and recreate live services.
- `qm destroy --purge` does NOT remove the seed ISO, which contains the join token.
- The prompts sit behind `[ -t 0 ]`, so a plain subprocess never reaches them.
  tests/harness.py drives a real pty. Do not "simplify" that away.

CONVENTIONS
- The repo is PUBLIC. No real IPs, MACs, tokens or pool ids in committed files.
  config.env, terraform/secrets.auto.tfvars and terraform/niosx_hosts.json are
  gitignored and hold the real values.
- Proxmox host is in config.env, not in git.
- Use OpenTofu (`tofu`), not terraform.
- teardown is destructive: always --dry-run first. There is deliberately no --all
  and no --yes; --confirm "<exact host name>" is the scripted path.
- Anything a user types (VMID, name, label) is validated in lib.sh before it can
  reach a root shell on Proxmox, a Portal record or a regex. Add new input there.
- Every change to the scripts: run ./niosx test, and prove a new test fails when
  you break the behaviour on purpose. A green suite proves nothing by itself.
- This tooling is unrelated to the Home Assistant config repo at
  ~/AI/HomeSystems/config. Do not mix them. /whats-next is an HA skill and does not
  apply here.

A recurring failure mode in this codebase has been code that LOOKS like it works:
silent fallbacks, misleading success messages, an assertion comparing "None".
Test the actual code path, not the endpoint.
```
