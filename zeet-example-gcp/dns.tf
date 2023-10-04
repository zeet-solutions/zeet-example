locals {
  domain    = var.cluster_domain
  zone_name = "zeet-${var.cluster_name}"
}

module "dns" {
  source  = "terraform-google-modules/cloud-dns/google"
  version = "3.0.0"

  project_id  = var.project_id
  name        = local.zone_name
  description = "Managed by Zeet"
  type        = "public"
  domain      = "${local.domain}."
}