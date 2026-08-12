# Terraform — Elastic observability cluster on Proxmox (bpg/proxmox)

Clones the Packer template (`ubuntu-26.04`, for every VM in the topology)
into five VMs — es-01/02/03, kibana, apm-server — assigns static
IPs via cloud-init, and generates `../ansible/inventory/hosts.ini`.

| VM | Role | IP | Ansible group |
| --- | --- | --- | --- |
| es-01/02/03 | Elasticsearch (master+data) | 192.168.68.30-32 | `elasticsearch` |
| kibana | Kibana (+ Fleet Server, once TLS lands) | 192.168.68.33 | `kibana` |
| apm-server | APM Server | 192.168.68.34 | `apm_server` |

`192.168.68.30-39` is reserved for this cluster; `.35`-`.39` are free for
future nodes. No Logstash node — deliberately out of scope, not deferred.

- `modules/vm/` — reusable single-VM clone (any role: ES, Kibana, APM
  Server). Renamed from `modules/elastic_node/` once it stopped
  being Elastic-Stack-exclusive — the module itself never was
  role-specific, it just clones the template with a static IP; role
  differs only in the `tags` passed in and which Ansible group the node
  lands in.
- `templates/inventory.ini.tftpl` — renders the Ansible inventory (INI
  format): `[elasticsearch]`, `[kibana]`, `[apm_server]`
  groups, one per VM role. Derives `es_seed_hosts` and
  `es_initial_master_nodes` from the `elasticsearch` group's IPs — that's
  what lets the ES cluster self-assemble. The other two groups are single
  hosts with no derived vars of their own (yet).
- State: HCP Terraform workspace `elastic-observability` (state only —
  Execution Mode is Local, since Proxmox is LAN-only and HCP's infra can't
  reach it).

Decoupled from Ansible by design — run `terraform apply`, then the Ansible
playbooks separately (no `local-exec` chaining).

Always `terraform plan` and review the output before applying; never
`destroy`.

## Configuration: `example.tfvars` vs `terraform.tfvars` vs secrets

Three different places feed this module's inputs, split by sensitivity:

- **`example.tfvars`** — committed to git. The root `.gitignore` blanket-
  ignores `*.tfvars`, then explicitly re-includes this one file
  (`!example.tfvars`), so it's the one `.tfvars` that's actually meant to be
  checked in. It's a template with realistic placeholder values for every
  *non-secret* input (`target_node`, `vm_template`, `cluster_name`,
  `gateway`, `network_bridge`, `nameserver`, `searchdomain`, `ciuser`, an
  example `sshkeys` value) plus the node-shape defaults (`es_nodes`,
  `kibana_node`). Never put a real secret in it — edit it only to change
  the example values everyone starts from.
- **`terraform.tfvars`** — what you actually run against. Gitignored
  (`terraform/terraform.tfvars` is listed explicitly, on top of the
  blanket `*.tfvars` rule). Create it once with
  `cp example.tfvars terraform.tfvars`, then fill in your real
  `target_node` and a real `sshkeys` value (not the placeholder), plus any
  `es_nodes`/`kibana_node`/new-node overrides you need. `sshkeys` is the
  one Terraform input in this module that's *not* marked `sensitive` in
  `variables.tf` — that's exactly why it belongs here rather than
  `secrets.yaml`/`.envrc`: it's a public key, there's nothing to encrypt.
- **`secrets.yaml` + `terraform/.envrc`** — everything Terraform treats as
  `sensitive` (`proxmox_api_token`, `cipassword`), plus the unrelated
  Terraform Cloud auth token (`TF_TOKEN_app_terraform_io`, read by the
  Terraform CLI itself, not by any `var.*`). These never touch a `.tfvars`
  file — they arrive purely as `TF_VAR_*` env vars via direnv. See
  "Proxmox user & API token" below for `proxmox_api_token`; `cipassword`
  needs its own `secrets.yaml` entry (there's no built-in default for it,
  and unlike `sshkeys` it's genuinely secret — it's the cloud-init login
  password for the VM user, a fallback alongside SSH keys).

Terraform picks up `terraform.tfvars` and `TF_VAR_*` env vars automatically
— no `-var-file` flag needed, just run `terraform plan`/`apply` from
`terraform/`.

## Proxmox user & API token

