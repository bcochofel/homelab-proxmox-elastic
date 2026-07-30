# Terraform

See [`../docs/TERRAFORM.md`](../docs/TERRAFORM.md).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | > 1.9.0, < 2.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | 2.5.2 |
| <a name="requirement_proxmox"></a> [proxmox](#requirement\_proxmox) | ~> 0.85 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_local"></a> [local](#provider\_local) | 2.5.2 |
| <a name="provider_proxmox"></a> [proxmox](#provider\_proxmox) | 0.111.1 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_apm_server"></a> [apm\_server](#module\_apm\_server) | ./modules/vm | n/a |
| <a name="module_es"></a> [es](#module\_es) | ./modules/vm | n/a |
| <a name="module_kibana"></a> [kibana](#module\_kibana) | ./modules/vm | n/a |
| <a name="module_otel_demo"></a> [otel\_demo](#module\_otel\_demo) | ./modules/vm | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [local_file.ansible_inventory](https://registry.terraform.io/providers/hashicorp/local/2.5.2/docs/resources/file) | resource |
| [proxmox_virtual_environment_vms.template](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/data-sources/virtual_environment_vms) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_ansible_user"></a> [ansible\_user](#input\_ansible\_user) | Remote user Ansible connects as (matches ansible.cfg) | `string` | `"ubuntu"` | no |
| <a name="input_apm_server_node"></a> [apm\_server\_node](#input\_apm\_server\_node) | APM Server node definition | <pre>object({<br/>    name    = string<br/>    vmid    = number<br/>    ip_cidr = string<br/>    cores   = number<br/>    memory  = number<br/>    disk    = number<br/>  })</pre> | <pre>{<br/>  "cores": 2,<br/>  "disk": 60,<br/>  "ip_cidr": "192.168.68.34/22",<br/>  "memory": 4096,<br/>  "name": "apm-server",<br/>  "vmid": 9520<br/>}</pre> | no |
| <a name="input_cipassword"></a> [cipassword](#input\_cipassword) | cloud-init user password | `string` | n/a | yes |
| <a name="input_ciuser"></a> [ciuser](#input\_ciuser) | cloud-init user (matches Packer template default user) | `string` | `"ubuntu"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Elasticsearch cluster.name (used by Ansible too) | `string` | `"homelab-observability"` | no |
| <a name="input_es_node_count"></a> [es\_node\_count](#input\_es\_node\_count) | Number of Elasticsearch nodes | `number` | `3` | no |
| <a name="input_es_nodes"></a> [es\_nodes](#input\_es\_nodes) | Elasticsearch node definitions | <pre>list(object({<br/>    name    = string<br/>    vmid    = number<br/>    ip_cidr = string # e.g. 192.168.68.30/22<br/>    cores   = number<br/>    memory  = number # MB<br/>    disk    = number # GB<br/>  }))</pre> | <pre>[<br/>  {<br/>    "cores": 2,<br/>    "disk": 60,<br/>    "ip_cidr": "192.168.68.30/22",<br/>    "memory": 8192,<br/>    "name": "es-01",<br/>    "vmid": 9501<br/>  },<br/>  {<br/>    "cores": 2,<br/>    "disk": 60,<br/>    "ip_cidr": "192.168.68.31/22",<br/>    "memory": 8192,<br/>    "name": "es-02",<br/>    "vmid": 9502<br/>  },<br/>  {<br/>    "cores": 2,<br/>    "disk": 60,<br/>    "ip_cidr": "192.168.68.32/22",<br/>    "memory": 8192,<br/>    "name": "es-03",<br/>    "vmid": 9503<br/>  }<br/>]</pre> | no |
| <a name="input_gateway"></a> [gateway](#input\_gateway) | Network gateway | `string` | `"192.168.68.1"` | no |
| <a name="input_kibana_node"></a> [kibana\_node](#input\_kibana\_node) | Kibana node definition | <pre>object({<br/>    name    = string<br/>    vmid    = number<br/>    ip_cidr = string<br/>    cores   = number<br/>    memory  = number<br/>    disk    = number<br/>  })</pre> | <pre>{<br/>  "cores": 2,<br/>  "disk": 60,<br/>  "ip_cidr": "192.168.68.33/22",<br/>  "memory": 4096,<br/>  "name": "kibana",<br/>  "vmid": 9510<br/>}</pre> | no |
| <a name="input_nameserver"></a> [nameserver](#input\_nameserver) | DNS nameserver for cloud-init | `string` | `"192.168.68.2"` | no |
| <a name="input_network_bridge"></a> [network\_bridge](#input\_network\_bridge) | Proxmox network bridge | `string` | `"vmbr0"` | no |
| <a name="input_otel_demo_node"></a> [otel\_demo\_node](#input\_otel\_demo\_node) | OpenTelemetry demo node definition (upstream opentelemetry-demo compose stack) | <pre>object({<br/>    name    = string<br/>    vmid    = number<br/>    ip_cidr = string<br/>    cores   = number<br/>    memory  = number<br/>    disk    = number<br/>  })</pre> | <pre>{<br/>  "cores": 4,<br/>  "disk": 60,<br/>  "ip_cidr": "192.168.68.35/22",<br/>  "memory": 8192,<br/>  "name": "otel-demo",<br/>  "vmid": 9530<br/>}</pre> | no |
| <a name="input_proxmox_api_token"></a> [proxmox\_api\_token](#input\_proxmox\_api\_token) | API token, form user@realm!tokenid=secret | `string` | n/a | yes |
| <a name="input_proxmox_endpoint"></a> [proxmox\_endpoint](#input\_proxmox\_endpoint) | Proxmox API endpoint, e.g. https://192.168.68.10:8006/ | `string` | n/a | yes |
| <a name="input_proxmox_insecure"></a> [proxmox\_insecure](#input\_proxmox\_insecure) | Skip TLS verification (homelab self-signed cert) | `bool` | `true` | no |
| <a name="input_proxmox_ssh_username"></a> [proxmox\_ssh\_username](#input\_proxmox\_ssh\_username) | SSH username for provider operations that require SSH | `string` | `"root"` | no |
| <a name="input_searchdomain"></a> [searchdomain](#input\_searchdomain) | DNS search domain | `string` | `"lab.local"` | no |
| <a name="input_sshkeys"></a> [sshkeys](#input\_sshkeys) | Newline-delimited SSH public keys for the cloud-init user | `string` | n/a | yes |
| <a name="input_target_node"></a> [target\_node](#input\_target\_node) | Proxmox node name to place VMs on (your MS-01) | `string` | `"pve"` | no |
| <a name="input_vm_template"></a> [vm\_template](#input\_vm\_template) | Name of the Packer-built template to clone | `string` | `"ubuntu-26.04-template"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_apm_server"></a> [apm\_server](#output\_apm\_server) | APM Server node details |
| <a name="output_es_endpoint"></a> [es\_endpoint](#output\_es\_endpoint) | An Elasticsearch endpoint (first node) |
| <a name="output_es_nodes"></a> [es\_nodes](#output\_es\_nodes) | Elasticsearch node names -> {vmid, ip} |
| <a name="output_inventory_path"></a> [inventory\_path](#output\_inventory\_path) | Path to the generated Ansible inventory |
| <a name="output_kibana"></a> [kibana](#output\_kibana) | Kibana node details |
| <a name="output_kibana_url"></a> [kibana\_url](#output\_kibana\_url) | Kibana URL once provisioned |
| <a name="output_otel_demo"></a> [otel\_demo](#output\_otel\_demo) | OpenTelemetry demo node details |
<!-- END_TF_DOCS -->
