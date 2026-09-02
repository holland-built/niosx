# CSP API key comes from secrets.auto.tfvars (gitignored) or env TF_VAR_infoblox_api_key.
provider "bloxone" {
  csp_url = var.csp_url
  api_key = var.infoblox_api_key
}
