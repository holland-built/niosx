# NIOS-X CSP config — Terraform (Universal DDI / bloxone provider)

Adopts the NIOS-X hosts that self-joined via the deploy script's cloud-init token
and **starts services** (DNS/DHCP) on them. Terraform does **not** create the host
— the appliance joins itself; this just looks it up by `display_name` and turns
services on, as declarative state you can `plan`/`destroy`.

## One-time setup

```bash
cd terraform
cp secrets.auto.tfvars.example secrets.auto.tfvars   # gitignored
# edit secrets.auto.tfvars -> paste CSP API key (Portal > your user > API Keys)
tofu init
```

## Use

```bash
tofu plan
tofu apply        # starts DNS+DHCP on nios-x-201 (see variables.tf default)
terraform output       # host id/ophid/serial/ip + started services
```

## Add a host

Edit `niosx_hosts` (default in `variables.tf`, or copy `hosts.auto.tfvars.example`
→ `hosts.auto.tfvars`):

```hcl
niosx_hosts = {
  "nios-x-201" = { services = ["dns", "dhcp"] }
  "nios-x-202" = { services = ["dns"] }
}
```

`tofu apply` again. Remove a host from the map + apply = services stopped/removed.

## Secrets — what's where

| Secret | Used by | Location | In git? |
|--------|---------|----------|---------|
| CSP **API key** | Terraform → CSP | `secrets.auto.tfvars` | ❌ gitignored |
| **Join token** | appliance first boot | `~/.config/niosx/jointoken` (deploy script) | ❌ outside repo |

Terraform needs the **API key**, not the join token — different secrets. Keep the
API key in `secrets.auto.tfvars` (or `export TF_VAR_infoblox_api_key=...`). It is
**not** hardcoded in any `.tf` so a leaked repo doesn't leak your CSP tenant.

## Resources used

| Object | Terraform | Notes |
|--------|-----------|-------|
| Host lookup | `data.bloxone_infra_hosts` | filter `display_name`; `retry_if_not_found` waits for join |
| Service | `bloxone_infra_service` | `service_type` dns/dhcp/…, `desired_state = "start"` |

## Full flow

```
./deploy-niosx.sh            # build VM + cloud-init join (host appears in CSP)
cd terraform && tofu apply   # start DNS/DHCP on it
```
