# homelab-proxmox-elastic

Elastic Stack observability cluster on Proxmox (MS-01), built with an IaC
pipeline:

```
Packer (template)  ->  Terraform (clone VMs + generate inventory)  ->  Ansible (configure)
```

## Topology

| VM      | vCPU | RAM   | Disk | Role                          | IP             |
| ------- | ---- | ----- | ---- | ----------------------------- | -------------- |
| es-01   | 2    | 8 GB  | 60 G | Elasticsearch (master+data)   | 192.168.68.30  |
| es-02   | 2    | 8 GB  | 60 G | Elasticsearch (master+data)   | 192.168.68.31  |
| es-03   | 2    | 8 GB  | 60 G | Elasticsearch (master+data)   | 192.168.68.32  |
| kibana  | 2    | 4 GB  | 30 G | Kibana                        | 192.168.68.33  |

`192.168.68.30-39` is reserved for this cluster; additional ES/Kibana nodes
should take the next free IP in that range.

Each VM runs a single-container Docker Compose stack. The three ES containers
form one real multi-node cluster across the VMs. Heap is 4 GB/node (≤50% RAM).

## Design decisions

- **Provider:** `bpg/proxmox` (deliberate choice over Telmate).
- **State:** HCP Terraform, workspace `elastic-observability`.
- **Compose pattern:** identical `docker-compose.yml` + per-node `.env` (DRY).
- **Cluster formation:** Terraform writes IPs into the generated inventory;
  Ansible derives `discovery.seed_hosts` and `cluster.initial_master_nodes`
  from inventory. Self-assembling.
- **Inventory:** only `ansible/inventory/hosts.ini` is generated.
  `ansible/group_vars/` is hand-authored and never overwritten.
- **Stack version:** pinned in `group_vars/all.yml` (`stack_version: 9.4.2`),
  not in Terraform.
- **Host kernel:** `vm.max_map_count`, memlock/nofile ulimits, and the
  `/opt/elastic` base directory are baked into the Packer template via
  cloud-init. Ansible's `common` role only runs preflight checks — it never
  configures the OS.
- **Security:** `xpack.security.enabled: false` for now. Flip `es_security_enabled`
  in `group_vars/all.yml` to true later as a TLS/auth exercise.
- **Decoupling:** Terraform and Ansible are run as separate, explicit
  commands — no `local-exec` chaining, and no Makefile wrapper around
  either write step, so the one command that actually changes
  infrastructure always stays visible and explicit.

## Documentation

- [`docs/QUICKSTART.md`](docs/QUICKSTART.md) — get a cluster running end to end.
- [`docs/PACKER.md`](docs/PACKER.md) — VM template build.
- [`docs/TERRAFORM.md`](docs/TERRAFORM.md) — cloning VMs + inventory generation.
- [`docs/ANSIBLE.md`](docs/ANSIBLE.md) — cluster configuration.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — environment setup, branching, commit
  conventions, and versioning for contributors.

## Next steps (deferred)

- Logstash VM (separate role/playbook).
- TLS + auth (`certutil`-generated local CA, run-once play).
- Beats/Elastic Agent to ship Proxmox host + VM metrics/logs.