Terraform authenticates as its own Proxmox user/token, separate from the
Packer and MCP tokens (see `CLAUDE.md`'s "Proxmox auth" section) — least
privilege per tool. Current token id: `terraform@pve!terraform-automation`
(matching Packer's `packer@pve!packer-automation` naming convention).

`pveum` only exists on the Proxmox node itself — see
[`docs/PACKER.md`](PACKER.md#proxmox-user--api-token) for the three ways to
run it (SSH into the node, the web UI's Datacenter -> Permissions, or the
node's own web Shell); the same options apply here.

```bash
# 1. Role scoped to what Terraform actually does: clone the Packer
#    template, size/network/cloud-init the clone, and read template/VM
#    state. Not building or templating — that's Packer's job.
pveum role add TerraformRole -privs "VM.Allocate,VM.Audit,VM.Clone,\
VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,\
VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.Monitor,VM.PowerMgmt,Datastore.Allocate,Datastore.AllocateSpace,\
Datastore.Audit,SDN.Use"

# 2. User for the role (no password; auth is via API token only)
pveum user add terraform@pve --comment "Terraform VM clone/configure"
pveum aclmod / -user terraform@pve -role TerraformRole

# 3. API token. --privsep 0: the token inherits the user's ACL directly.
pveum user token add terraform@pve terraform-automation --privsep 0
```

The last command prints the token secret once — it is not retrievable
again. Put `terraform@pve!terraform-automation` and the printed secret into
`secrets.yaml` (SOPS-encrypted) so `terraform/.envrc` can export
`TF_VAR_proxmox_api_token` in the combined `user@realm!tokenid=secret` form
`variables.tf` expects:

```bash
export TF_VAR_proxmox_endpoint="${PROXMOX_ENDPOINT}"
export TF_VAR_proxmox_api_token="${proxmox_terraform_token_id}=${proxmox_terraform_token_secret}"
export TF_VAR_cipassword="${cloudinit_password}"
```

(`proxmox_terraform_token_id`/`_secret` and `cloudinit_password` are the
`secrets.yaml` keys — a split id/secret pair, matching Packer's
`proxmox_packer_token_id`/`_secret` convention, rather than one combined
value.)

| Privilege | Why Terraform needs it |
| --- | --- |
| `VM.Allocate` | Required on the *destination* VMID for every clone, not just fresh-built VMs — Proxmox's clone endpoint checks `VM.Clone` on the source template but `VM.Allocate` on the new VMID, since claiming a not-yet-existing VM ID is an "allocate" regardless of whether the VM ends up empty or cloned. Confirmed empirically: omitting it makes every `proxmox_virtual_environment_vm` clone fail identically with `HTTP 403 Permission check failed`, even though `VM.Clone` is granted — see the incident note below. |
| `VM.Audit` | Look up the template's VMID by name (`data.proxmox_virtual_environment_vms.template`), read VM state while polling for the cloud-init-assigned IP |
| `VM.Clone` | Read/export permission on the *source* template for each of the six clones |
| `VM.Config.CDROM` | The `ubuntu-26.04` template carries a leftover `ide`-bus slot from the Packer build; bpg's `initialization` block reconfigures the cloud-init drive on that same bus on every clone, which Proxmox checks under the CD-ROM permission bucket regardless of actual media type. Confirmed empirically — see the incident note below. |
| `VM.Config.CPU`, `VM.Config.Memory`, `VM.Config.Disk`, `VM.Config.HWType`, `VM.Config.Network` | Set cores, memory, resize the cloned disk, attach the network device |
| `VM.Config.Cloudinit` | Write the static IP/gateway, DNS, and cloud-init user-account config each clone boots with |
| `VM.Config.Options` | Set description/tags on the clone |
| `VM.Monitor`, `VM.PowerMgmt` | Start the clone and poll the QEMU guest agent until it reports an IP |
| `Datastore.Allocate`, `Datastore.AllocateSpace` | Allocate the cloned VM's disk + cloud-init drive on `datastore_id` |
| `Datastore.Audit` | Read storage info |
| `SDN.Use` | Attach each VM's NIC to `vmbr0` — same reason Packer needs it: required once the bridge is managed as an SDN zone |

Not granted: anything from Packer's role that's about *building* a template
from an ISO (`VM.Console`, `Datastore.AllocateTemplate`, `Sys.Modify`) —
Terraform only ever clones an already-built template, it never creates one.
Two privileges sound template-building-specific but aren't, both confirmed
by hitting the actual 403s (see the incident notes below):

- `VM.Allocate` is checked against the clone's *destination* ID, not just
  the build path.
- `VM.Config.CDROM` is checked whenever the clone's `ide`-bus cloud-init
  drive gets reconfigured, because this template's `ide` slot was left
  over from the Packer build rather than being clean.

**Incident 1, since fixed — missing `VM.Allocate`:** the role above
originally shipped without `VM.Allocate` (the reasoning was "Terraform only
clones, it doesn't build templates, so it doesn't need allocate privileges"
— half right, but the destination-ID check still applies to clones).
`terraform apply` failed on all six `module.*.proxmox_virtual_environment_vm.this`
resources simultaneously with `Error: VM clone` / `HTTP 403 Permission check
failed`, even though `pveum acl list` showed `TerraformRole` correctly
attached to `terraform@pve` at `/` (propagate=1) and the token had
`privsep=0` (so it inherits the user's ACL). All six failing at once, rather
than one-off, was the tell that this was a role/privilege gap rather than a
per-VM or token-wiring issue. Fixed via `pveum role modify TerraformRole
-privs "...,VM.Allocate"` on the Proxmox node; no ACL or token changes
needed.

**Incident 2, since fixed — missing `VM.Config.CDROM`:** with `VM.Allocate`
in place, cloning itself succeeded, but `terraform apply` then failed on all
six resources again with `Error: ... HTTP 403 Permission check failed
(/vms/<vmid>, VM.Config.CDROM)` while bpg's `initialization` block
reconfigured each clone's cloud-init drive. Same signature as incident 1 —
every VM failing identically — so the same "check the role's privilege
list first" approach applied. Fixed the same way: `pveum role modify
TerraformRole -privs "...,VM.Config.CDROM"`.

`providers.tf`'s `ssh { agent = true, username = var.proxmox_ssh_username }`
block is configured but not currently exercised — this repo's cloud-init
only sets IP/DNS/user-account via the API (`initialization` block), no
custom snippet/file upload. Leave it enabled; some cloud-init file
operations (should one get added to a future node) do require SSH.

## Security checks and policy enforcement

Terraform under `terraform/` is scanned by TFLint, Trivy, and Checkov (see
[`CONTRIBUTING.md`](../CONTRIBUTING.md)'s pre-commit section). Trivy and
Checkov ship no built-in checks for the `bpg/proxmox` provider — Aqua's
check database (`avd.aquasec.com`) has no Proxmox category (nor a VMware
one, for what it's worth), so anything Proxmox-specific has to be a custom
check. Custom policies live under `policies/`:

- `policies/checkov/proxmox_*.yaml` — one file per check, targeting
  `proxmox_virtual_environment_vm`: UEFI firmware (`bios = "ovmf"`,
  MEDIUM), the QEMU guest agent enabled (MEDIUM), a `description` set
  (LOW), and the modern `q35` machine type (LOW). Verified working end to
  end, including through the actual `terraform_checkov` pre-commit hook.
  `checkov.yaml`'s `check: [MEDIUM, HIGH, CRITICAL]` genuinely filters which
  checks run — despite checkov's own "Filtering checks by severity is only
  possible with an API key" log line, that's confirmed empirically to be
  misleading for custom checks: a check with no `severity` (or one below
  the configured floor) in its metadata is silently excluded, not merely
  unfiltered. The two LOW checks here (description, machine type) are
  intentionally not enforced as a result. Of the two MEDIUM ones,
  `CKV_PROXMOX_4` (guest agent) passes; `CKV_PROXMOX_1` (UEFI) is a real,
  unaddressed gap — `bios` isn't set to `"ovmf"` in
  `modules/vm/main.tf` — and is deliberately skip-listed in
  `checkov.yaml` for now (matching this project's existing pattern of
  phasing in hardening rather than blocking on it immediately, e.g.
  `xpack.security` being off). Remove the skip once the module sets
  `bios = "ovmf"` (and, per `PROXMOX-004`, an `efi_disk` block).
- `policies/trivy/proxmox_*.rego` — the same intent, written as Trivy custom
  Rego checks (one package per file, per Trivy's documented convention),
  plus two provider-level checks (no hardcoded `api_token`, no `insecure =
  true`). **Caveat:** custom Rego checks could not be confirmed to actually
  fire against this repo's installed Trivy version (0.72.0) via the
  documented `--config-check`/`--check-namespaces`/`--raw-config-scanners`
  flags — even a trivial always-true test policy produced no result. This
  matches known, still-open community confusion around Trivy's custom-check
  plumbing (see aquasecurity/trivy discussions #6453 and #7087). Treat these
  `.rego` files as accurate-but-unverified until that's resolved.

**Fixed:** the `terraform_checkov` pre-commit hook was silently a no-op for
this provider. `antonbabenko/pre-commit-terraform`'s hook script `cd`s into
each changed directory before running `checkov -d .`, so `checkov.yaml`'s
`external-checks-dir: policies/checkov` (a relative path) resolved to
nothing once invoked that way — and since neither Trivy nor Checkov ship
any built-in Proxmox checks, checkov had zero applicable checks for
`proxmox_virtual_environment_vm` and reported `resource_count: 0`,
appearing to "pass" while scanning nothing. The hook now passes
`--external-checks-dir=__GIT_WORKING_DIR__/policies/checkov` as an absolute
path directly (see `.pre-commit-config.yaml`), matching how the TFLint and
Trivy hooks already handle their own config paths.
