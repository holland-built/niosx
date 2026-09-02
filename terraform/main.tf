# Adopt each already-joined host by display_name. retry_if_not_found waits for the
# appliance to finish registering (handy right after the deploy script boots it).
data "bloxone_infra_hosts" "niosx" {
  for_each = var.niosx_hosts
  filters  = { display_name = each.key }
  # true makes a miss retry for the full read timeout (20m) and hides real
  # errors. Keep false so failures surface fast; flip on only if you apply
  # immediately after a deploy and want to wait for registration to land.
  retry_if_not_found = false
}

# Flatten { host => {services=[...]} } into { "host-svc" => {host, service} }.
locals {
  host_services = merge([
    for hname, cfg in var.niosx_hosts : {
      for svc in cfg.services :
      "${hname}-${svc}" => { host = hname, service = svc }
    }
  ]...)
}

# Start the requested services on each host's pool.
resource "bloxone_infra_service" "svc" {
  for_each       = local.host_services
  name           = each.key
  service_type   = each.value.service
  pool_id        = data.bloxone_infra_hosts.niosx[each.value.host].results[0].pool_id
  desired_state  = "start"
  wait_for_state = true

  tags = {
    managed_by = "terraform"
    host       = each.value.host
  }
}
