terraform {
  required_version = "~> 1.1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.15.0"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 4.15.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

module "enables-google-apis" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "11.3.0"

  project_id = var.project_id

  activate_apis = [
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "containerregistry.googleapis.com",
    "container.googleapis.com",
    "storage-component.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "dns.googleapis.com",
    "tpu.googleapis.com",
  ]

  activate_api_identities = [
    {
      api   = "tpu.googleapis.com"
      roles = ["roles/viewer", "roles/storage.admin"]
    }
  ]

  disable_dependent_services  = false
  disable_services_on_destroy = false
}

module "gke_auth" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/auth"
  version = "~> 19.0"

  project_id   = var.project_id
  cluster_name = module.gke.name
  location     = module.gke.location

  depends_on = [module.gke]
}

resource "local_file" "kubeconfig" {
  content  = module.gke_auth.kubeconfig_raw
  filename = "kubeconfig_${var.cluster_name}"
}

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 4.1.0"

  project_id   = var.project_id
  network_name = "zeet-${var.cluster_name}"

  subnets = [
    {
      subnet_name   = "zeet-${var.cluster_name}-subnet-01"
      subnet_ip     = "10.0.0.0/19"
      subnet_region = var.region
      subnet_private_access = true
    }
  ]

  secondary_ranges = {
    "zeet-${var.cluster_name}-subnet-01" = [
      {
        range_name    = "zeet-${var.cluster_name}-subnet-01-pods"
        ip_cidr_range = "192.168.0.0/18"
      },
      {
        range_name    = "zeet-${var.cluster_name}-subnet-01-services"
        ip_cidr_range = "192.168.64.0/18"
      },
    ]
  }
}

# google_client_config and kubernetes provider must be explicitly specified like the following.
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

locals {
  gpu_sizes = var.enable_gpu ? [
    "n1-standard-1",
    "n1-standard-2",
    "n1-standard-4",
    "n1-standard-8",
    "n1-highmem-2",
    "n1-highmem-4",
    "n1-highmem-8",
  ] : []
  v100_sizes = var.enable_gpu ? [
    "n1-standard-1",
    "n1-standard-2",
    "n1-standard-4",
    "n1-standard-8",
    "n1-highmem-2",
    "n1-highmem-4",
    "n1-highmem-8",
  ] : []
  a100_sizes = var.enable_a100 ? [
    "a2-highgpu-1g",
    "a2-highgpu-2g",
    "a2-highgpu-4g",
  ] : []
}

