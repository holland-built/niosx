#!/usr/bin/env bash
# Repeatable NIOS-X (Infoblox On-Prem) deploy to Proxmox — fully hands-off.
# Ships qcow2 Mac -> Proxmox, builds a thin VM at Infoblox min spec and — if a
# join token is given — builds a cloud-init seed so the appliance self-registers
# to the Infoblox Portal (CSP) on first boot. No console login needed.
#
# Usage:
#   ./deploy-niosx.sh [VMID] [NAME] [JOINTOKEN]
#   VMID auto-allocates from a never-reuse high-water mark on the host
#   (/etc/niosx/last_vmid, seed 200) — delete 203 and the next is still 205, not 203.
#   Reusable join token is stored once at ~/.config/niosx/jointoken (mode 600,
#   outside git), so a normal deploy needs NO args and self-registers:
#     ./deploy-niosx.sh                      # auto VMID, build + join + start
#     ./deploy-niosx.sh 210 edge-dns         # pin a specific VMID + name
#     ./deploy-niosx.sh 210 edge-dns dXMt....ibjt   # override token explicitly
#   No stored token + no arg3 => VM built + STOPPED, no join.
#
# Networking: the appliance leases via DHCP on the chosen bridge and needs
# outbound HTTPS/443 to csp.infoblox.com. For a static IP instead, see README
# (add a cloud-init network-config).
set -euo pipefail

# ---- environment: copy config.env.example -> config.env and fill it in ----
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${NIOSX_CONFIG:-$HERE/config.env}
if [ ! -f "$CONFIG" ]; then
  echo "!! missing $CONFIG" >&2
  echo "   run: cp $HERE/config.env.example $HERE/config.env   then edit it" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG"           # PVE, IMG, POOL, BRIDGE, and optional RAM/CORES/DISK

: "${PVE:?set PVE in config.env}"
: "${IMG:?set IMG in config.env}"
: "${POOL:?set POOL in config.env}"
: "${BRIDGE:?set BRIDGE in config.env}"
RAM=${RAM:-4096}                                        # MB  (Infoblox floor = 4 GB)
CORES=${CORES:-3}                                       # Infoblox floor = 3 vCPU
DISK=${DISK:-64G}                                       # Infoblox floor = 64 GB (thin)

VMID=${1:-}                                             # arg1 = explicit VMID; empty => auto-allocate (never reuse)
NAME=${2:-}                                             # arg2; defaults to nios-x-<vmid> once VMID resolved
TOKEN_FILE=${NIOSX_TOKEN_FILE:-$HOME/.config/niosx/jointoken}  # reusable token, outside git (mode 600)
JOINTOKEN=${3:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}       # arg3, else stored token. Empty => build only

REMOTE=/var/lib/vz/template/qcow
BASENAME=$(basename "$IMG")

# NOTE: do NOT set an SMBIOS serial. Infoblox uses serial numbers for ZTP of
# *purchased hardware*; a made-up serial makes the appliance wait to be claimed
# as hardware and it never uses the join token — it won't even dial CSP.
# Verified: identical VM registered in ~100s with no serial, and never
# registered with serial=NIOSX-<vmid>. Removing the serial fixed it immediately.

# ---- allocate VMID: never-reuse high-water mark on the Proxmox host ----
# (single-quoted remote script; $(), $(()) etc. evaluate ON the host)
if [ -z "$VMID" ]; then
  VMID=$(ssh "$PVE" '
    mkdir -p /etc/niosx
    exec 9>/etc/niosx/.vmid.lock; flock 9          # serialize concurrent deploys
    last=$(cat /etc/niosx/last_vmid 2>/dev/null || echo 200)
    case "$last" in ""|*[!0-9]*) last=200 ;; esac
    [ "$last" -ge 200 ] || last=200
    n=$((last + 1))
    while qm status "$n" >/dev/null 2>&1; do n=$((n + 1)); done   # skip occupied ids
    printf "%s\n" "$n" > /etc/niosx/last_vmid
    printf "%s\n" "$n"
  ')
  echo ">> allocated VMID $VMID (high-water mark — freed ids never reused)"
fi
NAME=${NAME:-nios-x-$VMID}

echo ">> 1/5  Ship image Mac -> Proxmox"
ssh "$PVE" "mkdir -p $REMOTE"
rsync -aP "$IMG" "$PVE:$REMOTE/$BASENAME"

echo ">> 2/5  Build VM $VMID"
ssh "$PVE" bash -s <<EOF
set -euo pipefail
if qm status $VMID >/dev/null 2>&1; then
  echo "!! VMID $VMID already exists. Pick another VMID." >&2; exit 1
fi
qm create $VMID --name $NAME --machine q35 --ostype l26 \
  --memory $RAM --balloon $RAM --cores $CORES \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=$BRIDGE \
  --serial0 socket --vga serial0
echo ">> 3/5  Import disk (thin zvol on $POOL)"
qm importdisk $VMID "$REMOTE/$BASENAME" $POOL
qm set $VMID --scsi0 $POOL:vm-$VMID-disk-0,discard=on,ssd=1
qm set $VMID --boot order=scsi0
qm resize $VMID scsi0 $DISK
zfs get -H used,volsize,refreservation rpool/data/vm-$VMID-disk-0 || true
EOF

if [ -n "$JOINTOKEN" ]; then
  echo ">> 4/5  Build cloud-init join seed + attach (auto-register to CSP)"
  ssh "$PVE" bash -s <<EOF
set -euo pipefail
D=/tmp/niosx-seed-$VMID; rm -rf "\$D"; mkdir -p "\$D"; cd "\$D"
cat > user-data <<YAML
#cloud-config
host_setup:
  jointoken: "$JOINTOKEN"
YAML
cat > meta-data <<YAML
instance-id: niosx-$VMID-\$(date +%s)
local-hostname: $NAME
YAML
genisoimage -quiet -output /var/lib/vz/template/iso/seed-niosx-$VMID.iso -volid cidata -joliet -rock user-data meta-data
qm set $VMID --ide2 local:iso/seed-niosx-$VMID.iso,media=cdrom
echo ">> 5/5  Start $VMID (leases DHCP from .6, registers to CSP)"
qm start $VMID
EOF
  echo ">> DONE. VM $VMID starting + auto-registering. Confirm in CSP: Infrastructure > Hosts."
else
  echo ">> 4/5  No join token given — VM built + STOPPED. Start with: qm start $VMID"
  echo ">> To join later: re-run with the token as arg3, or attach a seed manually (see README)."
fi
