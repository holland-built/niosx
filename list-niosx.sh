#!/usr/bin/env bash
# Read-only inventory: your Proxmox VMs, your Portal hosts, and your Terraform
# services — and anything that appears in one but not the others.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${NIOSX_CONFIG:-$HERE/config.env}
[ -f "$CONFIG" ] || { echo "!! missing $CONFIG" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONFIG"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
: "${PVE:?set PVE in config.env}"; : "${OWNER:?set OWNER in config.env}"
niosx_check_no_cr PVE OWNER
TF=$HERE/terraform; CSP=${CSP_URL:-https://csp.infoblox.com}
SEC=${NIOSX_SECRETS:-$TF/secrets.auto.tfvars}
JOURNAL_DIR=${NIOSX_STATE_DIR:-$HOME/.config/niosx/teardown}

KEY=$(sed -nE 's/^[[:space:]]*infoblox_api_key[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' \
        "$SEC" 2>/dev/null | tail -1 | tr -d '\r' || true)

echo "== Proxmox ($PVE) =="
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" bash -s -- "$OWNER" <<'EOS' 2>/dev/null
owner=$1
for c in /etc/pve/qemu-server/*.conf; do
  [ -e "$c" ] || continue
  id=$(basename "$c" .conf)
  n=$(sed -n "s/^name: //p" "$c")
  m=$(sed -nE "s/^net0:.*virtio=([0-9A-Fa-f:]{17}).*/\1/p" "$c" | tr "A-Z" "a-z")
  seed=no; grep -q "seed-niosx-$id.iso" "$c" 2>/dev/null && seed=yes
  mine=no; case "$n" in "$owner"-*) mine=yes ;; esac
  # a VM is ours if it carries our seed, or at least our name prefix
  [ "$seed" = yes ] || [ "$mine" = yes ] || continue
  note=""
  [ "$seed" = no ] && note="   <- no join seed: ./niosx deploy --resume $id"
  printf "  %-6s %-22s %-18s %s%s\n" "$id" "$n" "$m" "$(qm status $id 2>/dev/null | awk "{print \$2}")" "$note"
done
echo "  next VMID: $(( $(cat /etc/niosx/last_vmid 2>/dev/null || echo 200) + 1 ))"
EOS
then
  echo "  (cannot reach $PVE)"
fi

echo
echo "== Infoblox Portal (yours) =="
if [ -n "$KEY" ]; then
  curl -s --max-time 40 -H "Authorization: Token $KEY" "$CSP/api/infra/v1/detail_hosts?_limit=500" \
  | python3 -c '
import sys,json
owner=sys.argv[1]
if not owner: print("  (OWNER not set)"); raise SystemExit
try: d=json.load(sys.stdin)
except Exception: print("  (Portal query failed)"); raise SystemExit
def mine(h):
    n = h.get("display_name") or ""
    # renamed hosts carry the owner prefix; un-renamed ZTP hosts carry the
    # join-token name, which is why the token should be named after you
    return n.startswith(owner + "-") or (n.startswith("ZTP_") and owner in n)
rows=[h for h in d.get("results",[]) if mine(h)]
if not rows: print("  (none)")
for h in rows:
    svcs=",".join(sorted(c.get("service_type","") for c in (h.get("configs") or [])
                         if c.get("service_type") not in ("platform","appmgmt"))) or "-"
    print("  %-38s %-16s %-9s %s" % (h.get("display_name"), h.get("ip_address") or "?",
                                     h.get("composite_status"), svcs))
' "$OWNER"
else
  echo "  (no CSP API key configured)"
fi

echo
echo "== Terraform (your state) =="
if out=$(cd "$TF" && tofu state list 2>/dev/null); then
  printf '%s\n' "$out" | sed 's/^/  /' | grep . || echo "  (none)"
else
  echo "  (state unreadable — run 'tofu init' in terraform/)"
fi
echo
echo "== Interrupted teardowns =="
found=0
for j in "$JOURNAL_DIR"/*.json; do
  [ -e "$j" ] || continue
  found=1
  python3 - "$j" <<'PY'
import json, os, sys, time
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    d = {}
vmid = d.get("vmid") or os.path.basename(path)[:-5]
print("  vmid %-6s %-22s started %s" % (
    vmid, d.get("label") or "?",
    time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(path)))))
print("         finish it: ./niosx teardown %s" % vmid)
PY
done
if [ "$found" = 0 ]; then echo "  (none)"; fi

echo
echo "Orphans: a Portal host with no Proxmox VM needs './niosx teardown <vmid>'"
echo "or removal in the Portal. A ZTP_* name means it never got renamed."
echo "A VM with no join seed never registers — finish it with './niosx deploy --resume <vmid>'."
