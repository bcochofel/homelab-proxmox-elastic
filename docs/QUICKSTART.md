# Quickstart

Get a green Elastic Stack cluster running on Proxmox, end to end. See
[`README.md`](../README.md) for the topology and design decisions, and
[`CONTRIBUTING.md`](../CONTRIBUTING.md) if you're setting this up to
contribute rather than just to run it.

## Prerequisites

- A Proxmox VE node reachable on your LAN, with an Ubuntu Server ISO
  (version depends on what Packer template is used) already uploaded to its
  ISO storage.
- Three Proxmox API tokens, each scoped to least privilege for what it does:
  one for Packer (template builds), one for Terraform (clone/configure VMs),
  and optionally a read-only one for any MCP tooling. See
  [`docs/PACKER.md`](PACKER.md) for the exact `pveum` commands to create the
  Packer token; Terraform's token setup is in [`docs/TERRAFORM.md`](TERRAFORM.md).
- `age` and `sops` installed, plus a `secrets.yaml` at the repo root holding
  the Proxmox tokens and any other credentials the `.envrc` files decrypt
  per directory — see "Secrets management" below for how to set this up.
- `direnv` installed and hooked into your shell.
- `pre-commit` installed if you plan to commit changes (see
  [`CONTRIBUTING.md`](../CONTRIBUTING.md)).

## Secrets management (SOPS + age)

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
that key added as an additional recipient in [`.sops.yaml`](../.sops.yaml)
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
environment variables (`PKR_VAR_*` for Packer, `TF_VAR_*` for Terraform) —
see the specific `.envrc` in each directory for the exact keys it maps.
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

## 0. Prepare the local environment

```bash
make install
```

Pins the CLI binaries this repo needs (`terraform`, `packer`, `trivy`,
`tflint`, `terraform-docs`, `sops`) into `~/bin`, approves the `.envrc`
files (root, `packer/`, `terraform/`, `ansible/`) via direnv, and creates
the `.venv/` Ansible runs from.

## 1. Build the VM template (Packer)

```bash
make packer-init
cd packer/ubuntu-26.04
cp variables.pkrvars.hcl.example variables.auto.pkrvars.hcl   # fill in, gitignored, auto-loaded
packer build .
```

All six VMs in the topology (see [`README.md`](../README.md)) clone from this
one template. See [`packer/ubuntu-26.04/README.md`](../packer/ubuntu-26.04/README.md)
for what it bakes in and why (`packer/ubuntu-24.04/` still exists and builds,
but is no longer what Terraform's `vm_template` default points at).

## 2. Clone VMs and generate the inventory (Terraform)

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
[`docs/TERRAFORM.md`](TERRAFORM.md), including the `pveum` commands to
create the `terraform@pve` token if you haven't already.

## 3. Configure the cluster (Ansible)

```bash
source .venv/bin/activate   # from repo root
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml
```

Runs bootstrap -> Elasticsearch -> Kibana -> APM Server -> OTel demo ->
Elastic Agent (all hosts) -> health check. See
[`docs/ANSIBLE.md`](ANSIBLE.md) for the role/playbook breakdown and the
bootstrap lifecycle (`es_bootstrap_cluster: true` -> `false` after first
green).

## Verify

- Kibana: `http://192.168.68.33:5601`
- Elasticsearch: `http://192.168.68.30:9200`
- APM Server: `http://192.168.68.34:8200`
- OTel demo frontend: `http://192.168.68.35:8080`

## Adding a node

Append to `es_nodes` in `terraform.tfvars`, then `terraform apply`
(regenerates the inventory) followed by `ansible-playbook playbooks/site.yml`
(with `.venv/` activated). Once the cluster is healthy, set
`es_bootstrap_cluster: false` in `ansible/inventory/group_vars/elasticsearch.yml`
and re-run.
