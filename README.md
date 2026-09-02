# NIOS-X On-Prem on Proxmox

One command builds a NIOS-X On-Prem VM on Proxmox, lets it self-register to the
Infoblox Portal, renames it to something you can find, and starts the services
you pick.

**Result:** a host named `<you>-<vmid>` in **Infrastructure > Hosts**, running
DNS/DHCP, in about 5–10 minutes. No console login anywhere.

## Prerequisites

| Where | Needs |
|-------|-------|
| Your machine | `ssh` `rsync` `curl` `python3` and [OpenTofu](https://opentofu.org) (`tofu`) |
| macOS | `brew install opentofu` |
| Linux | `apt install -y rsync python3 curl` + OpenTofu install script |
| **Windows** | **WSL2 (Ubuntu) only** — see below |
| Proxmox host | root SSH by key; `genisoimage` (`apt install -y genisoimage`); a storage named `local` with ISO content |
| Storage for VMs | **must be `zfspool` or `lvmthin`** — `dir`/NFS will not work (volume naming differs) |
| Network | DHCP on the bridge, and outbound **443 to csp.infoblox.com** from the VM |
| Portal | a join token and an API key (below) |

### Windows

Use **WSL2 with Ubuntu**. Git Bash and PowerShell are *not* supported (no
`rsync`, no `python3`, path and permission differences).

```bash
wsl --install                      # PowerShell as admin, then reboot
# inside Ubuntu:
sudo apt update && sudo apt install -y git rsync python3 curl openssh-client
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method deb
ssh-keygen -t ed25519 && ssh-copy-id root@<proxmox-host>
git config --global core.autocrlf input
git clone https://github.com/holland-built/niosx ~/niosx && cd ~/niosx
```

- Clone into your Linux home (`~`), **not** `/mnt/c` — the qcow2 copy is far slower there.
- Your Windows downloads are at `/mnt/c/Users/<you>/Downloads/` — use that path for `IMG`.
- Create the token file with `printf` inside WSL; editing it in Notepad adds a CR that breaks registration.

## Setup (once)

| # | What | Where it goes | Get it from |
|---|------|---------------|-------------|
| 1 | Settings | `config.env` | copy the example, edit |
| 2 | **Join token** | `~/.config/niosx/jointoken` | Portal → **System > Administration > Join Tokens** |
| 3 | **CSP API key** | `terraform/secrets.auto.tfvars` | Portal → **your name (top-right) > API Keys** |

```bash
cp config.env.example config.env && nano config.env        # OWNER, PVE, IMG, POOL, BRIDGE

mkdir -p ~/.config/niosx
printf '%s\n' 'PASTE-JOIN-TOKEN.ibjt' > ~/.config/niosx/jointoken
chmod 600 ~/.config/niosx/jointoken

cp terraform/secrets.auto.tfvars.example terraform/secrets.auto.tfvars
nano terraform/secrets.auto.tfvars                          # infoblox_api_key = "PASTE-API-KEY"

cd terraform && tofu init && cd ..
```

### The two secrets are different things

People mix these up constantly. The scripts now refuse the swap, but know the difference:

| | Join token | CSP API key |
|---|---|---|
| Looks like | long string **ending in `.ibjt`** | long string, no `.ibjt` |
| Portal page | System > Administration > **Join Tokens** | your name (top-right) > **API Keys** |
| Used by | the appliance, once, to enrol itself | Terraform, every run, acting as you |
| Goes in | `~/.config/niosx/jointoken` | `terraform/secrets.auto.tfvars` |
| If swapped | join token used as API key → **HTTP 401** | API key used as join token → never registers |

Name your join token after yourself: for ~2 minutes before rename, the host is
called `ZTP_<token-name>_<digits>`.

Both files are gitignored — but gitignore only prevents accidents, not
`git add -f`, screenshots, or shell history. The join token is also written into
a seed ISO that stays on the Proxmox host.

## Deploy

```bash
./deploy-niosx.sh                          # prompts for services, does everything
./deploy-niosx.sh --services dns,dhcp      # non-interactive
./deploy-niosx.sh --services none          # build the VM only
./deploy-niosx.sh 210 edge-dns             # pin a specific VMID and name
```

It lists what your tenant actually offers (live from `/api/infra/v1/applications`):

```
Services available in this tenant:
   dfp,dns,dhcp,cdc,anycast,orpheus,msad,authn,ntp,discovery,dgw

Which should run on the new host?  (comma-separated, or 'none')
services [dns,dhcp]:
```

Registration takes ~2–3 min, services ~3–5 min more; the script waits up to 30.
**Success:** the host appears in **Infrastructure > Hosts** as `<you>-<vmid>`.

## Add services to an existing host

```bash
./add-services.sh <vmid> <owner>-<vmid> dns,dhcp
```

## Naming in a shared tenant

Everything is prefixed with `OWNER` from `config.env`, because many people share
one Infoblox **tenant**:

| Object | Name |
|--------|------|
| Proxmox VM and CSP host | `<owner>-<vmid>` |
| Services | `<owner>-<vmid>-dns` |

Use your corporate login or initials — it **must be unique in the tenant**. Two
people using `lab` on different Proxmox hosts will collide on `lab-202-dns`.
Use your own API key, never a shared one, so actions stay attributable.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CSP rejected the API key (HTTP 401)` | join token in `secrets.auto.tfvars`, or a stale key | API key comes from **your name > API Keys** |
| `does not look like a join token` | API key in the token file | join token ends in `.ibjt` |
| `timed out waiting ... to register` | no DHCP lease, no outbound 443, or a CR in the token | check the VM got an IP; `tr -d '\r'` the token file |
| Registered but never finishes | an SMBIOS serial is set | never set one (see below) |
| `VMID already exists` | id in use | omit the VMID to auto-allocate |
| `genisoimage: command not found` | missing on Proxmox | `ssh root@<pve> apt install -y genisoimage` |
| `volume ... does not exist` after import | `POOL` is a `dir` store | use a `zfspool` or `lvmthin` storage |
| `inconsistent result after apply` | bare pool id | must be `infra/pool/<id>` |
| Deleted the VM, host still in Portal | orphaned record | Portal > Infrastructure > Hosts > Remove, or `DELETE /api/infra/v1/hosts/<id>` |

## Teardown

```bash
./teardown-niosx.sh <vmid>              # asks you to type the host name
./teardown-niosx.sh <vmid> --dry-run    # show what would go, change nothing
```

Removes, in this order: its services (via a Terraform plan that is checked to
touch **only** that host), the Portal host record, the Proxmox VM and disk, and
the seed ISO holding your join token. The VMID is retired and never reused.

Start with `--dry-run` — it prints exactly what will be destroyed. There is
deliberately **no `--all`** and no `--yes`; for scripting, `--confirm "<host
name>"` requires the exact name.

Do **not** use `tofu destroy` to remove one host: it destroys the services of
*every* host in your state. And do not `qm destroy` first — that orphans the
Portal record.

<details>
<summary><b>Reference — flags, VMID allocation, specs, console, static IP</b></summary>

### Arguments and flags

| Arg / flag | Meaning | Default |
|------------|---------|---------|
| 1 | VMID | auto (never-reuse counter) |
| 2 | VM name | `<owner>-<vmid>` |
| 3 | join token | the stored token file |
| `--services dns,dhcp` | start these; skips the prompt | prompts |
| `--services none` | build the VM only | |

### VMID allocation — never reuse

With no VMID argument the next id comes from a high-water mark at
`/etc/niosx/last_vmid` on the Proxmox host (seed 200). It only climbs: delete
203 and the next deploy is still 205 — even if you delete the highest id.
Occupied ids are skipped. An explicit VMID bypasses the counter entirely.

### Specs (Infoblox floor — smallest 5 kQPS tier)

4096 MB RAM (balloon) · 3 vCPU · 64 GB **thin** disk · 1 virtio NIC · q35 ·
serial console. Real disk use starts ~2.4 GB and grows. Anything smaller is
below Infoblox's documented minimum. Override `RAM`/`CORES`/`DISK` in `config.env`.

### ⚠️ Never set an SMBIOS serial

Infoblox uses serial numbers to zero-touch-provision *purchased hardware*. Give a
VM a made-up serial and the appliance waits to be claimed as hardware — it never
uses the join token and never dials CSP, with no error anywhere.

| SMBIOS serial | Result |
|---------------|--------|
| none | registered in ~100 seconds |
| made-up value | no outbound 443 at all, never registered |
| removed, rebooted | dialled CSP immediately |

The script sets none. The trade-off: the console password is derived from the
serial, so there isn't one — manage via Portal/API, which is the supported path.

### Console

Serial only, and with no serial number there is no derivable password. To read
raw console output from the Proxmox host:

```bash
{ printf "\n"; sleep 1; } | socat -T3 - UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0
```

### Static IP instead of DHCP

**Not implemented by the script** — DHCP is the tested path. To do it by hand,
add a cloud-init v2 `network-config` to the seed before `genisoimage`:

```yaml
version: 2
ethernets:
  nic0:
    match: { macaddress: "<vm-mac>" }
    addresses: [<ip>/<prefix>]
    gateway4: <gateway>
    nameservers: { addresses: [<dns1>, <dns2>] }
```

</details>
