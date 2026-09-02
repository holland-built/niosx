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
# Services: after the host registers, the chosen services are started via
# terraform/. Interactively you are prompted with the list of services this
# tenant supports (fetched live from the API); otherwise pass the flag:
#     ./deploy-niosx.sh --services dns,dhcp
#     ./deploy-niosx.sh --services none      # build the VM, start nothing
#
# Naming: OWNER in config.env prefixes everything, so in a shared CSP tenant
# your objects are obvious: VM/host <owner>-<vmid>, services <owner>-<vmid>-dns.
#
# Networking: the appliance leases via DHCP on the chosen bridge and needs
# outbound HTTPS/443 to csp.infoblox.com. For a static IP instead, see README
# (add a cloud-init network-config).
set -euo pipefail

# --help must work on a fresh clone, before config.env exists
case "${1:-}" in -h|--help) sed -n '2,29p' "$0"; exit 0 ;; esac

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
: "${OWNER:?set OWNER in config.env (prefix for CSP object names)}"
RAM=${RAM:-4096}                                        # MB  (Infoblox floor = 4 GB)
CORES=${CORES:-3}                                       # Infoblox floor = 3 vCPU
DISK=${DISK:-64G}                                       # Infoblox floor = 64 GB (thin)

# ---- flags (before positionals) ----
SERVICES=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --services)
      [ $# -ge 2 ] || { echo "!! --services needs a value, e.g. --services dns,dhcp" >&2; exit 1; }
      case "$2" in -*) echo "!! --services needs a value, got '$2'" >&2; exit 1 ;; esac
      SERVICES=$2; shift 2 ;;
    --services=*) SERVICES=${1#*=}; shift ;;
    -h|--help)    sed -n '2,29p' "$0"; exit 0 ;;
    --)           shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*)           echo "!! unknown option: $1  (try --help)" >&2; exit 1 ;;
    *)            ARGS+=("$1"); shift ;;
  esac
done
if [ ${#ARGS[@]} -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

# ---- preflight: fail before shipping a multi-GB image ----
for t in ssh rsync curl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "!! missing required tool: $t (see README > Prerequisites)" >&2; exit 1; }
done
[ -f "$IMG" ] || { echo "!! qcow2 not found: $IMG   (set IMG in config.env)" >&2; exit 1; }

VMID=${1:-}                                             # arg1 = explicit VMID; empty => auto-allocate (never reuse)
NAME=${2:-}                                             # arg2; defaults to nios-x-<vmid> once VMID resolved
TOKEN_FILE=${NIOSX_TOKEN_FILE:-$HOME/.config/niosx/jointoken}  # reusable token, outside git (mode 600)
JOINTOKEN=${3:-$(tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null || true)}   # arg3, else stored token (CR/LF stripped)

REMOTE=/var/lib/vz/template/qcow
BASENAME=$(basename "$IMG")

# NOTE: do NOT set an SMBIOS serial. Infoblox uses serial numbers for ZTP of
# *purchased hardware*; a made-up serial makes the appliance wait to be claimed
# as hardware and it never uses the join token — it won't even dial CSP.
# Verified: identical VM registered in ~100s with no serial, and never
# registered with serial=NIOSX-<vmid>. Removing the serial fixed it immediately.

# ---- which services to start once it registers? ----
if [ -z "$SERVICES" ] && [ -t 0 ]; then
  # live list of services this tenant supports
  APPS=$(sed -nE 's/^[[:space:]]*infoblox_api_key[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' \
           "$HERE/terraform/secrets.auto.tfvars" 2>/dev/null | tail -1 \
         | { read -r k; [ -n "$k" ] && curl -s --max-time 20 -H "Authorization: Token $k" \
             https://csp.infoblox.com/api/infra/v1/applications; } \
         | python3 -c 'import sys,json;print(",".join(json.load(sys.stdin).get("results",{}).get("applications",[])))' 2>/dev/null || true)
  if [ -z "$APPS" ]; then
    # Fallback only — snapshot of /api/infra/v1/applications on 2026-09-02.
    # May be stale; the live fetch above is authoritative.
    APPS="dfp,dns,dhcp,cdc,anycast,orpheus,msad,authn,ntp,discovery,dgw"
    echo "!! could not reach the CSP applications API — showing a cached list"
    echo "   (snapshot 2026-09-02; may be out of date)"
  fi
  echo
  echo "Services available in this tenant:"
  echo "   $APPS"
  echo
  echo "Which should run on the new host?  (comma-separated, or 'none')"
  printf 'services [dns,dhcp]: '
  read -r choice || choice=""
  SERVICES=${choice:-dns,dhcp}
fi
SERVICES=${SERVICES:-none}
SERVICES=$(printf '%s' "$SERVICES" | tr -d '[:space:]')
if [ "$SERVICES" != "none" ]; then
  [ -n "${APPS:-}" ] || APPS="dfp,dns,dhcp,cdc,anycast,orpheus,msad,authn,ntp,discovery,dgw"
  for want in $(printf '%s' "$SERVICES" | tr ',' ' '); do
    case ",$APPS," in
      *",$want,"*) ;;
      *) echo "!! '$want' is not a service this tenant offers." >&2
         echo "   valid: $APPS" >&2; exit 1 ;;
    esac
  done
