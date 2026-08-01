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
- `es_certs` — generates one CA + one shared node certificate (PEM, SANs
  covering all three ES nodes + Kibana + APM Server) via
  `elasticsearch-certutil`, then distributes it. Generation runs via a
  one-off `docker run --rm` against the pinned `es_image`, bind-mounting the
  host's certs directory directly — deliberately **not** `docker exec` into
  the live `elasticsearch` service container. An earlier version of this
  role did exec into the running container, which only worked for a live
  security cutover on a cluster that already had one; on a from-scratch
  bootstrap no `elasticsearch` container exists yet at this point in
  `site.yml` (it's only created later, in `10-elasticsearch.yml`), so that
  approach would fail outright. `docker run` has no such dependency. PEM,
  not p12/keystore — avoids the Docker `ELASTIC_PASSWORD`/`KEYSTORE_PASSWORD`
  interaction bug (elastic/elasticsearch#98115) by construction. Idempotent:
  a controller-local cache (`ansible/.certs/`, gitignored) is checked before
  ever regenerating, since regenerating against an already-secured cluster
  would invalidate trust cluster-wide. Runs unconditionally (inert until
  `es_security_enabled` is true) so it's safe to leave in the standard
  `site.yml` chain.
- `es_security_bootstrap` — runs once against `elasticsearch[0]`, only when
  `es_security_enabled` is true: sets the built-in `kibana_system` user's
  password and mints the API keys APM Server / standalone Elastic Agents
  use as their ES output credential (never the `elastic` superuser).
  Minted keys are cached in `ansible/.secrets-cache/` (gitignored, shown
  once at creation) so re-running the playbook doesn't orphan a
  previously-minted key.

## TLS + auth (Phase 2)

`es_security_enabled` (`inventory/group_vars/all.yml`) is the single
controlling flag — everything else (certs, passwords, API keys, `https://`
vs `http://` in every downstream template) is conditional on it. Turning it
on for a **brand-new** cluster is a normal `site.yml` run (`-e
es_bootstrap_cluster=true`, no `security_rollout` needed — every node comes
up already secured from its first-ever start, so there's no mixed-security
window for `serial: 1` to be unsafe against). Turning it on for an existing,
already-green cluster is not — see below.

**Secrets.** `ELASTIC_PASSWORD` and `KIBANA_SYSTEM_PASSWORD` are the only
two human-chosen secrets this phase needs; add them to `secrets.yaml`
yourself (`sops secrets.yaml`) and export them from `ansible/.envrc` the
same way `terraform/.envrc` exports `TF_VAR_*`, then `direnv allow ansible`
(or `make direnv-allow`). `inventory/group_vars/all.yml` reads them via
`lookup('env', ...)` (not a separate `vault.yml` — only `all.yml` or a file
named after a real inventory group auto-loads; a standalone `vault.yml`
silently never gets read, confirmed the hard way); a preflight assert in
`common`'s tasks fails loudly if either resolves empty. Certs and minted API
keys are a different kind of secret — generated, not human-chosen — and are
never round-tripped through `secrets.yaml`; see the
`es_certs`/`es_security_bootstrap` role summaries above.

**Live cluster cutover.** `10-elasticsearch.yml`'s normal `serial: 1` is
unsafe for this specific change — a node restarted with transport TLS on
can't complete a handshake with peers still running plaintext, so a
one-at-a-time rollout leaves the cluster split (not just briefly degraded)
for the whole window. The cutover instead restarts all three ES nodes
together in one batch, gated behind an explicit one-shot flag (same idiom
as `es_bootstrap_cluster`'s CLI-override below):

```bash
ansible-playbook playbooks/site.yml -e es_security_enabled=true -e security_rollout=true
```

Run the full chain in one sitting — Kibana/APM Server/every Elastic Agent
break the instant ES flips, so the cutover isn't done until `site.yml`
completes end to end, not playbook-by-playbook. Once `99-healthcheck.yml`
passes, commit `es_security_enabled: true` in `all.yml` as the new checked-in
steady state. Rollback is the mirror image:
`-e es_security_enabled=false -e security_rollout=true` — `esdata` volumes
are never touched by this change, so it's data-loss-free.

**Credential model, deliberately simplified for homelab scale:** Kibana uses
the built-in `kibana_system` user; APM Server and every standalone Elastic
Agent use API keys instead of the `elastic` superuser — but all six agents
share **one** API key rather than one per host. Least-privilege purism
wasn't judged worth the added bookkeeping at this scale; revisit if that
changes.

Playbooks (all under `playbooks/`, run via `site.yml`'s `import_playbook`
chain):

- `00-bootstrap.yml` — preflight (`common` role), `hosts: all`.
- `05-elasticsearch-certs.yml` — TLS cert generation/distribution
  (`es_certs` role), `hosts: all`. Unconditional, inert until
  `es_security_enabled` is true.
- `10-elasticsearch.yml` — ES cluster.
- `15-elasticsearch-security.yml` — `kibana_system` password + API key
  minting (`es_security_bootstrap` role), only when `es_security_enabled`.
- `20-kibana.yml` — Kibana.
- `30-apm-server.yml` — APM Server.
- `40-otel-demo.yml` — OTel demo.
- `50-elastic-agent.yml` — Elastic Agent, `hosts: all`.
- `99-healthcheck.yml` — asserts cluster green with N nodes, Kibana up, APM
  Server up, and the OTel demo stack running.
- `site.yml` — the full chain: bootstrap -> certs -> ES -> security
  bootstrap -> Kibana -> APM Server -> OTel demo -> Elastic Agent (all
  hosts) -> health.

`ansible.cfg` sets `roles_path = roles` so role lookup works regardless of
which playbook (or subdirectory) is invoked.

Ansible itself runs from a local virtualenv (`.venv/` at repo root), not a
system install — `make install` (from the repo root) creates it, pip-installs
Ansible from `requirements.txt`, and installs the collections below.

```bash
# from repo root, one-time setup:
make install

# day to day:
source .venv/bin/activate
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml
```

Before a real run (or whenever inventory/connectivity is in doubt), check
every host in `hosts.ini` is reachable and correctly named/grouped with a
plain `ping` module call — no playbook, no roles, just SSH + inventory:

```bash
ansible all -m ping
```

A healthy cluster returns `SUCCESS` for `es-01`/`es-02`/`es-03`, `kibana`,
`apm-server`, and `otel-demo`. `UNREACHABLE` points at SSH/`ansible_host`
(wrong IP, VM not up, key not accepted); an inventory/group_vars parsing
error surfaces here too, before it would otherwise fail deep into a
playbook run.

## Bootstrap lifecycle

`es_bootstrap_cluster: true` emits `cluster.initial_master_nodes` for first
formation.

**The checked-in value is `false`** — it tracks this homelab's own
already-bootstrapped cluster, not a template for a fresh one. Standing up a
brand-new cluster (empty ES data volumes, no prior cluster state) needs it
`true` for exactly one run. **Override it on the CLI rather than editing the
checked-in file:**

```bash
ansible-playbook playbooks/site.yml -e es_bootstrap_cluster=true
```

Confirm `_cluster/health` reaches green, then re-run **without** the
override — the checked-in `false` is already correct for steady state, so
there's nothing to revert. Running with `false` against data volumes that
have never formed a cluster will not bootstrap it — there's no in-role check
that catches this, since the role has no way to distinguish "steady state"
from "never bootstrapped."
