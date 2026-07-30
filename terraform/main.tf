# ----------------------------------------------------------------------------
# Elastic observability cluster on Proxmox.
# Packer template -> Terraform clones N+1 VMs -> generates Ansible inventory.
# ----------------------------------------------------------------------------

# Look up the template's VMID by name so tfvars can reference it by name.
data "proxmox_virtual_environment_vms" "template" {
  node_name = var.target_node

  filter {
    name   = "name"
    values = [var.vm_template]
  }
}

locals {
  template_vmid = one(data.proxmox_virtual_environment_vms.template.vms).vm_id
}

# Elasticsearch nodes
module "es" {
  source   = "./modules/vm"
  for_each = { for n in var.es_nodes : n.name => n }

  name          = each.value.name
  vmid          = each.value.vmid
  target_node   = var.target_node
  template_vmid = local.template_vmid

  cores  = each.value.cores
  memory = each.value.memory
  disk   = each.value.disk

  ip_cidr        = each.value.ip_cidr
  gateway        = var.gateway
  network_bridge = var.network_bridge
  nameserver     = var.nameserver
  searchdomain   = var.searchdomain

  ciuser     = var.ciuser
  cipassword = var.cipassword
  sshkeys    = var.sshkeys

  tags = ["terraform", "elastic", "elasticsearch"]
}

# Kibana node
module "kibana" {
  source = "./modules/vm"

  name          = var.kibana_node.name
  vmid          = var.kibana_node.vmid
  target_node   = var.target_node
  template_vmid = local.template_vmid

  cores  = var.kibana_node.cores
  memory = var.kibana_node.memory
  disk   = var.kibana_node.disk

  ip_cidr        = var.kibana_node.ip_cidr
  gateway        = var.gateway
  network_bridge = var.network_bridge
  nameserver     = var.nameserver
  searchdomain   = var.searchdomain

  ciuser     = var.ciuser
  cipassword = var.cipassword
  sshkeys    = var.sshkeys

  tags = ["terraform", "elastic", "kibana"]
}

# ----------------------------------------------------------------------------
# Generate Ansible inventory.
# Only hosts.ini is generated — group_vars/ stays hand-authored so Terraform
# never clobbers tuning. Derives seed_hosts + initial_master_nodes from the IPs
# Terraform knows, which is exactly what lets the cluster self-assemble.
# ----------------------------------------------------------------------------
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.root}/templates/inventory.ini.tftpl", {
    es_nodes = [
      for name, mod in module.es : {
        name = mod.name
        ip   = mod.ip
      }
    ]
    kibana_name  = module.kibana.name
    kibana_ip    = module.kibana.ip
    cluster_name = var.cluster_name
    ansible_user = var.ansible_user
  })
  filename = "${path.root}/../ansible/inventory/hosts.ini"
}