fi
echo ">> services: $SERVICES"

# join token must actually look like a join token
if [ -n "$JOINTOKEN" ]; then
  case "$JOINTOKEN" in
    *.ibjt) ;;
    *) echo "!! that does not look like a join token (should end in .ibjt)." >&2
       echo "   Get one: Portal > System > Administration > Join Tokens" >&2; exit 1 ;;
  esac
fi

# if we will start services, prove the CSP API key works BEFORE the big upload
if [ "$SERVICES" != "none" ]; then
  command -v tofu >/dev/null 2>&1 || { echo "!! missing required tool: tofu (brew install opentofu)" >&2; exit 1; }
  SEC=$HERE/terraform/secrets.auto.tfvars
  if [ ! -f "$SEC" ]; then
    echo "!! missing $SEC" >&2
    echo "   cp terraform/secrets.auto.tfvars.example terraform/secrets.auto.tfvars, then add your CSP API key" >&2
    exit 1
  fi
  K=$(sed -nE 's/^[[:space:]]*infoblox_api_key[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "$SEC" | tail -1 | tr -d '\r')
  case "$K" in
    ""|REPLACE_WITH_CSP_API_KEY)
      echo "!! $SEC still has the placeholder — paste your CSP API key" >&2
      echo "   Portal > your name (top-right) > API Keys" >&2; exit 1 ;;
    *.ibjt)
      echo "!! $SEC contains a JOIN TOKEN (it ends in .ibjt), not an API key." >&2
      echo "   Join token belongs in : $TOKEN_FILE" >&2
      echo "   API key comes from    : Portal > your name (top-right) > API Keys" >&2; exit 1 ;;
  esac
  rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Token $K" \
        https://csp.infoblox.com/api/infra/v1/applications || echo 000)
  if [ "$rc" != "200" ]; then
    echo "!! CSP rejected the API key (HTTP $rc)." >&2
    echo "   Regenerate: Portal > your name (top-right) > API Keys" >&2; exit 1
  fi
  echo ">> CSP API key OK"
fi

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
NAME=${NAME:-$OWNER-$VMID}

echo ">> 1/6  Ship image Mac -> Proxmox"
ssh "$PVE" "mkdir -p $REMOTE"
rsync -aP "$IMG" "$PVE:$REMOTE/$BASENAME"

echo ">> 2/6  Build VM $VMID"
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
echo ">> 3/6  Import disk (thin zvol on $POOL)"
qm importdisk $VMID "$REMOTE/$BASENAME" $POOL
qm set $VMID --scsi0 $POOL:vm-$VMID-disk-0,discard=on,ssd=1
qm set $VMID --boot order=scsi0
qm resize $VMID scsi0 $DISK
zfs get -H used,volsize,refreservation rpool/data/vm-$VMID-disk-0 || true
EOF

if [ -n "$JOINTOKEN" ]; then
  echo ">> 4/6  Build cloud-init join seed + attach (auto-register to CSP)"
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
echo ">> 5/6  Start $VMID (leases DHCP, then registers to CSP)"
qm start $VMID
EOF
  echo ">> VM $VMID starting + auto-registering."
  if [ "$SERVICES" != "none" ]; then
    echo ">> 6/6  Wiring services once it registers"
    "$HERE/wire-services.sh" "$VMID" "$NAME" "$SERVICES"
    echo ">> DONE. $NAME deployed and running: $SERVICES"
  else
    echo ">> DONE. VM started. Registration happens on its own (~2-3 min) - not verified here."
    echo "   Start some later: ./wire-services.sh $VMID $NAME dns,dhcp"
  fi
else
  echo ">> 4/6  No join token given — VM built + STOPPED. Start with: qm start $VMID"
  echo ">> To join later: re-run with the token as arg3, or attach a seed manually (see README)."
fi
