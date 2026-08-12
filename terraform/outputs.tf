output "es_nodes" {
  value = {
    for name, mod in module.es : name => {
      vmid = mod.vmid
      ip   = mod.ip
    }
  }
  description = "Elasticsearch node names -> {vmid, ip}"
}

output "kibana" {
  value = {
    name = module.kibana.name
    vmid = module.kibana.vmid
    ip   = module.kibana.ip
  }
  description = "Kibana node details"
}

output "kibana_url" {
  # Port must stay in sync with kibana_port in
  # ansible/inventory/group_vars/kibana.yml — Terraform has no variable of
  # its own for it, this is a hand-kept mirror.
  value       = "https://kibana.homelab.bcochofel.com:443"
  description = "Kibana URL once provisioned (Let's Encrypt TLS, see docs/ANSIBLE.md)"
}

output "apm_server" {
  value = {
    name = module.apm_server.name
    vmid = module.apm_server.vmid
    ip   = module.apm_server.ip
  }
  description = "APM Server node details"
}

output "es_endpoint" {
  value       = "http://${module.es[var.es_nodes[0].name].ip}:9200"
  description = "An Elasticsearch endpoint (first node)"
}

output "inventory_path" {
  value       = local_file.ansible_inventory.filename
  description = "Path to the generated Ansible inventory"
}
