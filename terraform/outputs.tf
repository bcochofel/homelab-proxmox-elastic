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
  value       = "http://${module.kibana.ip}:5601"
  description = "Kibana URL once provisioned"
}

output "apm_server" {
  value = {
    name = module.apm_server.name
    vmid = module.apm_server.vmid
    ip   = module.apm_server.ip
  }
  description = "APM Server node details"
}

output "otel_demo" {
  value = {
    name = module.otel_demo.name
    vmid = module.otel_demo.vmid
    ip   = module.otel_demo.ip
  }
  description = "OpenTelemetry demo node details"
}

output "es_endpoint" {
  value       = "http://${module.es[var.es_nodes[0].name].ip}:9200"
  description = "An Elasticsearch endpoint (first node)"
}

output "inventory_path" {
  value       = local_file.ansible_inventory.filename
  description = "Path to the generated Ansible inventory"
}
