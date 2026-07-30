# --------------------------------------------------------
# Proxmox connection
# --------------------------------------------------------
variable "proxmox_api_url" {
  type        = string
  description = "Proxmox API URL"
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API Token ID"
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "Proxmox API Token Secret"
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name"
}

variable "proxmox_skip_tls_verify" {
  type        = bool
  description = "Skip TLS verification"
}

# --------------------------------------------------------
# ISO Boot configuration
# --------------------------------------------------------
variable "boot_iso_type" {
  type        = string
  description = "Boot ISO type"
  default     = "scsi"
}

variable "boot_iso_file" {
  type        = string
  description = "Ubuntu ISO local file"
  default     = "local:iso/ubuntu-26.04-live-server-amd64.iso"
}

variable "boot_iso_unmount" {
  type        = bool
  description = "Unmount ISO after installation?"
  default     = true
}

# --------------------------------------------------------
# Virtual Machine Settings
# --------------------------------------------------------
variable "vm_id" {
  type        = number
  description = "VM template ID"
  default     = 9001
}

variable "vm_name" {
  type        = string
  description = "VM template name"
  default     = "ubuntu-26.04-template"
}

variable "vm_description" {
  type        = string
  description = "VM template description"
  default     = "Ubuntu 26.04 LTS template"
}

variable "qemu_agent" {
  type    = bool
  default = true
}

variable "scsi_controller" {
  type    = string
  default = "virtio-scsi-single"
}

variable "disk_size" {
  type        = string
  description = "Disk size"
  default     = "60G"
}

variable "storage_pool" {
  type        = string
  description = "Storage pool for VM disk"
  default     = "local-lvm"
}

variable "disk_type" {
  type        = string
  description = "Disk Type"
  default     = "scsi"
}

variable "vm_cpu_cores" {
  type        = number
  description = "Number of CPU cores"
  default     = 2
}

variable "vm_cpu_sockets" {
  type        = number
  description = "Number of CPU sockets"
  default     = 1
}

variable "vm_cpu_type" {
  type        = string
  description = "CPU type"
  default     = "host"
}

variable "vm_memory" {
  type        = number
  description = "Memory in MB"
  default     = 2048
}

variable "network_model" {
  type        = string
  description = "Network Model"
  default     = "virtio"
}

variable "network_bridge" {
  type        = string
  description = "Network bridge"
  default     = "vmbr0"
}

# --------------------------------------------------------
# Cloud-init and autoinstall
# --------------------------------------------------------
variable "username" {
  type        = string
  description = "Default user"
  default     = "ubuntu"
}

variable "password_hash" {
  type        = string
  description = <<EOT
Default user password hashed. Use
$ mkpasswd -m sha-512 '<yourpassword>'
EOT
  sensitive   = true
}

variable "hostname" {
  type        = string
  description = "System hostname"
  default     = "ubuntu-template"
}

variable "timezone" {
  type        = string
  description = "System timezone"
  default     = "Europe/Lisbon"
}

variable "locale" {
  type        = string
  description = "System locale"
  default     = "en_US.UTF-8"
}

variable "keyboard_layout" {
  type        = string
  description = "Keyboard layout"
  default     = "us"
}

variable "keyboard_variant" {
  type        = string
  description = "Keyboard variant"
  default     = "intl"
}

# Packages
variable "packages" {
  type        = list(string)
  description = "List of packages to install"
  default = [
    "qemu-guest-agent",
    "cloud-init",
    "lvm2",
    # minimal OS
    "ubuntu-minimal",
    # docker dependencies
    "ca-certificates",
    "curl",
    "gnupg",
    "lsb-release",
    "apt-transport-https",
    "software-properties-common",
    # troubleshooting tools
    "whois",
    "net-tools",
    "inetutils-ping",
    "traceroute",
    "dnsutils",
    "iproute2",
    "tcpdump",
    "unzip",
    "jq",
    "htop",
    "tmux",
    "lsof",
    "strace",
    "vim-nox",
    "mc",
    "sysstat",
    "rsync",
    "git"
  ]
}

