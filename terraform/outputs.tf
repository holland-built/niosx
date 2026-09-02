output "adopted_hosts" {
  description = "Adopted NIOS-X hosts: display_name => key facts."
  value = {
    for hname, d in data.bloxone_infra_hosts.niosx :
    hname => {
      id            = try(d.results[0].id, null)
      ophid         = try(d.results[0].ophid, null)
      serial_number = try(d.results[0].serial_number, null)
      ip_address    = try(d.results[0].ip_address, null)
      pool_id       = try(d.results[0].pool_id, null)
    }
  }
}

output "started_services" {
  description = "Services started, key => service_type."
  value       = { for k, s in bloxone_infra_service.svc : k => s.service_type }
}
