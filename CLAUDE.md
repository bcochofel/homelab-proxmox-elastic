# CLAUDE.md

Project context for Claude Code sessions — **not for humans**: never link or
reference this file from `README.md`, `CONTRIBUTING.md`, `TODO.md`, or
anything under `docs/`. A human contributor's path is root `README.md` ->
`docs/*.md` -> `CONTRIBUTING.md`, with `TODO.md` as the standing
phase-status tracker alongside them. The per-tool READMEs (`packer/README.md`,
`terraform/README.md`, `ansible/README.md`) are deliberately just one-line
pointers to their `docs/<TOOL>.md` — details live in `docs/PACKER.md`,
`docs/TERRAFORM.md`, `docs/ANSIBLE.md`, `docs/QUICKSTART.md`, and
`CONTRIBUTING.md` (branching, commits, versioning, pre-commit), all of
which now exist. `packer/<template>/README.md` (e.g.
`packer/ubuntu-26.04/README.md`) is the one exception that holds real
content — per-template build steps and ADRs — since `packer/` is designed
to hold multiple OS templates over time and its own README stays generic.

## What this is

Elastic Stack observability cluster on Proxmox (MS-01), built with the
Packer -> Terraform -> Ansible pipeline:

```text
Packer (template) -> Terraform (clone VMs + generate inventory) -> Ansible (configure)
```

