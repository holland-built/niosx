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
