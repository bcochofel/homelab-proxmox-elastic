# Copy to terraform.tfvars (gitignored) or set as HCP workspace variables.

proxmox_endpoint = "https://192.168.68.10:8006/"
# Set TF_VAR_proxmox_api_token in env / HCP (sensitive):
#   terraform@pve!tf=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
proxmox_insecure = true
target_node      = "pve"

vm_template  = "ubuntu-26.04-elastic"
cluster_name = "homelab-observability"

gateway        = "192.168.68.1"
network_bridge = "vmbr0"
nameserver     = ["192.168.68.42", "192.168.68.43"] # CoreDNS + Pihole (homelab-proxmox-core)
searchdomain   = "homelab.bcochofel.com"

ciuser = "ubuntu"
# Set TF_VAR_cipassword in env / HCP (sensitive)
sshkeys = "ssh-ed25519 AAAA... bcochofel@host"

# Defaults already size es x3 (8GB), kibana (4GB), and apm_server (4GB).
# Override es_nodes/kibana_node/apm_server_node here only if you want
# different VMIDs, IPs, or sizing.