module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/beta-public-cluster"
  version = "~> 19.0.0"

  project_id        = var.project_id
  name              = "zeet-${var.cluster_name}"
  release_channel   = "STABLE"
  region            = var.region
  regional          = false
  zones             = [var.zone]
  network           = module.vpc.network_name
  subnetwork        = module.vpc.subnets_names[0]
  ip_range_pods     = "zeet-${var.cluster_name}-subnet-01-pods"
  ip_range_services = "zeet-${var.cluster_name}-subnet-01-services"

  horizontal_pod_autoscaling = true
  gce_pd_csi_driver          = true
  enable_tpu                 = var.enable_tpu

  http_load_balancing = false
  network_policy      = false
  istio               = false
  cloudrun            = false
  dns_cache           = false

  remove_default_node_pool = true

  cluster_autoscaling = {
    enabled             = true
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
    max_cpu_cores       = 250
    min_cpu_cores       = 2
    max_memory_gb       = 1000
    min_memory_gb       = 4
    gpu_resources       = []
  }

  node_pools = concat([
    {
      name                      = "e2-standard-2-system"
      machine_type              = "e2-standard-2"
      node_locations            = var.zone
      min_count                 = 1
      max_count                 = 10
      local_ssd_count           = 0
      local_ssd_ephemeral_count = 0
      disk_size_gb              = 100
      disk_type                 = "pd-standard"
      image_type                = "COS_CONTAINERD"
      auto_repair               = true
      auto_upgrade              = true
      preemptible               = false
      initial_node_count        = 1
    },
    {
      name                      = "e2-standard-2-guara-preemp"
      machine_type              = "e2-standard-2"
      node_locations            = var.zone
      min_count                 = 0
      max_count                 = 10
      local_ssd_count           = 0
      local_ssd_ephemeral_count = 0
      disk_size_gb              = 100
      disk_type                 = "pd-standard"
      image_type                = "COS_CONTAINERD"
      auto_repair               = true
      auto_upgrade              = true
      preemptible               = true
      initial_node_count        = 0
    },
    {
      name                      = "e2-standard-2-dedicated"
      machine_type              = "e2-standard-2"
      node_locations            = var.zone
      min_count                 = 0
      max_count                 = 10
      local_ssd_count           = 0
      local_ssd_ephemeral_count = 0
      disk_size_gb              = 100
      disk_type                 = "pd-standard"
      image_type                = "COS_CONTAINERD"
      auto_repair               = true
      auto_upgrade              = true
      preemptible               = false
      initial_node_count        = 0
    }
    ], [for size in local.gpu_sizes : {
      name                      = "${size}-nvidia-t4"
      machine_type              = size
      node_locations            = var.zone
      min_count                 = 0
      max_count                 = 20
      local_ssd_count           = 0
      local_ssd_ephemeral_count = 0
      accelerator_count         = 1
      accelerator_type          = "nvidia-tesla-t4"
      disk_size_gb              = 200
      disk_type                 = "pd-standard"
      image_type                = "COS_CONTAINERD"
      auto_repair               = true
      auto_upgrade              = true
      preemptible               = false
      initial_node_count        = 0
    }],
    [for size in local.v100_sizes : {
      name                      = "${size}-nvidia-v100"
      machine_type              = size
      node_locations            = var.zone
      min_count                 = 0
      max_count                 = 20
      local_ssd_count           = 0
      local_ssd_ephemeral_count = 0
      accelerator_count         = 1
      accelerator_type          = "nvidia-tesla-v100"
      disk_size_gb              = 200
      disk_type                 = "pd-standard"
      image_type                = "COS_CONTAINERD"
      auto_repair               = true
      auto_upgrade              = true
      preemptible               = false
      initial_node_count        = 0
    }],
    [for size in local.a100_sizes : {
      name                      = "${size}-nvidia-a100"
      machine_type              = size
      node_locations            = var.zone
      min_count                 = 0
      max_count                 = 20
      local_ssd_count           = 0
      local_ssd_ephemeral_count = 0
      disk_size_gb              = 200
      disk_type                 = "pd-standard"
      image_type                = "COS_CONTAINERD"
      auto_repair               = true
      auto_upgrade              = true
      preemptible               = false
      initial_node_count        = 0
    }]
  )

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }



  node_pools_labels = merge({
    all = {
      ZeetClusterId = var.cluster_id
      ZeetUserId    = var.user_id
    }

    e2-standard-2-system = {
      "zeet.co/dedicated" = "system"
    }

    e2-standard-2-guara-preemp = {
      "zeet.co/dedicated" = "guaranteed"
    }

    e2-standard-2-dedicated = {
      "zeet.co/dedicated" = "dedicated"
    }

    }, {
    for size in local.gpu_sizes : "${size}-nvidia-t4" => {
      "zeet.co/dedicated"                = "dedicated"
      "cloud.google.com/gke-accelerator" = "nvidia-tesla-t4"
    } }, {
    for size in local.v100_sizes : "${size}-nvidia-v100" => {
      "zeet.co/dedicated"                = "dedicated"
      "cloud.google.com/gke-accelerator" = "nvidia-tesla-v100"
    } }, {
    for size in local.a100_sizes : "${size}-nvidia-a100" => {
      "zeet.co/dedicated"                = "dedicated"
      "cloud.google.com/gke-accelerator" = "nvidia-tesla-a100"
    }
    }
  )


  node_pools_metadata = {
    all = {
      ZeetClusterId = var.cluster_id
      ZeetUserId    = var.user_id
    }
  }

  node_pools_taints = {
    all = []

    e2-standard-2-guara-preemp = [
      {
        key    = "zeet.co/dedicated"
        value  = "guaranteed"
        effect = "NO_SCHEDULE"
      },
    ]

    e2-standard-2-dedicated = [
      {
        key    = "zeet.co/dedicated"
        value  = "dedicated"
        effect = "NO_SCHEDULE"
      },
    ]
  }

  node_pools_tags = {
    all = []
  }

  depends_on = [module.enables-google-apis]
}