Topology: 3 Elasticsearch nodes (es-01/02/03, 192.168.68.30-32), 1 Kibana
(192.168.68.33 — also runs Fleet Server, once TLS lands), 1 APM Server
(192.168.68.34), and 1 OpenTelemetry demo VM (192.168.68.35, the upstream
[`open-telemetry/opentelemetry-demo`](https://github.com/open-telemetry/opentelemetry-demo)
compose stack, reconfigured to export traces to the APM Server instead of
its bundled Jaeger/Grafana stack). Each Elastic Stack VM (ES, Kibana, APM
Server) runs a single-container Docker Compose stack; the three ES
containers form one real cluster across their VMs. Every VM in the topology,
including the OTel demo one, also runs a standalone Elastic Agent for OS +
Docker metrics/logs. No Logstash — deliberately out of scope, not just
deferred (see "Decisions that are deliberate"). `192.168.68.30-39` is
reserved for this cluster — additional nodes take the next free IP in range
(`.36`-`.39` currently free).

## Decisions that are deliberate (do not "fix" these)

- **Terraform Provider is `bpg/proxmox`.** Deliberate choice over Telmate. Pin the bpg
  minor version.
- **Terraform State: HCP Terraform**, workspace `elastic-observability`.
- **Compose pattern: identical `docker-compose.yml` + per-node `.env`** (DRY).
  Edit the role templates, never the rendered files on hosts.
- **Cluster formation is inventory-derived.** Terraform writes node IPs into
  `ansible/inventory/hosts.ini`; the ES `.env` template builds `SEED_HOSTS` and
  `INITIAL_MASTER_NODES` from the `elasticsearch` group. This is why the cluster
  self-assembles. The generated inventory also carries `[kibana]`,
  `[apm_server]`, and `[otel_demo]` groups for the other three roles — one
  group per VM role, all derived the same way.
- **Elastic Agent runs standalone, not Fleet-managed, on every VM** (deb
  package pre-installed but disabled by Packer, then Ansible renders
  `elastic-agent.yml` and enables/starts it — see ADR-8 in
  `packer/ubuntu-26.04/README.md`), including the OTel demo VM. Reason:
  Fleet Server needs TLS to enroll agents against,
  and TLS is deliberately deferred to reach a green cluster fast (see
  "Security sequencing" and `TODO.md`). Migrating these agents to
  Fleet-managed mode is itself a planned step *after* Fleet Server comes up
  on the Kibana VM — not part of this change.
- **APM Server is its own VM/compose stack, self-managed** (not the
  Fleet-managed APM integration) — same reasoning as Elastic Agent: Fleet
  isn't live yet. Revisit once Fleet Server + TLS land.
- **No Logstash.** Decided against entirely, not deferred — ingest goes
  straight to Elasticsearch (via Elastic Agent output / ES ingest pipelines).
  Don't propose adding a Logstash role or VM.
- **The OpenTelemetry demo VM is Ansible-managed like every other node**, not
  run ad hoc. Ansible checks out the upstream
  `open-telemetry/opentelemetry-demo` compose project and overrides its OTLP
  exporter env vars (`OTEL_EXPORTER_OTLP_ENDPOINT` /
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) to point at the APM Server VM instead
  of the demo's bundled Jaeger/Grafana/Prometheus stack. It also runs a
  standalone Elastic Agent like the rest of the fleet.
- **Only `hosts.ini` is generated.** `ansible/inventory/group_vars/` is
  hand-authored and must never be overwritten by Terraform.
- **Stack version is pinned in `inventory/group_vars/all.yml`** (`stack_version`), NOT in
  Terraform. Bump there, roll out via playbook.
- **Packer configures the Ubuntu OS with everything the Elastic Stack
  containers need to run** — `vm.max_map_count`, memlock/nofile ulimits, and
  the `/opt/elastic` compose base directory are all baked in via cloud-init
  (`packer/ubuntu-26.04/http/user-data.yml.tpl`). Ansible has zero involvement
  in OS configuration: no variables for any of this exist on the Ansible
  side (not even for verification) — its `common` role only checks Docker
  is present and renders/runs docker-compose. Changing `vm_max_map_count` or
  `elastic_base_dir` means rebuilding the template; `elastic_base_dir` also
  has to stay in sync with `ansible/inventory/group_vars/all.yml`'s copy, since Ansible
  still needs that path to know where to render compose files.
- **Security is OFF for now** (`es_security_enabled: false`). Adding TLS/auth is
  a planned later exercise (local CA via `elasticsearch-certutil`, run-once play).
- **`packer/` holds one subdirectory per OS template** (`ubuntu-24.04/`,
  `ubuntu-26.04/`). Each is self-contained: its own `*.pkr.hcl` +
  `README.md` with build steps/ADRs. `packer/README.md` itself stays
  generic — don't add template-specific content there.
- **All six VMs (ES x3, Kibana, APM Server, OTel demo) clone from the
  `ubuntu-26.04` template**, not `ubuntu-24.04`. `ubuntu-24.04/` still exists
  and still builds — it's just no longer what `terraform/variables.tf`'s
  `vm_template` default points at going forward. Same OS-bakes-in-everything
  approach applies (`vm.max_map_count`, ulimits, `/opt/elastic`) — see
  `packer/ubuntu-26.04/README.md`'s ADRs for how that template got stripped
  down relative to 24.04.
- **`ubuntu-26.04`'s initrd has no networking at all** (dracut's network
  modules are explicitly omitted, `scripts/15-fix-initrd-network.sh`). Not
  optional hardening — the first real `terraform apply` against this
  template had all six VMs come up on the wrong (DHCP) IP because dracut's
  default hostonly mode bundled network modules that raced cloud-init's
  static-IP netplan config and won, since the initrd's own DHCP client
  brought the NIC up first and blocked the rename cloud-init needed. See
  ADR-6 in that README for the full incident before touching this.
- **Every VM installs Trivy and self-scans daily** (`vm_max_map_count`
  sibling: `scripts/30-install-trivy.sh`, ADR-7 in the same README) —
  pinned version, DB pre-cached at build time, cron overwrites a JSON
  report at `trivy_report_path` (default `/var/log/trivy/report.json`).
  This is deliberately not the AIDE/rkhunter-style tooling dropped
  elsewhere in that template (see its ADR-3) — Trivy is stateless, no
  per-clone baseline to initialize. Shipping that JSON into Elasticsearch
  is still open, tracked in `TODO.md`.
