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

# Which already-joined NIOS-X hosts to adopt, and which services to start on each.
# The host self-joins via the deploy script's cloud-init token; Terraform only
# looks it up by display_name and starts services — it does NOT create the host.
variable "niosx_hosts" {
  description = "map of display_name => { services = [\"dns\",\"dhcp\",...] }"
  type = map(object({
    services = list(string)
  }))
  default = {
    "nios-x-201" = { services = ["dns", "dhcp"] }
  }
}
