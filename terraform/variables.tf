# --------------------------------------------------------
# Proxmox connection (bpg/proxmox)
# --------------------------------------------------------
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint, e.g. https://192.168.68.10:8006/"
}

variable "proxmox_api_token" {
  type        = string
  description = "API token, form user@realm!tokenid=secret"
  sensitive   = true
}

variable "proxmox_insecure" {
  type        = bool
  description = "Skip TLS verification (homelab self-signed cert)"
  default     = true
}

variable "proxmox_ssh_username" {
  type        = string
  description = "SSH username for provider operations that require SSH"
  default     = "root"
}

variable "target_node" {
  type        = string
  description = "Proxmox node name to place VMs on (your MS-01)"
  default     = "pve"
}

variable "vm_template" {
  type        = string
  description = "Name of the Packer-built template to clone"
  default     = "ubuntu-26.04-template"
}

# --------------------------------------------------------
# Cluster topology
# --------------------------------------------------------
variable "cluster_name" {
  type        = string
  description = "Elasticsearch cluster.name (used by Ansible too)"
  default     = "homelab-observability"
}

variable "es_node_count" {
  type        = number
  description = "Number of Elasticsearch nodes"
  default     = 3
}

variable "es_nodes" {
  type = list(object({
    name    = string
    vmid    = number
    ip_cidr = string # e.g. 192.168.68.30/22
    cores   = number
    memory  = number # MB
    disk    = number # GB
  }))
  description = "Elasticsearch node definitions"
  default = [
    { name = "es-01", vmid = 9501, ip_cidr = "192.168.68.30/22", cores = 2, memory = 8192, disk = 60 },
    { name = "es-02", vmid = 9502, ip_cidr = "192.168.68.31/22", cores = 2, memory = 8192, disk = 60 },
    { name = "es-03", vmid = 9503, ip_cidr = "192.168.68.32/22", cores = 2, memory = 8192, disk = 60 },
  ]
}

variable "kibana_node" {
  type = object({
    name    = string
    vmid    = number
    ip_cidr = string
    cores   = number
    memory  = number
    disk    = number
  })
  description = "Kibana node definition"
  default = {
    name = "kibana", vmid = 9510, ip_cidr = "192.168.68.33/22", cores = 2, memory = 4096, disk = 30
  }
}

variable "apm_server_node" {
  type = object({
    name    = string
    vmid    = number
    ip_cidr = string
    cores   = number
    memory  = number
    disk    = number
  })
  description = "APM Server node definition"
  default = {
    name = "apm-server", vmid = 9520, ip_cidr = "192.168.68.34/22", cores = 2, memory = 4096, disk = 30
  }
}

variable "otel_demo_node" {
  type = object({
    name    = string
    vmid    = number
    ip_cidr = string
    cores   = number
    memory  = number
    disk    = number
  })
  description = "OpenTelemetry demo node definition (upstream opentelemetry-demo compose stack)"
  default = {
    name = "otel-demo", vmid = 9530, ip_cidr = "192.168.68.35/22", cores = 4, memory = 8192, disk = 60
  }
}

# --------------------------------------------------------
# Networking
# --------------------------------------------------------
variable "gateway" {
  type        = string
  description = "Network gateway"
  default     = "192.168.68.1"
}

variable "network_bridge" {
  type        = string
  description = "Proxmox network bridge"
  default     = "vmbr0"
}

variable "nameserver" {
  type        = string
  description = "DNS nameserver for cloud-init"
  default     = "192.168.68.2"
}

variable "searchdomain" {
  type        = string
  description = "DNS search domain"
  default     = "lab.local"
}

# --------------------------------------------------------
# cloud-init
# --------------------------------------------------------
variable "ciuser" {
  type        = string
  description = "cloud-init user (matches Packer template default user)"
  default     = "ubuntu"
}

variable "cipassword" {
  type        = string
  description = "cloud-init user password"
  sensitive   = true
}

variable "sshkeys" {
  type        = string
  description = "Newline-delimited SSH public keys for the cloud-init user"
}

# --------------------------------------------------------
# Ansible inventory generation
# --------------------------------------------------------
variable "ansible_user" {
  type        = string
  description = "Remote user Ansible connects as (matches ansible.cfg)"
  default     = "ubuntu"
}
