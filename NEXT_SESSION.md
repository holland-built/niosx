# Prompt for a fresh session

Paste everything in the block below into a new Claude Code session.

---

```
Work on the NIOS-X on Proxmox tooling at ~/AI/HomeSystems/niosx
(public repo: github.com/holland-built/niosx). Read HANDOFF.md and README.md first.

WHAT IT IS
One command builds an Infoblox NIOS-X On-Prem VM on Proxmox, lets it self-register
to the Infoblox Portal (CSP) via a cloud-init join token, renames it, and starts
chosen services via OpenTofu. Audience: ~700 Infoblox sales engineers sharing ONE
CSP tenant, mostly network people rather than developers.

  ./niosx deploy | add | teardown | list

DONE AND VERIFIED LIVE
- Full lifecycle twice: VM 202 (dns,dhcp) and VM 201 (dns,ntp), both built then
  torn down completely, with a second host provably untouched each time.
- One host is currently live (see `./niosx list`) running DNS + DHCP. Leave it up.
- Next VMID is 205 (never-reuse counter at /etc/niosx/last_vmid on the Proxmox host).
- Everything is committed and pushed; working tree clean.

REMAINING WORK, most valuable first
1. The interactive path has never been run from a real terminal. `./niosx deploy`
   with no args should prompt for VMID, name, then show a numbered menu of the
   services the tenant offers. Verify it renders and parses correctly (numbers and
   names both accepted). I could not test this — my tooling has no TTY.
2. Windows is documented as WSL2-only in README.md but has never actually been run
   on Windows. Validate or correct that section.
3. There is no --resume. Any failure after `qm create` leaves a VM behind; deploy
   now detects this early and prints the teardown command, but cannot continue a
   half-built node.
4. OWNER uniqueness is documented, not enforced. Two engineers both using OWNER=lab
   would collide on service names like lab-205-dns in the shared tenant.
5. teardown-niosx.sh writes a journal to ~/.config/niosx/teardown/<vmid>.json that
   nothing ever reads. Either use it to detect an interrupted run, or remove it.

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

CONVENTIONS
- The repo is PUBLIC. No real IPs, MACs, tokens or pool ids in committed files.
  config.env, terraform/secrets.auto.tfvars and terraform/niosx_hosts.json are
  gitignored and hold the real values.
- Proxmox host is in config.env, not in git.
- Use OpenTofu (`tofu`), not terraform.
- teardown is destructive: always --dry-run first. There is deliberately no --all
  and no --yes; --confirm "<exact host name>" is the scripted path.
- This tooling is unrelated to the Home Assistant config repo at
  ~/AI/HomeSystems/config. Do not mix them. /whats-next is an HA skill and does not
  apply here.

A recurring failure mode in this codebase has been code that LOOKS like it works:
silent fallbacks, misleading success messages, an assertion comparing "None".
Test the actual code path, not the endpoint.
```