# SSH Configuration
variable "ssh_private_key_file" {
  type        = string
  description = "Private key file to use for SSH."
  sensitive   = true
}

variable "ssh_timeout" {
  type        = string
  description = "SSH timeout"
  default     = "20m"
}

# SSH Keys for Default user
variable "ssh_authorized_keys" {
  type        = list(string)
  description = "SSH authorized keys for default user"
  default     = []
}

# Additional Users (optional)
variable "additional_users" {
  type = list(object({
    name                = string
    groups              = list(string)
    sudo                = string
    shell               = string
    ssh_authorized_keys = list(string)
    lock_passwd         = bool
  }))
  description = "Additional users to create"
  default     = []
}

variable "tags" {
  type        = string
  description = "The tags to set. This is a semicolon separated list. For example, debian-12;template."
  default     = "packer;ubuntu"
}

# NTP Servers
variable "ntp_servers" {
  type        = list(string)
  description = "List of NTP servers"
  default = [
    "0.pool.ntp.org",
    "1.pool.ntp.org",
    "2.pool.ntp.org",
    "3.pool.ntp.org"
  ]
}

# --------------------------------------------------------
# Elastic Stack host requirements
# Baked in at image-build time so Ansible only has to render
# docker-compose.yml/.env and run `docker compose up`. Keep these in sync
# with ansible/group_vars/all.yml (vm_max_map_count, elastic_base_dir) —
# changing either side requires a template rebuild.
# --------------------------------------------------------
variable "vm_max_map_count" {
  type        = number
  description = "vm.max_map_count kernel setting (Elasticsearch bootstrap requirement)"
  default     = 262144
}

variable "elastic_base_dir" {
  type        = string
  description = "Base directory for Elastic Stack docker-compose projects"
  default     = "/opt/elastic"
}

# Docker
variable "install_docker" {
  type        = bool
  description = "Wheter to install Docker"
  default     = true
}

# --------------------------------------------------------
# Trivy (OS-level vulnerability scanning) — see ADR-7 in
# packer/ubuntu-26.04/README.md for why this differs from the
# AIDE/rkhunter/chkrootkit/lynis tooling ADR-3 dropped.
# --------------------------------------------------------
variable "install_trivy" {
  type        = bool
  description = "Whether to install Trivy and schedule the daily OS vulnerability scan"
  default     = true
}

variable "trivy_version" {
  type        = string
  description = "Trivy release to install (pinned — matches the Makefile's TRIVY_VERSION)"
  default     = "0.72.0"
}

variable "trivy_report_path" {
  type        = string
  description = "Path where the daily cron overwrites the latest Trivy JSON report"
  default     = "/var/log/trivy/report.json"
}

# --------------------------------------------------------
# Elastic Agent — package pre-installed here (like Docker/Trivy) but left
# disabled: there's no ES cluster at template-build time, so Ansible is
# still the one that renders elastic-agent.yml and enables/starts the
# service, per CLAUDE.md's "Elastic Agent runs standalone" decision. See
# ADR-8 in packer/ubuntu-26.04/README.md.
#
# elastic_agent_version MUST match ansible/group_vars/all.yml's
# stack_version — same manual-sync trade-off ADR-1 already accepts for
# elastic_base_dir. Unlike that one, a drift here isn't harmless: the
# (not-yet-built) elastic_agent Ansible role must check the installed
# version against stack_version and reinstall via this same .deb URL if
# they've drifted, since Packer can't retroactively fix already-cloned
# VMs — see TODO.md's Phase 1 Ansible item.
# --------------------------------------------------------
variable "install_elastic_agent" {
  type        = bool
  description = "Whether to pre-install the Elastic Agent package (left disabled until Ansible configures it)"
  default     = true
}

variable "elastic_agent_version" {
  type        = string
  description = "Elastic Agent version to install — MUST match ansible/group_vars/all.yml's stack_version"
  default     = "9.4.2"
}
