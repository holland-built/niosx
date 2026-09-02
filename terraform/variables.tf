variable "infoblox_api_key" {
  description = "Infoblox CSP API key (Portal > your user > API Keys). Put in secrets.auto.tfvars (gitignored)."
  type        = string
  sensitive   = true
}

variable "csp_url" {
  description = "Infoblox Cloud Services Portal base URL."
  type        = string
  default     = "https://csp.infoblox.com"
}

variable "hosts_file" {
  description = "Path to niosx_hosts.json. Empty = <module>/niosx_hosts.json. Set via NIOSX_HOSTS_JSON, which exports TF_VAR_hosts_file so the scripts and Terraform never read different files."
  type        = string
  default     = ""
}