- **Terraform and Ansible are decoupled** — no `local-exec` chaining. Run
  `terraform apply` (from `terraform/`) then `ansible-playbook playbooks/site.yml`
  (from `ansible/`) as two separate, explicit commands.
- **The Makefile only has non-mutating targets** (`packer-init`, `tf-init`,
  `ansible-deps`, plus tool install/check). `packer build`, `terraform
  apply`, and `ansible-playbook` are deliberately NOT Makefile targets — run
  them directly, by hand, from their own directory. That keeps the one
  write path a single explicit command instead of a wrapper anyone (or any
  agent) could invoke without thinking, and it's the same command GitHub
  Actions will run later (see "Agent-tooling rollout," step 3).

## Execution environment & tooling decisions

Linux only — Ubuntu, whether that's WSL2 or a native Linux workstation, never
PowerShell. This is currently developed under WSL2 Ubuntu, but nothing here
is WSL2-specific; it should work unchanged on a bare Linux box. Claude Code
must be launched from the repo root so `packer`, `terraform`,
`ansible-playbook` (via `.venv/`), and `sops` resolve correctly. On WSL2
specifically: if `which claude` returns a `/mnt/c/...` path, the install is
on the Windows side and is wrong — reinstall natively inside WSL2 with
`curl -fsSL https://claude.ai/install.sh | bash`, then confirm `which claude`
resolves to a Linux path (e.g. `~/.local/bin/claude`) before relying on it.

Pipeline order is fixed: **Packer → Terraform → Ansible**. Do not skip ahead.
Get a green cluster first, then layer in security and automation.

## Credentials & secrets

- Secrets live in `secrets.yaml`, SOPS-encrypted with **age**. `.sops.yaml` at
  repo root holds the recipient key; the age private key is at
  `~/.config/sops/age/keys.txt` (chmod 600, never in the repo).
- **direnv** loads credentials per-directory. Root `.envrc` decrypts once
  (`sops -d --output-type dotenv secrets.yaml`) and child dirs inherit via
  `source_up`. `packer/`, `terraform/`, `ansible/` each add tool-specific vars.
- direnv runs in the human's shell *before* the agent starts. The Claude Code
  deny rule on `sops -d` restricts the agent, not direnv — both hold.
- Never read, print, echo, `cat`, `head`, `grep`, or `sed` any `.envrc`,
  `secrets.yaml`, or the age key. Reference secrets by variable name only.
- **`secrets.yaml` is meant to be committed** (it's ciphertext — SOPS
  encrypts values in place) — `.sops.yaml` and `.gitleaks.toml` both assume
  this. Never add `secrets.yaml`/`secrets.yml` to `.gitignore`; that was a
  real bug here once (silently blocked the file from ever being committed)
  and got fixed. Only decrypted output (`*.decrypted`, `*.dec.yaml`,
  `secrets.dec.yaml`) should ever be ignored.
- **Editing `secrets.yaml` needs no direnv action** — it reloads
  automatically on next `cd` (or `direnv reload`). **Editing any `.envrc`**
  makes direnv treat it as untrusted (`direnv: error .envrc is blocked`)
  until re-approved — tell the human to run `make direnv-allow` (re-approves
  all four: root, `packer/`, `terraform/`, `ansible/`).

## Proxmox auth — two tokens + a third for MCP

- **packer@pve!packer-automation** — template build rights (`VM.Allocate`, `VM.Config.*`,
  `VM.Monitor`, `VM.PowerMgmt`, `Datastore.Allocate*`, `Sys.Modify`).
