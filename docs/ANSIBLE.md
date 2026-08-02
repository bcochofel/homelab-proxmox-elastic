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
- `otel_demo` — checks out the upstream
  [`open-telemetry/opentelemetry-demo`](https://github.com/open-telemetry/opentelemetry-demo)
  compose project and overrides its OTLP exporter env vars
  (`OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) to
  point at the `apm_server` host instead of the demo's bundled
  Jaeger/Grafana/Prometheus stack. Unchanged by the Phase 3 APM migration
  below — same host:port either way, now backed by the Fleet-managed APM
  integration instead of a standalone container.
- `elastic_agent` — applies to every host in the inventory (`hosts: all`),
  including `otel-demo`. Fleet-managed (Phase 3 steps 2+3, complete) — see
  "Fleet" below. Still checks the pre-installed `.deb` package's version
  against `stack_version` and reinstalls if drifted, same as before; the
  standalone-config rendering this role used to also do is gone (one-way
  migration, no dual-mode toggle — see git history if a rollback is ever
  needed).
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
  password (never the `elastic` superuser). Used to also mint the API keys
  APM Server / standalone Elastic Agents used as their ES output credential
  — gone since Phase 3: every agent is Fleet-managed now and gets its ES
  output credentials from Fleet enrollment instead (see `fleet_bootstrap`
  below), so there's no standalone credential left to mint.
- `kibana_tls` — Let's Encrypt certificate for Kibana's public URL
  (`kibana_fqdn`, `inventory/group_vars/kibana.yml`), via `certbot` +
  `certbot-dns-cloudflare` (DNS-01 — Kibana has no public port 80/443 to
  answer an HTTP-01 challenge; the `_acme-challenge` TXT record lands in
  Cloudflare regardless of where the A record itself is hosted, since
  that's the zone `bcochofel.com` is delegated to). Runs as a host apt
  package with certbot's own systemd renewal timer, not a container —
  this is a recurring scheduled job (Trivy's shape, see ADR-7 in
  `packer/ubuntu-26.04/README.md`), not a one-shot generate-once tool
  invocation (`es_certs`'s shape) — and keeping it host-side means the
  renewal deploy-hook can call `docker compose restart kibana` directly
  with no Docker-socket-in-container privilege exposure. The deploy-hook
  (registered at issuance time via `--deploy-hook`, persisted into
  certbot's own renewal config for every future automatic renewal) copies
  the renewed `fullchain.pem`/`privkey.pem` into
  `{{ elastic_base_dir }}/kibana/certs/` and restarts the `kibana`
  container so it picks up the new cert. Needs `CLOUDFLARE_API_TOKEN`
  (Zone:DNS:Edit only, scoped to `bcochofel.com`) — see "TLS + auth"
  below.
- `fleet_bootstrap` — runs once against `kibana`, only when
  `fleet_server_enabled`: scripts the same Kibana Fleet setup a human would
  otherwise click through the UI wizard for — `POST /api/fleet/setup`, the
  Fleet Server agent policy + host registration, the `elastic/fleet-server`
  ES service account token, and (Phase 3 steps 2+3) the two agent policies
  the six Elastic Agents and the APM integration migrate onto
  (`homelab-agents-policy`: System + Docker; `apm-server-agent-policy`:
  System + Docker + APM), their package policies, and their enrollment
  tokens — all via `ansible.builtin.uri`, same idiom as
  `es_security_bootstrap`'s old API-key minting. Idempotent throughout —
  every create step is guarded by a GET-by-id check first, using fixed IDs
  rather than name matching, and minted credentials are cached in
  `ansible/.secrets-cache/`.

  Also explicitly points Fleet's default output at the real ES cluster
  (`PUT /api/fleet/outputs/fleet-default-output`) — `POST /api/fleet/setup`
  auto-creates that output pointed at plain `http://localhost:9200`, which
  is silently wrong here (HTTPS, security on, three real ES nodes, a
  self-signed internal CA) and every enrolled agent's data output failed
  until this was added. Found live, not from inspection: `metrics-system.*`
  /`metrics-docker.*` data streams never got created at all, and a plain
  HTTP request to a real ES node's HTTPS-only port gets "Empty reply from
  server" — the exact shape of the "EOF" errors agents were reporting.

  Package policy `inputs` are `{}` (Fleet's own defaults) everywhere except
  APM's `host` var, which defaults to `localhost:8200` — loopback only,
  would silently break `otel_demo`'s cross-VM OTLP export — so that one is
  explicitly overridden to `0.0.0.0:8200`. The input key for that override
  is `"{policy_template.name}-{input.type}"` (`apmserver-apm`), not the
  input's own type or the package name alone — confirmed empirically
  against a live cluster (`"apmserver"` and `"apm"` alone both 400 with
  `"Input not found"`).

  All three agent policies also get `monitoring_enabled: [logs, metrics]`
  — without it, Fleet's own "Logs"/"Metrics" tabs for an agent in the
  Kibana UI show as disabled (this is agent self-monitoring visibility,
  unrelated to whether the System/Docker integrations are actually
  collecting data, which they were the whole time). Set both at policy
  creation time and via an unconditional `PUT` retrofit right after —
  `PUT` requires the full body (name/namespace, not a partial patch) and
  is safe to always re-run, same idiom as the output-config fix above;
  the retrofit is what actually fixed it on this cluster, since the
  policies already existed by the time this was added.
- `fleet_server` — Fleet Server itself, same DRY compose pattern as
  ES/Kibana. Bootstraps from the `elastic-agent` image (there's no
  dedicated `fleet-server` image), pinned to `stack_version` like every
  other image here. Its own TLS listener (port 8220, what every Elastic
  Agent connects to) reuses the internal CA `es_certs` already generates:
  that cert's SAN list already covers the Kibana host, so the role just
  copies the node cert/key from the controller-local cache onto this host
  rather than `es_certs` needing any changes. `FLEET_SERVER_ELASTICSEARCH_HOST`
  points at a single ES node (the env var takes one host, not a list) —
  same kind of homelab-scale simplification already accepted elsewhere. A
  Fleet Server is itself always an enrolled Elastic Agent — the container
  also self-enrolls against the Fleet Server it just started, which needs
  `FLEET_URL` (+ `FLEET_CA` to trust its own cert) set too; without them,
  enrollment fails outright (`"url is required when a certificate is
  provided"`), confirmed live.

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

**Credential model:** Kibana uses the built-in `kibana_system` user, never
the `elastic` superuser. (Prior to Phase 3, APM Server and every standalone
Elastic Agent used a shared API key the same way — see "Fleet" below for
what replaced that once everything became Fleet-managed.)

## Kibana TLS (Let's Encrypt)

Separate from the internal `es_certs` CA above — Kibana's own public URL
(`kibana_fqdn`, default `kibana.homelab.bcochofel.com`) is served with a
real Let's Encrypt certificate instead, since it's the one endpoint humans
hit in a browser. `kibana_tls_enabled` (`inventory/group_vars/kibana.yml`)
gates it; the `kibana` role's compose template only sets
`SERVER_SSL_ENABLED`/`SERVER_SSL_CERTIFICATE`/`SERVER_SSL_KEY` and mounts
`{{ elastic_base_dir }}/kibana/certs` when it's true, and `kibana_port`
becomes `443` (still just the host-side published port, same var
`99-healthcheck.yml` already uses) so the URL needs no port suffix.

**Secrets.** `CLOUDFLARE_API_TOKEN` is the one secret this needs — a
Cloudflare API token scoped to **Zone:DNS:Edit only** for the
`bcochofel.com` zone (not the broader "Edit zone" template — this token
only ever needs to create/delete the `_acme-challenge` TXT record).
Same pattern as `ELASTIC_PASSWORD`: add it to `secrets.yaml`
(`sops secrets.yaml`), export it from `ansible/.envrc`, then
`direnv allow ansible`. A preflight assert in `common` (gated on
`kibana_tls_enabled`) fails loudly if it resolves empty.

DNS-01 was the only option here, not a preference — Kibana has no public
port 80/443 exposure for HTTP-01. The ACME `_acme-challenge` TXT record
still has to land in Cloudflare regardless of where the `kibana_fqdn` A
record itself is hosted (this homelab's on-prem DNS server, in this case),
since Cloudflare is the zone `bcochofel.com` is actually delegated to.

Renewal is entirely certbot's own systemd timer (installed by the
`certbot` apt package) — no separate cron entry. The `--deploy-hook` script
passed at issuance time gets persisted into certbot's renewal config and
re-run automatically on every future renewal, copying the new cert into
`{{ elastic_base_dir }}/kibana/certs/` and restarting the `kibana`
container.

## Fleet (Phase 3, complete)

Three steps, landed as three changes with live verification at each stage:

1. **Fleet Server** on the Kibana VM — `fleet_server_enabled`
   (`inventory/group_vars/kibana.yml`) gates the `35-fleet-server.yml` play.
2. **All six Elastic Agents Fleet-managed** — the `elastic_agent` role no
   longer renders a standalone config, only enrolls (one-way migration).
3. **APM ingestion via the Fleet-managed APM integration** — the standalone
   `apm_server` role and its compose stack are gone; the apm-server host's
   own Elastic Agent runs the APM integration instead, same host:port
   `otel_demo` already targeted. Elastic Agent 9.x ships in install
   "flavors" — the default `basic` flavor (what Packer's pre-install and
   every other host uses) doesn't include the APM input at all. Confirmed
   live: the apm component reported `"input not supported - ensure you
   have installed the correct flavor"` and nothing ever listened on 8200.
   `elastic_agent`'s tasks purge and reinstall the `.deb` with
   `ELASTIC_AGENT_FLAVOR=servers` for the `apm_server` host specifically
   (own marker file, separate from the version-drift and enrollment
   markers — purging wipes `/etc/elastic-agent`, so this has to run
   *before* enrollment or it'd purge a live enrollment out from under
   itself). dpkg tracks package version, not flavor, so a same-version
   reinstall wouldn't have triggered the flavor-specific postinst logic on
   its own.

**Secrets.** `KIBANA_ENCRYPTION_KEY` is the one new secret Fleet needs —
Kibana's `xpack.encryptedSavedObjects.encryptionKey`, which Fleet requires
to encrypt the service tokens/API keys it stores as saved objects.
Discovered empirically, not from a checklist: `POST /api/fleet/setup`
fails outright with `"Agent binary source needs encrypted saved object api
key to be set"` without it. Human-chosen like `ELASTIC_PASSWORD` — generate
one (`openssl rand -hex 32`), add it to `secrets.yaml`, export from
`ansible/.envrc`, then `direnv allow ansible`. A preflight assert in
`common` (gated on `fleet_server_enabled`) fails loudly if it resolves
empty.

Fleet Server's own TLS (port 8220) reuses the internal `es_certs` CA rather
than the new Let's Encrypt cert — every Elastic Agent that enrolls against
it already trusts that CA (it's already distributed to all six VMs), so
there's nothing extra to distribute. Its own ES output, unlike Kibana's,
points at a single ES node rather than the full `elasticsearch` group —
`FLEET_SERVER_ELASTICSEARCH_HOST` only takes one host, a real
container-env-var constraint, not a stylistic choice.

All Kibana-side setup (agent policies, package policies, Fleet Server host
registration, Fleet's default output config) is scripted via
`ansible.builtin.uri` against Kibana's own Fleet HTTP API rather than
relying on the `elastic-agent` container's own `KIBANA_FLEET_SETUP`
auto-bootstrap env vars — keeps it in the same API-driven, idempotent,
inspectable style every other secret/credential in this repo already uses
(`es_security_bootstrap`'s old API-key minting), instead of a second, less
transparent bootstrap mechanism. See the `fleet_bootstrap`/`fleet_server`/
`elastic_agent` role summaries above for what surfaced only by running
this live: agents silently trying plain HTTP against Fleet's
auto-generated default output, Fleet Server's own self-enrollment needing
`FLEET_URL`/`FLEET_CA`, `ansible.builtin.uri` not sending Basic auth
credentials preemptively against Kibana's API, and the APM package
policy's input-key naming.

Playbooks (all under `playbooks/`, run via `site.yml`'s `import_playbook`
chain):

- `00-bootstrap.yml` — preflight (`common` role), `hosts: all`.
- `05-elasticsearch-certs.yml` — TLS cert generation/distribution
  (`es_certs` role), `hosts: all`. Unconditional, inert until
  `es_security_enabled` is true.
- `10-elasticsearch.yml` — ES cluster.
- `15-elasticsearch-security.yml` — `kibana_system` password
  (`es_security_bootstrap` role), only when `es_security_enabled`.
- `18-kibana-tls.yml` — Kibana's Let's Encrypt certificate (`kibana_tls`
  role), before Kibana itself since the container's compose file bind-mounts
  the cert.
- `20-kibana.yml` — Kibana.
- `35-fleet-server.yml` — Fleet Server + all agent/package policies +
  enrollment tokens (`fleet_bootstrap` + `fleet_server` roles), only when
  `fleet_server_enabled`.
- `40-otel-demo.yml` — OTel demo.
- `50-elastic-agent.yml` — Elastic Agent enrollment, `hosts: all` (includes
  the apm-server host, which is what actually brings the Fleet-managed APM
  integration online there).
- `99-healthcheck.yml` — asserts cluster green with N nodes, Kibana up,
  Fleet Server up (when enabled), APM reachable, and the OTel demo stack
  running.
- `site.yml` — the full chain: bootstrap -> certs -> ES -> security
  bootstrap -> Kibana TLS -> Kibana -> Fleet Server -> OTel
  demo -> Elastic Agent (all hosts) -> health.

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
