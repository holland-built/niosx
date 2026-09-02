# NIOS-X On-Prem on Proxmox — repeatable, hands-off deploy

Ships the Infoblox NIOS-X On-Prem qcow2 to a Proxmox host, builds a **thin** VM at
Infoblox minimum spec, sets the SMBIOS serial, and — given a join token — injects
it via **cloud-init** so the appliance **self-registers to the Infoblox Portal
(CSP)** on first boot. No console login required.

## Setup (once)

```bash
cp config.env.example config.env      # gitignored; your Proxmox host, storage, bridge
$EDITOR config.env

mkdir -p ~/.config/niosx
printf '%s\n' '<your-join-token>.ibjt' > ~/.config/niosx/jointoken
chmod 600 ~/.config/niosx/jointoken
```

Get the token: Infoblox Portal → **System > Administration > Join Tokens** → create
→ copy the `.ibjt` string. It's reusable, so you only do this once. Tokens are
secrets — never commit one. The script only ever embeds it in a seed ISO on the
Proxmox host.

## Deploy each time

```bash
./deploy-niosx.sh                                    # AUTO vmid + join + start (no args)
./deploy-niosx.sh 210 dns-edge                       # pin a specific vmid + name
./deploy-niosx.sh 210 nios-x-210 dXMt....ibjt        # override token explicitly
```

| Arg | Meaning | Default |
|-----|---------|---------|
| 1 | VMID | **auto** — never-reuse high-water mark (see below) |
| 2 | VM name | `nios-x-<vmid>` |
| 3 | **Join token** (`.ibjt`) | stored token file → else none = build only |

- Token file: `~/.config/niosx/jointoken`. Override the path with `NIOSX_TOKEN_FILE`.
- Config file: `config.env`. Override the path with `NIOSX_CONFIG`.
- Image lives on the Proxmox host after the first run; `rsync` skips re-copy unless it changed.
- Token present (stored or arg3): seed built + attached, VM **started**, registers itself.
- No token at all: VM built **stopped** — join later by re-running with the token.

### VMID allocation — never reuse

No VMID arg → the script asks the host for the next id from a **high-water mark**
at `/etc/niosx/last_vmid` (seed 200). It only ever climbs: delete 203 and the next
deploy is still **205**, not 203 — even if you delete the highest id. Occupied ids
are skipped. Pin an explicit id with arg1 to bypass.

### CSP-side config (services) → Terraform

Adopting the host + starting DNS/DHCP lives in [`terraform/`](terraform/README.md)
(`infobloxopen/bloxone` provider). Flow: `./deploy-niosx.sh` (host joins CSP) →
`cd terraform && tofu apply` (start services).

## How the automation works

| Step | What happens |
|------|--------------|
| SMBIOS serial | set to `NIOSX-<vmid>` at build (base64-encoded for `qm`) — Device-UI identity |
| Disk | 64 GB **thin** volume (qcow virtual ~58.6 G, real ~2.4 G at first boot) |
| Join (cloud-init) | seed ISO labelled `cidata` with `user-data` → `host_setup: jointoken:` |
| Network | **DHCP** on the configured bridge; appliance leases automatically |
| Register | appliance dials out HTTPS/443 to `csp.infoblox.com` with the token |

## Requirements

| Need | Why |
|------|-----|
| Proxmox host, ssh key auth | `qm` build commands |
| Storage that accepts VM images **and** is thin | 64 GB declared, ~2.4 GB real. A zfspool with `sparse 1` works; a plain `dir` store often refuses images entirely |
| `genisoimage` on the Proxmox host | builds the cloud-init seed |
| DHCP on the bridge + outbound 443 to `csp.infoblox.com` | appliance self-registration |

## Verify it registered

| Check | How |
|-------|-----|
| Host appears | CSP → **Infrastructure > Hosts** → look for `nios-x-<vmid>` |
| Leased IP | on the Proxmox host, ping-sweep the subnet then `ip neigh \| grep -i <vm-mac>` |
| Device UI up | `https://<leased-ip>` returns 200 |

## Console access (if you must)

The only console is serial (`--vga serial0`). Login is **`admin`**, initial password
= **last 8 chars of the appliance's `ophid`** — **not** root. From the Proxmox host
you can read the console without the Proxmox UI:

```bash
{ printf "\n"; sleep 1; } | socat -T3 - UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0
```

You shouldn't need this — the cloud-init join is the supported path.

## Static IP instead of DHCP

Add a `network-config` (cloud-init v2) to the seed before `genisoimage`:

```yaml
version: 2
ethernets:
  nic0:
    match: { macaddress: "<vm-mac>" }
    addresses: [<ip>/<prefix>]
    gateway4: <gateway>
    nameservers: { addresses: [<dns1>, <dns2>] }
```

DHCP is the tested path here and is simplest.

## Specs (Infoblox floor, smallest 5 kQPS tier)

| Resource | Value |
|----------|-------|
| RAM | 4096 MB (balloon on) |
| vCPU | 3 |
| Disk | 64 GB thin |
| NIC | 1 × virtio |
| Machine | q35, serial console |

Below 4 GB / 3 vCPU / 64 GB is under Infoblox's documented minimum. Thin
provisioning is what makes the 64 GB affordable — real usage starts around 2.4 GB
and grows on demand.

## Notes

- A host that has already registered keeps its identity; changing its SMBIOS serial
  afterwards re-identifies it in CSP. Set the serial at build time (this script does).
- The qcow2's virtual size is ~58.6 GB; the script grows it to 64 GB, still sparse.
