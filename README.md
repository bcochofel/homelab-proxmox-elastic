# homelab-proxmox-elastic

Elastic Stack observability cluster on Proxmox (MS-01), built with an IaC
pipeline:

```text
Packer (template)  ->  Terraform (clone VMs + generate inventory)  ->  Ansible (configure)
```

## Quickstart

Get a green Elastic Stack cluster running on Proxmox, end to end. See
[Design decisions](#design-decisions) below for topology and rationale, and
[`CONTRIBUTING.md`](CONTRIBUTING.md) if you're setting this up to
contribute rather than just to run it.

### Prerequisites

- A Proxmox VE node reachable on your LAN, with an Ubuntu Server ISO
  (version depends on what Packer template is used) already uploaded to its
  ISO storage.
- Three Proxmox API tokens, each scoped to least privilege for what it does:
  one for Packer (template builds), one for Terraform (clone/configure VMs),
  and optionally a read-only one for any MCP tooling. See
  [`docs/PACKER.md`](docs/PACKER.md) for the exact `pveum` commands to create
  the Packer token; Terraform's token setup is in
  [`docs/TERRAFORM.md`](docs/TERRAFORM.md).
- `age` and `sops` installed, plus a `secrets.yaml` at the repo root holding
  the Proxmox tokens and any other credentials the `.envrc` files decrypt
  per directory — see "Secrets management" below for how to set this up.
- `direnv` installed and hooked into your shell.
- `pre-commit` installed if you plan to commit changes (see
  [`CONTRIBUTING.md`](CONTRIBUTING.md)).

### Secrets management (SOPS + age)

Every credential this repo needs — Proxmox API tokens, the cloud-init
password hash, etc. — lives in one file, `secrets.yaml` at the repo root,
encrypted at rest with [SOPS](https://github.com/getsops/sops) using an
[age](https://github.com/FiloSottile/age) key. Unlike most `secrets.*`
naming conventions, **this file is meant to be committed** — SOPS encrypts
the values in place, so the file in git is ciphertext, safe to version
alongside the code that needs it (`.gitleaks.toml` allowlists it explicitly
for that reason, and it's exempt from `.gitignore`). What must never be
committed is the age *private* key or a decrypted copy of the file — both
are covered by `.gitignore` (`*.agekey`, `keys.txt`, `*.decrypted`,
`*.dec.yaml`, `secrets.dec.yaml`).

**First-time setup (generating your own age key):**

```bash
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

This prints an age public key (`age1...`). For an existing repo, either get
that key added as an additional recipient in [`.sops.yaml`](.sops.yaml)
(SOPS supports multiple comma-separated recipients per rule, so more than
one person/machine can decrypt the same file), or use the private key you
were handed out-of-band by whoever bootstrapped the repo's secrets.

**Creating or editing `secrets.yaml`:**

```bash
sops secrets.yaml
```

This decrypts into a temp file, opens your `$EDITOR`, and re-encrypts on
save — you never see or handle ciphertext directly. If the file doesn't
exist yet, SOPS creates it fresh, encrypting it according to the matching
`creation_rules` entry in `.sops.yaml` (path regex `secrets\.ya?ml$`).

**Viewing decrypted content (read-only):**

```bash
sops -d secrets.yaml
```

**How `direnv` uses it:** each directory's `.envrc` runs something like
`sops -d --output-type dotenv secrets.yaml` and exports the result as
environment variables (`PKR_VAR_*` for Packer, `TF_VAR_*` for Terraform,
plain names like `ELASTIC_PASSWORD`/`KIBANA_SYSTEM_PASSWORD` for Ansible,
which has no built-in `X_VAR_*` convention of its own) — see the specific
`.envrc` in each directory for the exact keys it maps.
Once `secrets.yaml` exists and your age key can decrypt it, `direnv allow`
(via `make install`) is all that's needed for those variables to appear
automatically when you `cd` into `packer/`, `terraform/`, etc.

**After editing `secrets.yaml` itself:** no action needed — direnv re-runs
`.envrc` (and re-decrypts) automatically the next time you `cd` into a
directory, or immediately via `direnv reload`.

**After editing any `.envrc` file** (root, `packer/`, `terraform/`, or
`ansible/`): direnv treats a changed `.envrc` as untrusted and blocks it
(`direnv: error .envrc is blocked`) until it's re-approved. Re-run:

```bash
make direnv-allow
```

This re-approves all four `.envrc` files at once (`direnv allow .` /
`packer` / `terraform` / `ansible`), so it's safe to run any time you're not
sure — it doesn't matter which one actually changed.

### 0. Prepare the local environment

```bash
make install
```

Pins the CLI binaries this repo needs (`terraform`, `packer`, `trivy`,
`tflint`, `terraform-docs`, `sops`) into `~/bin`, approves the `.envrc`
files (root, `packer/`, `terraform/`, `ansible/`) via direnv, and creates
the `.venv/` Ansible runs from.

### 1. Build the VM template (Packer)

```bash
make packer-init
cd packer/ubuntu-26.04
cp variables.pkrvars.hcl.example variables.auto.pkrvars.hcl   # fill in, gitignored, auto-loaded
packer build .
```

All six VMs in the topology (see [Topology](#topology) below) clone from
this one template. See
[`packer/ubuntu-26.04/README.md`](packer/ubuntu-26.04/README.md) for what it
bakes in and why (`packer/ubuntu-24.04/` still exists and builds, but is no
longer what Terraform's `vm_template` default points at).

### 2. Clone VMs and generate the inventory (Terraform)

```bash
cd terraform
cp example.tfvars terraform.tfvars   # edit, or set the equivalent HCP workspace variables
export TF_VAR_proxmox_api_token='terraform@pve!tf=...'
export TF_VAR_cipassword='...'
make tf-init      # from repo root, one-time
terraform plan    # review before applying
terraform apply
```

This clones the Packer template into all six VMs (es-01/02/03, kibana,
apm-server, otel-demo), assigns static IPs, and writes
`ansible/inventory/hosts.ini` with one group per role — see
[`docs/TERRAFORM.md`](docs/TERRAFORM.md), including the `pveum` commands to
create the `terraform@pve` token if you haven't already.

### 3. Configure the cluster (Ansible)

```bash
source .venv/bin/activate   # from repo root
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml
```

Runs bootstrap -> Elasticsearch -> Kibana -> Fleet Server -> OTel demo ->
Elastic Agent (all hosts, Fleet enrollment — this is also what brings the
Fleet-managed APM integration online on the apm-server host) -> health
check. See [`docs/ANSIBLE.md`](docs/ANSIBLE.md) for the role/playbook
breakdown.

**First run against a brand-new cluster** (empty ES data volumes, no prior
cluster state): the checked-in `es_bootstrap_cluster: false` in
`inventory/group_vars/elasticsearch.yml` won't bootstrap it — that value
tracks this homelab's own already-formed cluster, not a fresh one. Override
it on the CLI for that one run instead of editing the committed file:

```bash
ansible-playbook playbooks/site.yml -e es_bootstrap_cluster=true
```

Confirm `_cluster/health` reaches green, then re-run **without** the
override — the checked-in `false` is already correct for steady state, so
there's nothing to revert. See [`docs/ANSIBLE.md`](docs/ANSIBLE.md)'s
Bootstrap lifecycle section for the full explanation. Note this is a
different flag from `security_rollout` (below) — a from-scratch bootstrap
needs `es_bootstrap_cluster=true` and does **not** need
`security_rollout=true`, since every node comes up already secured from its
first-ever start (no mixed-security window to protect against — that flag
matters only for flipping security on an already-live cluster).

**Security is on by default** (`es_security_enabled: true`), so a
from-scratch run also needs `ELASTIC_PASSWORD` and `KIBANA_SYSTEM_PASSWORD`
set in `secrets.yaml` and exported from `ansible/.envrc` first — a preflight
check fails loudly and early if either is missing. See
[`docs/ANSIBLE.md`](docs/ANSIBLE.md)'s "TLS + auth" section.

Once done, see [Verify](#verify) below.

### Adding a node

Append to `es_nodes` in `terraform.tfvars`, then `terraform apply`
(regenerates the inventory) followed by `ansible-playbook playbooks/site.yml`
(with `.venv/` activated). The new node joins the existing cluster via
discovery — no bootstrap override needed, since `es_bootstrap_cluster` stays
at its checked-in `false`.

## Topology

| VM         | vCPU | RAM  | Disk | Role                           | IP            |
| ---------- | ---- | ---- | ---- | ------------------------------ | ------------- |
| es-01      | 2    | 8 GB | 60 G | Elasticsearch (master+data)    | 192.168.68.30 |
| es-02      | 2    | 8 GB | 60 G | Elasticsearch (master+data)    | 192.168.68.31 |
| es-03      | 2    | 8 GB | 60 G | Elasticsearch (master+data)    | 192.168.68.32 |
| kibana     | 2    | 4 GB | 30 G | Kibana + Fleet Server          | 192.168.68.33 |
| apm-server | 2    | 2 GB | 20 G | APM (Fleet-managed integration)| 192.168.68.34 |
| otel-demo  | 2    | 4 GB | 30 G | OpenTelemetry demo             | 192.168.68.35 |

`192.168.68.30-39` is reserved for this cluster; additional nodes should take
the next free IP in that range (`.36`-`.39` currently free). No Logstash node
— deliberately out of scope.

Each ES/Kibana VM runs a single-container Docker Compose stack. The three
ES containers form one real multi-node cluster across the VMs. Heap is
4 GB/node (≤50% RAM). `otel-demo` runs the upstream
[open-telemetry/opentelemetry-demo](https://github.com/open-telemetry/opentelemetry-demo)
compose stack, reconfigured to export traces to the APM endpoint instead of
its bundled Jaeger/Grafana/Prometheus stack. Every VM in the topology runs
a Fleet-managed Elastic Agent for OS + Docker metrics/logs — the
apm-server host's agent additionally runs the APM integration, which is
what actually ingests those traces (no separate `apm-server` container).

## Verify

- Kibana: `https://kibana.homelab.bcochofel.com` — a real Let's Encrypt
  certificate (DNS-01 via Cloudflare), not the cluster's own self-signed CA,
  since this is the one endpoint humans hit in a browser. Port 5601 is no
  longer published on the host — only 443 is. See `docs/ANSIBLE.md`'s
  "Kibana TLS (Let's Encrypt)" section
- Elasticsearch: `https://192.168.68.30:9200`
- APM: `http://192.168.68.34:8200` — the Fleet-managed APM integration on
  the apm-server host's Elastic Agent, not a standalone container. Not
  TLS-fronted itself; only its connection *to* Elasticsearch is (via
  Fleet's own output config)
- OTel demo frontend: `http://192.168.68.35:8080`

Elasticsearch presents a self-signed cert from this cluster's own CA
(`ansible/.certs/ca.crt` on the machine that ran the Ansible rollout, not
committed to git) — expect a browser/`curl` warning if you hit ES directly,
or pass `--cacert ansible/.certs/ca.crt` (or `-k` to skip verification).

## Exploring the data in Kibana

Login as `elastic` — password is `ELASTIC_PASSWORD` in `secrets.yaml`
(SOPS-encrypted; decrypt with your own age key, or ask whoever holds it).
Once the cluster is green, the OTel demo's `load-generator` keeps producing
live traffic continuously, so there's always fresh data to look at.

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
- **Security:** `xpack.security.enabled: true` — ES transport + HTTP TLS via
  a local CA, `elastic`/`kibana_system` credentials. Toggled by
  `es_security_enabled` in `inventory/group_vars/all.yml`; see
  `docs/ANSIBLE.md` for the cert generation/rollout mechanics.
- **Decoupling:** Terraform and Ansible are run as separate, explicit
  commands — no `local-exec` chaining, and no Makefile wrapper around
  either write step, so the one command that actually changes
  infrastructure always stays visible and explicit.
- **Elastic Agent:** Fleet-managed on every VM (Phase 3, complete) — deb
  package pre-installed by Packer, enrolled by the `elastic_agent` role
  (one-way migration, no standalone mode left). ES output credentials come
  from Fleet enrollment, not a manually-minted API key.
- **APM:** the Fleet-managed APM integration, running as part of the
  apm-server host's own Elastic Agent — no separate self-managed
  `apm-server` container anymore.
- **No Logstash:** decided against entirely, not deferred. Ingest goes
  straight to Elasticsearch.
- **Template:** all six VMs clone from the `ubuntu-26.04` Packer template.

## Documentation

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
