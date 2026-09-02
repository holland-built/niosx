# Handoff — NIOS-X on Proxmox tooling

Status as of 2026-09-02. Repo: https://github.com/holland-built/niosx (public).

## What this is

One command builds an Infoblox NIOS-X On-Prem VM on Proxmox, lets it register
itself to the Infoblox Portal, renames it, and starts the services you choose.
Another removes all of it. Aimed at ~700 sales engineers sharing one CSP tenant.

```bash
./niosx deploy                     # prompts, then does everything
./niosx deploy --resume <vmid>     # finish a half-built node
./niosx add <vmid> <name> <svcs>   # add services to an existing host
./niosx teardown <vmid> --dry-run  # see what would go
./niosx list                       # your VMs vs Portal vs Terraform
./niosx test                       # stubbed suite: no host, no tenant
```

## Verified working

| Path | Evidence |
|------|----------|
| Deploy → register → rename → services | VM 203 (`dns,dhcp`), VM 201 (`dns,ntp`) |
| Teardown | VM 202 and VM 201, both fully removed from Proxmox + Portal |
| Blast-radius isolation | tearing down one host left the other's VM, services, state and Portal record untouched |
| Never-reuse VMIDs | counter at 204 after 201/202/204 retired |
| **Interactive prompts + numbered menu** | 39 assertions in `tests/`, driven through a real pty |
| **`--resume`** | tested against every half-built shape (no disk, no seed, running, foreign VM) — stubbed, not yet on real hardware |

Currently live: `sholland-203` running DNS + DHCP (`./niosx list` for its IP).

## Hard-won facts (do not relearn these)

- **Never set an SMBIOS serial.** A made-up serial makes the appliance wait to
  be claimed as purchased hardware; it never uses the join token and never dials
  CSP, with no error anywhere. No serial = registers in ~100s.
- **Two different secrets.** Join token (ends `.ibjt`, from System >
  Administration > Join Tokens) is used by the appliance to enrol. The CSP API
  key (your name > API Keys) is used by Terraform. Swapped = HTTP 401.
- **`pool_id` is nested** at `detail_hosts[].pool.pool_id` and comes back bare;
  the provider needs it prefixed as `infra/pool/<id>` or apply fails with
  "inconsistent result after apply".
- **Hosts register under a generated name** `ZTP_<join-token-name>_<digits>`.
  Match hosts by MAC, not name. Name your join token after yourself.
- **`/api/infra/v1/hosts` is not the full picture** — it returned 101 records
  while `detail_hosts` returned 500+. Use `detail_hosts` with a server-side
  `_filter`, not client-side paging.
- **A tainted resource after a failed apply** will be destroyed and recreated by
  the next apply. `tofu untaint` instead.
- **`--purge` does not remove the seed ISO**, which contains the join token.
- **The prompts are behind `[ -t 0 ]`.** A plain `subprocess` never reaches
  them; that is why they went untested for so long. `tests/harness.py` uses a
  pty. Do not "simplify" that away.

## Fixed on 2026-09-02

| Was | Now |
|-----|-----|
| A VM name went unvalidated and unquoted into `qm create` over ssh — `x;reboot` ran `reboot` as root on the Proxmox host | names are `[A-Za-z0-9-]`, checked before anything ships, and quoted in the remote command |
| `--services` was validated against a hardcoded 2026-09-02 snapshot | validated against the live tenant; the snapshot is a labelled fallback |
| The host name was only unique by convention | checked against the tenant before the build; a clash refuses |
| `OWNER` uniqueness was documented, not enforced | generic and malformed values are refused |
| VMID `7` was accepted and failed after a multi-GB upload | must be 100-999999999, checked up front |
| The teardown journal was written and never read | reported on the next teardown, and by `./niosx list` |
| A failed deploy left a VM you could only delete | `./niosx deploy --resume <vmid>` |
| The host name was spliced into JSON for the CSP rename | built with `json.dumps` |
| CRLF in `config.env` failed three steps later, unrecognisably | named at startup |

## Known gaps

| Gap | Note |
|-----|------|
| Windows | hardened for WSL2 and covered by tests for the two known traps (CRLF, spaces in the image name), but never actually run on Windows |
| `--resume` on real hardware | every shape is covered by stubbed tests; it has not yet finished a genuinely half-built VM |
| Service names | services are `<host>-<svc>`, so they are unique once the host name is. Not separately checked |

## Where things live

| Path | What |
|------|------|
| `config.env` | your settings + join token (gitignored) |
| `~/.config/niosx/jointoken` | alternative token location |
| `terraform/secrets.auto.tfvars` | CSP API key (gitignored) |
| `terraform/niosx_hosts.json` | which hosts/services you manage (gitignored, per-user) |
| `/etc/niosx/last_vmid` (Proxmox) | never-reuse VMID counter |
| `~/.config/niosx/teardown/<vmid>.json` | journal of a teardown in progress |
| `lib.sh` | shared validators (names, VMIDs, OWNER, CRLF) |
| `tests/` | stubbed suite; `./niosx test` |

## If you pick this up

Start with `./niosx test` — 30 seconds, proves the tooling still works without
touching anything. Then `./niosx list`, which shows whether Proxmox, the Portal
and Terraform agree. Always `--dry-run` a teardown first.
