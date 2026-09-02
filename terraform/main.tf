# Hosts + services live in niosx_hosts.json so deploy-niosx.sh can update them
# safely. Shape: { "<label>": { "pool_id": "infra/pool/<id>", "services": [...] } }
#
# pool_id MUST be the fully-qualified "infra/pool/<id>". The API returns a bare
# id at detail_hosts[].pool.pool_id; the provider normalises to the prefixed form
# and errors with "inconsistent result after apply" if you pass the bare one.
locals {
  # Overridable so the scripts and the tests can point both halves at one file;
  # empty (the default) means the usual <module>/niosx_hosts.json.
  hosts_path = var.hosts_file != "" ? var.hosts_file : "${path.module}/niosx_hosts.json"

  # Absent on a fresh clone (it is gitignored, per-user) — treat as "no hosts".
  niosx_hosts = fileexists(local.hosts_path) ? jsondecode(file(local.hosts_path)) : {}

  host_services = merge([
    for label, cfg in local.niosx_hosts : {
      for svc in cfg.services :
      "${label}-${svc}" => { label = label, pool_id = cfg.pool_id, service = svc }
    }
  ]...)
}

resource "bloxone_infra_service" "svc" {
  for_each       = local.host_services
  name           = each.key
  service_type   = each.value.service
  pool_id        = each.value.pool_id
  desired_state  = "start"
  wait_for_state = true

  tags = {
    managed_by = "terraform"
    host       = each.value.label
  }
}
