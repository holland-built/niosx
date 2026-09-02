# Handoff — NIOS-X on Proxmox tooling

Status as of 2026-09-02. Repo: https://github.com/holland-built/niosx (public).

## What this is

One command builds an Infoblox NIOS-X On-Prem VM on Proxmox, lets it register
itself to the Infoblox Portal, renames it, and starts the services you choose.
Another removes all of it. Aimed at ~700 sales engineers sharing one CSP tenant.

```bash
./niosx deploy                     # prompts, then does everything
./niosx add <vmid> <name> <svcs>   # add services to an existing host
./niosx teardown <vmid> --dry-run  # see what would go
./niosx list                       # your VMs vs Portal vs Terraform
```

## Verified working

| Path | Evidence |
|------|----------|
| Deploy → register → rename → services | VM 203 (`dns,dhcp`), VM 201 (`dns,ntp`) |
| Teardown | VM 202 and VM 201, both fully removed from Proxmox + Portal |
| Blast-radius isolation | tearing down one host left the other's VM, services, state and Portal record untouched |
| Never-reuse VMIDs | counter at 204 after 201/202/204 retired |

Currently live: `sholland-203` at 192.168.100.113 running DNS + DHCP.

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

## Known gaps

| Gap | Note |
|-----|------|
| Interactive prompts / numbered service menu | logic tested, but never driven from a real TTY — needs a human to eyeball |
| Windows | documented as WSL2-only; never actually run on Windows |
| Resume of a half-built VM | any failure after `qm create` leaves a VM that blocks re-runs; no `--resume` |
| `OWNER` uniqueness | documented, not enforced. Two people using the same OWNER collide on service names |
| Teardown journal | written but never read |

## Where things live

| Path | What |
|------|------|
| `config.env` | your settings + join token (gitignored) |
| `~/.config/niosx/jointoken` | alternative token location |
| `terraform/secrets.auto.tfvars` | CSP API key (gitignored) |
| `terraform/niosx_hosts.json` | which hosts/services you manage (gitignored, per-user) |
| `/etc/niosx/last_vmid` (Proxmox) | never-reuse VMID counter |

## If you pick this up

Start with `./niosx list` — it shows immediately whether Proxmox, the Portal and
Terraform agree. Then `./niosx deploy` for a new node. Always `--dry-run` a
teardown first.
