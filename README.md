# homelab-proxmox-elastic

Elastic Stack observability cluster on Proxmox (MS-01), built with an IaC
pipeline:

```text
Packer (template)  ->  Terraform (clone VMs + generate inventory)  ->  Ansible (configure)
```

## Topology

| VM         | vCPU | RAM  | Disk | Role                           | IP            |
| ---------- | ---- | ---- | ---- | ------------------------------ | ------------- |
| es-01      | 2    | 8 GB | 60 G | Elasticsearch (master+data)    | 192.168.68.30 |
| es-02      | 2    | 8 GB | 60 G | Elasticsearch (master+data)    | 192.168.68.31 |
| es-03      | 2    | 8 GB | 60 G | Elasticsearch (master+data)    | 192.168.68.32 |
| kibana     | 2    | 4 GB | 30 G | Kibana (+ Fleet Server, later) | 192.168.68.33 |
| apm-server | 2    | 2 GB | 20 G | APM Server                     | 192.168.68.34 |
| otel-demo  | 2    | 4 GB | 30 G | OpenTelemetry demo             | 192.168.68.35 |

`192.168.68.30-39` is reserved for this cluster; additional nodes should take
the next free IP in that range (`.36`-`.39` currently free). No Logstash node
— deliberately out of scope.

Each Elastic Stack VM (ES, Kibana, APM Server) runs a single-container Docker
Compose stack. The three ES containers form one real multi-node cluster
across the VMs. Heap is 4 GB/node (≤50% RAM). `otel-demo` runs the upstream
[open-telemetry/opentelemetry-demo](https://github.com/open-telemetry/opentelemetry-demo)
compose stack, reconfigured to export traces to the APM Server instead of
its bundled Jaeger/Grafana/Prometheus stack. Every VM in the topology,
including `otel-demo`, also runs a standalone Elastic Agent for OS + Docker
metrics/logs.

## Verify

- Kibana: `http://192.168.68.33:5601`
- Elasticsearch: `http://192.168.68.30:9200`
- APM Server: `http://192.168.68.34:8200`
- OTel demo frontend: `http://192.168.68.35:8080`

## Exploring the data in Kibana

No login — `xpack.security` is off (see below). Once the cluster is green,
the OTel demo's `load-generator` keeps producing live traffic continuously,
so there's always fresh data to look at.

Elastic reshuffles Kibana's left nav across versions and even lets each
space pick "classic" vs. a solution-specific view — this project has
already seen the exact app names differ between the two on the same
Kibana instance (no separate "APM"/"Logs" entries in some views), so
precise menu paths aren't documented here. The data underneath is stable
regardless of nav layout — **Discover** with the right data view always
works:

- **Traces/APM data** — `traces-apm-default`, plus per-service
  `logs-apm.app.*` (application logs) and `metrics-apm.*` (throughput,
  latency). Covers every otel-demo microservice (`checkout`, `cart`,
  `frontend`, `payment`, `recommendation`, etc.) and `otelcol_contrib`
  itself. If your nav has a dedicated APM/Applications app, it visualizes
  these same data streams (service list, trace waterfalls, service map)
  instead of browsing them raw in Discover.
- **Logs** — `logs-*` data view. Key datasets: `system.syslog` (every VM's
  OS logs), `docker.container_logs` (every container's stdout/stderr),
  `apm.app.*`, `apm.error` (captured exceptions). Filter on
  `data_stream.dataset` or `container.name`/`host.name` to narrow down.
- **Metrics** — `metrics-*` data view, filtered to `data_stream.dataset`
  values like `system.cpu`, `system.memory`, `docker.cpu`,
  `docker.memory`. An "Infrastructure" app, if present, gives a
  host/container inventory view over the same data.

If `Discover` shows no data the first time, check **Stack Management →
Data Views** — dedicated Observability apps typically query
`logs-*`/`metrics-*`/`traces-*` directly and don't need one, but `Discover`
sometimes does.

## Design decisions

- **Provider:** `bpg/proxmox` (deliberate choice over Telmate).
- **State:** HCP Terraform, workspace `elastic-observability`.
- **Compose pattern:** identical `docker-compose.yml` + per-node `.env` (DRY).
- **Cluster formation:** Terraform writes IPs into the generated inventory;
  Ansible derives `discovery.seed_hosts` and `cluster.initial_master_nodes`
  from inventory. Self-assembling.
- **Inventory:** only `ansible/inventory/hosts.ini` is generated.
  `ansible/inventory/group_vars/` is hand-authored and never overwritten.
- **Stack version:** pinned in `inventory/group_vars/all.yml`
  (`stack_version: 9.4.2`), not in Terraform.
- **Host kernel:** `vm.max_map_count`, memlock/nofile ulimits, and the
  `/opt/elastic` base directory are baked into the Packer template via
  cloud-init. Ansible's `common` role only runs preflight checks — it never
  configures the OS.
- **Security:** `xpack.security.enabled: false` for now. Flip `es_security_enabled`
  in `inventory/group_vars/all.yml` to true later as a TLS/auth exercise.
- **Decoupling:** Terraform and Ansible are run as separate, explicit
  commands — no `local-exec` chaining, and no Makefile wrapper around
  either write step, so the one command that actually changes
  infrastructure always stays visible and explicit.
- **Elastic Agent:** standalone (deb package + Ansible-rendered config) on
  every VM for OS + Docker metrics/logs, not Fleet-managed — Fleet Server
  needs TLS to enroll against, and TLS is deferred (see below).
- **APM Server:** its own VM/compose stack, self-managed — same reason as
  Elastic Agent. Both migrate to Fleet-managed mode once Fleet Server is up.
- **No Logstash:** decided against entirely, not deferred. Ingest goes
  straight to Elasticsearch.
- **Template:** all six VMs clone from the `ubuntu-26.04` Packer template.

## Documentation

- [`docs/QUICKSTART.md`](docs/QUICKSTART.md) — get a cluster running end to end.
- [`docs/PACKER.md`](docs/PACKER.md) — VM template build.
- [`docs/TERRAFORM.md`](docs/TERRAFORM.md) — cloning VMs + inventory generation.
- [`docs/ANSIBLE.md`](docs/ANSIBLE.md) — cluster configuration.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — environment setup, branching, commit
  conventions, and versioning for contributors.
- [`TODO.md`](TODO.md) — phase-by-phase roadmap and current status.

## Next steps

See [`TODO.md`](TODO.md) for the full, checkbox-tracked roadmap (TLS/auth,
Fleet, OSQuery, vulnerability scanning, SIEM, and more) — kept as the one
place status lives instead of duplicated here.
