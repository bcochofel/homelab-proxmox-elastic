# Ansible — configure the Elastic observability cluster

Consumes the Terraform-generated `inventory/hosts.ini`, which now carries
four groups — `elasticsearch`, `kibana`, `apm_server`, `otel_demo` — one per
VM role. `inventory/group_vars/` (adjacent to `hosts.ini`, so discovery
doesn't depend on where a playbook lives) is hand-authored (pins
`stack_version`, heap, security toggle) and is never overwritten by
Terraform.

Roles:

- `common` — preflight checks only (OS/version, Docker + Compose plugin
  present). It has zero involvement in OS configuration — no variables for
  `vm.max_map_count`, ulimits, or the `/opt/elastic` base directory exist on
  the Ansible side at all. All of that is baked into the Packer template
  (`ubuntu-26.04`, used by every VM in the topology now). See
  [`../packer/ubuntu-26.04/README.md`](../packer/ubuntu-26.04/README.md).
- `elasticsearch` — identical compose + per-node `.env`; rolls one node at a time.
- `kibana` — Kibana compose stack pointed at all ES nodes.
- `apm_server` — same DRY compose pattern as ES/Kibana (identical
  `docker-compose.yml` + `.env`); self-managed APM Server, not the
  Fleet-managed APM integration, since Fleet Server isn't up yet (see
  "Security sequencing" in `CLAUDE.md`).
- `otel_demo` — checks out the upstream
  [`open-telemetry/opentelemetry-demo`](https://github.com/open-telemetry/opentelemetry-demo)
  compose project and overrides its OTLP exporter env vars
  (`OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) to
  point at the `apm_server` host instead of the demo's bundled
  Jaeger/Grafana/Prometheus stack.
- `elastic_agent` — applies to every host in the inventory (`hosts: all`),
  including `otel-demo`. Installs the `.deb` package and renders a
  standalone `elastic-agent.yml` (OS + Docker metrics/logs, output pointed
  at the `elasticsearch` group). Standalone, not Fleet-managed — same
  reason as `apm_server`: no Fleet Server yet. Migrating these agents (and
  APM ingestion) to Fleet-managed mode is planned work for after TLS +
  Fleet Server land, not part of this role.

Playbooks (all under `playbooks/`, run via `site.yml`'s `import_playbook`
chain):

- `00-bootstrap.yml` — preflight (`common` role), `hosts: all`.
- `10-elasticsearch.yml` — ES cluster.
- `20-kibana.yml` — Kibana.
- `30-apm-server.yml` — APM Server.
- `40-otel-demo.yml` — OTel demo.
- `50-elastic-agent.yml` — Elastic Agent, `hosts: all`.
- `99-healthcheck.yml` — asserts cluster green with N nodes, Kibana up, APM
  Server up, and the OTel demo stack running.
- `site.yml` — the full chain: bootstrap -> ES -> Kibana -> APM Server ->
  OTel demo -> Elastic Agent (all hosts) -> health.

`ansible.cfg` sets `roles_path = roles` so role lookup works regardless of
which playbook (or subdirectory) is invoked.

Ansible itself runs from a local virtualenv (`.venv/` at repo root), not a
system install — `make install` (from the repo root) creates it, pip-installs
Ansible from `requirements.txt`, and installs the collections below.

```bash
# from repo root, one-time setup:
make install

# from ansible/, day to day:
../.venv/bin/ansible-galaxy collection install -r requirements.yml
../.venv/bin/ansible-playbook playbooks/site.yml
```

## Bootstrap lifecycle

`es_bootstrap_cluster: true` emits `cluster.initial_master_nodes` for first
formation. Once green, set it to `false` in
`inventory/group_vars/elasticsearch.yml` and re-run for safe steady-state
config.
