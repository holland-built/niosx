output "started_services" {
  description = "Services started: key => service_type."
  value       = { for k, s in bloxone_infra_service.svc : k => s.service_type }
}