- **terraform@pve!terraform-automation** — clone/configure rights + SSH to the PVE node for
  bpg file uploads (`VM.Clone`, `VM.Allocate`, `VM.Config.CDROM`,
  `VM.Config.Cloudinit`, `Datastore.Allocate`, …). `VM.Allocate` and
  `VM.Config.CDROM` are both required even though Terraform only clones
  (never builds) a VM: Proxmox's clone endpoint checks `VM.Allocate`
  against the *destination* VMID rather than just `VM.Clone` on the
  source, and this template's `ide`-bus cloud-init drive (a leftover from
  the Packer build) needs `VM.Config.CDROM` to reconfigure on every clone.
  See `docs/TERRAFORM.md`'s privilege table and incident notes for the
  full list and the two 403s that surfaced these.
- **mcp@pve!mcp** — **read-only** (`VM.Audit`, `Datastore.Audit`, `Sys.Audit`,
  `Pool.Audit`). This token is the real security boundary for the Proxmox MCP
  server; the server's own `PROXMOX_ALLOW_ELEVATED=false` flag is belt-and-
  suspenders, not the guarantee.
- Env var shapes: Packer `PKR_VAR_*`; Terraform `PROXMOX_VE_*` (bpg/proxmox
  reads these directly).

## Terraform Cloud

Remote **state only**. Workspace Execution Mode = **Local**, because Proxmox is
LAN-only and HCP's infra can't reach it. `cloud {}` block (`terraform/versions.tf`)
points at org `homelab-bcochofel-com`, workspace `elastic-observability`.
Always `plan` and show output; never `apply` unprompted; never `destroy`.

## Command permissions (.claude/settings.json)

Committed, shared policy — distinct from `.claude/settings.local.json`
(gitignored, per-session allowlist). Philosophy: local, read-only/validating
checks run freely; anything that actually writes infrastructure requires a
human click every time, for now — the plan is to move those write ops (`packer
build`, `terraform apply`, `ansible-playbook`) behind a GitHub Actions runner
later (see "Agent-tooling rollout," step 3), at which point the agent won't hold the
write credential at all.

- **Allow (no prompt):** `pre-commit run`/`install`; `terraform
  validate/fmt/plan/init/show/output/providers/version/graph/state`; `packer
  validate/init/fmt/version`; `ansible-lint`, `ansible-inventory`,
  `ansible-galaxy collection list` (both bare and via `.venv/bin/`, since
  Ansible only exists inside the virtualenv now), and the known-safe exact
  `ansible-playbook playbooks/site.yml --check`/`--syntax-check` invocations in both
  forms (only those exact strings — flags aren't wildcarded more broadly,
  since prefix-only matching can't safely tell "check" from a real run once
  the args reorder); read-only `git` (`status`, `diff`, `log`, `show`,
  `branch`, `remote -v`); the non-mutating Makefile targets (`help`, `debug`,
  `check`, `install`, `install-binaries`, `clean`, `direnv-allow`,
  `pre-commit-install`, `packer-init`, `tf-init`, `venv`, `ansible-install`,
  `ansible-deps` — none of these touch Proxmox, and there are no Makefile
  targets for the write ops to begin with).
- **Ask (human approval every time):** `packer build`, `terraform apply`,
  any other `ansible-playbook` invocation.
- **Deny outright:** `terraform destroy`, `sops -d`/`sops --decrypt`, and
  `Read()` on `secrets.yaml`, any `.envrc`, and the age key
  (`~/.config/sops/age/keys.txt`).

The `Read()` denies are the real boundary for secret material; the
`sops -d`/`terraform destroy` Bash denies are friction, not a guarantee — a
determined rephrasing of the same command can still slip past a prefix
match. Use the `update-config` skill for future changes here.

## Agent-tooling rollout

Detailed technical notes behind the "Tooling / agent integrations" checklist
in `TODO.md` — that file tracks status (done/not done), this section holds
the how-to and the gotchas. Numbered by rollout order within this track only;
these numbers are independent of `TODO.md`'s infra `Phase N` headings and
don't correspond to them.

