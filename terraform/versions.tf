terraform {
  required_version = "> 1.9.0, < 2.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.85" # pin minor — bpg iterates fast
    }
    local = {
      source  = "hashicorp/local"
      version = "2.5.2"
    }
  }

  # HCP Terraform. Create a separate workspace for this workload.
  cloud {
    organization = "homelab-bcochofel-com"

    workspaces {
      name = "elastic-observability"
    }
  }
}