1. **GitHub MCP** — official remote server (`https://api.githubcopilot.com/mcp/`,
   `--transport http`, fine-grained PAT scoped to this repo only). Low effort,
   lets the agent read PR checks and workflow logs. Avoid the deprecated
   `@modelcontextprotocol/server-github` npm package.
   `api.githubcopilot.com`'s OAuth endpoint doesn't support the dynamic
   client registration Claude Code tries by default (`claude mcp add` alone
   fails with "Incompatible auth server") — verified empirically, not a
   guess. Use a PAT via header instead, and run the command from the repo
   root (it's local-scope, keyed to cwd — running it from elsewhere silently
   scopes the server to the wrong project):
   `claude mcp add --transport http github https://api.githubcopilot.com/mcp/ --header "Authorization: Bearer <PAT>"`
   `--header` writes the token *verbatim* into `~/.claude.json` — never use
   `--scope project` with a literal token, since that scope's `.mcp.json` is
   committed to git and would leak the PAT. Local scope (the default, this
   repo's project entry in `~/.claude.json`, not committed) is the safe
   choice for a single-machine setup like this one. Verify with
   `claude mcp list` (expect `✔ Connected`).
2. **Proxmox MCP** (optional) — `gilby125/mcp-proxmox` (Node.js, stdio;
   **not published on npm** — confirmed via `registry.npmjs.org`, so
   `npx mcp-proxmox` alone won't resolve). Vet the code and pin a commit
   before running — this is a 49-star,
   67-tool third-party repo with real Proxmox API access (several tools are
   write/exec-capable — `migrate_vm`, `execute_vm_command`, etc. — gated by
   `PROXMOX_ALLOW_ELEVATED`, but the real backstop is `mcp@pve!mcp`'s
   read-only ACL below, which makes those calls fail at the Proxmox API
   regardless of the app-level flag).

   **`npx -y github:gilby125/mcp-proxmox#<sha>` does not work — confirmed by
   running it.** It exits immediately (code 0, no error) instead of starting
   the server, so `claude mcp list` shows "Failed to connect — Connection
   closed." Root cause, isolated by running `node index.js` directly (which
   works) vs. through the `bin` symlink `npx` creates in
   `node_modules/.bin/mcp-proxmox` (which doesn't): `index.js` line ~4901
   gates its entire startup behind
   `if (process.argv[1] === fileURLToPath(import.meta.url))` — a common
   ESM "run as main" guard, except `import.meta.url` resolves through the
   symlink to the real file while `process.argv[1]` stays the symlink path,
   so they never match and the server silently no-ops. This isn't
   environment-specific — it'll fail the same way for anyone installing via
   the package's own declared `bin` entry (i.e. `npx` or `npm i -g`).

   **Working alternative:** clone at the pinned commit and point `command`
   directly at the real `index.js` (no symlink involved):

   ```bash
   git clone https://github.com/gilby125/mcp-proxmox.git ~/.local/share/mcp-proxmox
   cd ~/.local/share/mcp-proxmox && git checkout <pinned-commit-sha> && npm install
   ```

   Create the read-only token first, same `pveum`-on-the-node pattern as
   Packer/Terraform (see "Running `pveum` from WSL2" in `docs/PACKER.md`):

   ```bash
   pveum role add McpReadOnlyRole -privs "VM.Audit,Datastore.Audit,Sys.Audit,Pool.Audit"
   pveum user add mcp@pve --comment "Read-only MCP access"
   pveum aclmod / -user mcp@pve -role McpReadOnlyRole
   pveum user token add mcp@pve mcp --privsep 0
   ```

   Then wire it in (verified flag syntax via `claude mcp add --help` on this
   install — `-e` for env vars, bare `--` before the command; the args after
   `--` are spawned directly, no shell, so use the real absolute path — `~`
   won't expand):

   ```bash
   claude mcp add proxmox \
     -e PROXMOX_HOST=<pve-ip-or-hostname> \
     -e PROXMOX_USER=mcp@pve \
     -e PROXMOX_TOKEN_NAME=mcp \
     -e PROXMOX_TOKEN_VALUE=<token-secret-from-the-pveum-command-above> \
     -e PROXMOX_ALLOW_ELEVATED=false \
     -e PROXMOX_VERIFY_TLS=false \
     -- node /home/<you>/.local/share/mcp-proxmox/index.js
   ```

   Default scope is `local` (not committed) — same reasoning as GitHub MCP:
   never `--scope project` with a literal secret in the args, since that
   scope's `.mcp.json` is committed to git. `PROXMOX_ALLOW_ELEVATED=false`
   is the app-level belt; `mcp@pve!mcp`'s read-only ACL above is the
   suspenders (see "Proxmox auth"). `PROXMOX_VERIFY_TLS=false` matches this
   homelab's self-signed cert, same posture as `proxmox_insecure` in
   Terraform. Verify with `claude mcp list` (expect `✔ Connected`) — this
   exact setup (commit `6186c71`) was confirmed working this way. A
   Metricbeat Proxmox module into our own Elastic cluster is the
   alternative that also teaches the ingest side.
3. **Self-hosted GitHub Actions runner** — move `terraform apply` behind it; the
   runner holds the write credential, the AI agent never does. `apply` gated on
   merge/approval the agent cannot pass.
4. **Custom Elasticsearch MCP server** — written last, exposing `cluster_health`,
   `list_indices`, shard allocation. Design it after operating the cluster, so
   the tools reflect real use.

## Security sequencing (deferred, but planned)

`xpack.security` + TLS are off to reach a green cluster fast. **Fleet enrollment
creates a hard dependency on security being enabled** — plan that transition
deliberately before Fleet becomes viable. When TLS lands, the bootstrap password
and `elastic-certificates.p12` go into SOPS (the pattern is already in place).
Fleet Server then deploys on the Kibana VM, and the standalone Elastic Agents
already running on all six VMs (installed in phase 1) get re-enrolled as
Fleet-managed — that migration, and switching APM ingestion from the
self-managed APM Server to the Fleet-managed APM integration, are both part
of this same later phase, not phase 1. See [`TODO.md`](TODO.md) for current
phase status and what comes after (OSQuery, Proxmox-host telemetry, Trivy
CVE scanning into Elasticsearch, eventual SIEM).

## Custom Trivy/Checkov policies for Proxmox (`policies/`)

Neither Trivy nor Checkov ship built-in checks for `bpg/proxmox` (Aqua's
check DB has no Proxmox category — nor VMware, if a `vsphere_*` check ever
looks tempting to copy from elsewhere). Custom checks live in
`policies/checkov/proxmox_*.yaml` and `policies/trivy/proxmox_*.rego`, one
file per check in both cases (Checkov's YAML loader doesn't support
multi-document files; Rego needs one `package` per file). Full writeup:
`docs/TERRAFORM.md` "Security checks and policy enforcement." Two gotchas
that cost real debugging time once already:

- **Checkov custom checks need an explicit `severity` in `metadata`.**
  `checkov.yaml`'s `check: [MEDIUM, HIGH, CRITICAL]` filter genuinely
  excludes checks below that floor (including ones with no severity at
  all) — despite checkov's own log line claiming severity filtering needs
  an API key. That claim is misleading for custom checks; verified
  empirically.
- **Checkov custom checks work fine standalone but need an *absolute*
  `--external-checks-dir`** when run through `pre-commit`: the
  `terraform_checkov` hook (`antonbabenko/pre-commit-terraform`) `cd`s into
  each changed directory before running `checkov -d .`, so a relative path
  in `checkov.yaml` silently resolves to nothing there — and since there
  were zero applicable checks either way, checkov reported `resource_count:
  0` and the hook always "passed," gating nothing. Fixed by passing
  `--external-checks-dir=__GIT_WORKING_DIR__/policies/checkov` via the
  hook's own `args` in `.pre-commit-config.yaml`.
- **The Trivy Rego side is unverified.** Custom `.rego` checks could not be
  made to fire in the pinned Trivy version (0.72.0) via any documented
  flag combination (`--config-check`, `--check-namespaces`,
  `--raw-config-scanners terraform`) — not even a trivial always-true test
  policy. Matches open community confusion (aquasecurity/trivy discussions
  #6453, #7087). Don't assume `policies/trivy/*.rego` is actually enforced
  until this is resolved; Checkov is the proven-working gate.

`CKV_PROXMOX_1` (require `bios = "ovmf"`) is currently skip-listed in
`checkov.yaml` — a real, deliberately deferred gap (the module doesn't set
`bios` yet), same posture as `xpack.security` above.

## Standing rules

- **Never overwrite `inventory/group_vars/`.** Terraform generates `hosts.ini`
  inventory; `inventory/group_vars/` is hand-authored.
- **DRY compose:** identical `docker-compose.yml` per node type, differentiated
  only by per-node `.env` files (Option A).
- Run `terraform validate` on every change — the provider schema will be
  hallucinated confidently otherwise.
- Elastic Stack specifics may post-date the training cutoff: fetch current
  docs, pin exact image tags, don't generate config schema from memory.

## Bootstrap lifecycle (important)

`es_bootstrap_cluster: true` (in `inventory/group_vars/elasticsearch.yml`) emits
`cluster.initial_master_nodes` for first formation. After the cluster is green
once, set it to `false` and re-run for safe steady state.

## Commands

`make install` is the shift-left entry point — one command prepares
everything a contributor needs: pinned CLI binaries, direnv approval,
pre-commit git hooks, and the Ansible virtualenv + collections. It chains
`check` → `direnv-allow` → `pre-commit-install` → `ansible-deps` (→
`ansible-install` → `venv`).

```bash
make install   # everything below, in one shot
```

Deliberately out of scope for `make install` (install these yourself via
the OS package manager): the `pre-commit`, `checkov`, `direnv`, and `age`
**binaries** themselves — `pre-commit-install` only registers hooks with an
already-installed `pre-commit`, it doesn't install the tool.

Individual pieces, if you need to re-run just one:

```bash
make check            # pinned binaries only (terraform, packer, trivy,
                       # tflint, terraform-docs, sops) into ~/bin
make direnv-allow      # direnv allow . / packer / terraform / ansible
make pre-commit-install # pre-commit install (+ commit-msg stage)
make venv               # create .venv/
make ansible-install    # pip install -r requirements.txt into .venv/
make ansible-deps       # ansible-galaxy collections, via .venv/bin/ansible-galaxy
make packer-init        # packer init . (plugin download, non-mutating)
make tf-init            # one-time: init the HCP Terraform backend + providers
```

`make help` lists every target with a one-line description. The write ops
have no Makefile target — run them directly (Ansible via the venv):

```bash
cd packer/ubuntu-24.04 && packer build .
cd terraform && terraform apply
cd ansible && ../.venv/bin/ansible-playbook playbooks/site.yml
```

## Before first run

1. `make install` (chains binaries, direnv approval, pre-commit hooks, and
   the Ansible virtualenv + collections — see "Credentials & secrets" below
   for what direnv-allow unlocks).
2. Set in tfvars / HCP / env: `target_node` (MS-01 node name), `vm_template`
   (Packer template name), `TF_VAR_proxmox_api_token`, `TF_VAR_cipassword`.

## Open / deferred work

Tracked in [`TODO.md`](TODO.md), not duplicated here — it's the one place
phase status lives (TLS/auth, Fleet, OSQuery, Proxmox-host telemetry, Trivy
CVE scanning, SIEM, and the agent-tooling roadmap). Check items off there as
they land instead of editing this file or `README.md`.
