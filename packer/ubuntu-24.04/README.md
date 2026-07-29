# Packer — Ubuntu 24.04 + Docker template

Builds a cloud-init-ready Ubuntu 24.04 template with Docker + Compose plugin
baked in. Security hardening (auditd, AIDE, lynis, rkhunter), SSH hardening,
and unattended-upgrades are configured via autoinstall.

`vm.max_map_count`, memlock/nofile ulimits, and the `/opt/elastic` compose
base directory are baked in here via cloud-init (`http/user-data.yml.tpl`),
tunable through the `vm_max_map_count`/`elastic_base_dir` variables. Changing
either value means rebuilding the template.

## Build

```bash
cp variables.pkrvars.hcl.example variables.pkrvars.hcl   # fill in, gitignored
make packer-init                 # non-mutating: packer init . (plugin download)
cd packer/ubuntu-24.04 && packer build .   # run directly from this directory
```

Provisioning runs in a fixed order (`scripts/00-` through `99-`): proxy config,
custom CA import, Docker install, then a security baseline
(`80-security-scans.sh` initializes the AIDE database and records the
rkhunter file-property baseline — without it the timers installed via
autoinstall would compare against a database that never existed) before
`99-cleanup-seal.sh` seals the template.

Proxmox user/token setup is shared across templates — see
[`../../docs/PACKER.md`](../../docs/PACKER.md).

## What it builds

A `proxmox-iso` source boots an Ubuntu 24.04 Server ISO, autoinstalls via
cloud-init (`http/user-data.yml.tpl` + `http/meta-data.yml` served over the
Packer HTTP server), then a chain of provisioner scripts configures the
image before it's converted to a Proxmox template. Terraform later clones
this template per node (see `docs/TERRAFORM.md`, once written).

```
ISO boot --autoinstall--> cloud-init (users, disk layout, packages,
  sysctl/limits, SSH hardening, security-tool timers)
    --provisioners--> proxy config -> custom CA -> Docker install
    --provisioners--> AIDE/rkhunter baseline -> cleanup & seal
```

## File map

| File | Role |
| --- | --- |
| `ubuntu-24.04.pkr.hcl` | `source` (Proxmox connection, VM shape, boot) + `build` (provisioner order) |
| `variables.pkr.hcl` | Every input variable, grouped by concern |
| `locals.pkr.hcl` | Renders `http/user-data.yml.tpl` into `local.user_data` |
| `versions.pkr.hcl` | Packer core + `hashicorp/proxmox` plugin version pins |
| `http/user-data.yml.tpl` | cloud-init autoinstall: disk layout (LVM), users, SSH hardening, security-tool systemd timers, **OS config for Elastic Stack** |
| `http/meta-data.yml` | cloud-init meta-data (mostly empty; required by the datasource) |
| `scripts/00-configure-proxy.sh` | Optional system-wide HTTP(S) proxy, incl. a docker.service drop-in |
| `scripts/10-install-custom-ca.sh` | Imports `custom-ca/*.crt`/`*.pem` if present (no-op otherwise) |
| `scripts/20-install-docker.sh` | Docker CE + Compose plugin, qemu-guest-agent |
| `scripts/80-security-scans.sh` | Initializes the AIDE database + rkhunter baseline (see ADR-4) |
| `scripts/99-cleanup-seal.sh` | Strips machine-id/SSH host keys/logs/cloud-init state before conversion to template |
| `custom-ca/` | Drop custom root CA `.crt`/`.pem` files here; picked up automatically |
| `variables.pkrvars.hcl.example` | Copy to `variables.pkrvars.hcl` (gitignored) and fill in |

## Decisions (ADRs)

### ADR-1: OS dependencies for Elastic Stack are baked in here, not by Ansible

**Context.** Elasticsearch-in-Docker needs `vm.max_map_count >= 262144` and
raised memlock/nofile limits on the host, plus a directory for the
docker-compose projects to live in. The original design put this in an
Ansible `common` role so it stayed tunable without a Packer rebuild.

**Decision.** Moved to cloud-init in `http/user-data.yml.tpl`:
`/etc/sysctl.d/90-elasticsearch.conf`, `/etc/security/limits.d/90-elasticsearch.conf`,
and `mkdir -p ${elastic_base_dir}` all run at first boot, driven by the
`vm_max_map_count`/`elastic_base_dir` Packer variables. Ansible's `common`
role has zero involvement in OS configuration — no `vm_max_map_count`
variable exists on the Ansible side at all, not even to verify it. It only
checks Docker and the Compose plugin are present before the ES/kibana roles
render docker-compose files.

**Consequences.** Changing `vm_max_map_count` means rebuilding the template,
full stop — there's no Ansible-side check that would catch a template built
against a stale value. `elastic_base_dir` is the one value still duplicated:
Packer bakes the directory, and `ansible/group_vars/all.yml` needs the same
path to know where to render compose files, so that one has to be kept in
sync by hand. This trade-off was made deliberately: every VM boots ready to
run Elasticsearch immediately, and Ansible's job is reduced to "render
docker-compose.yml/.env and run `docker compose up`," nothing host-level.

### ADR-2: Provisioning scripts are numbered and ordered, not roles

Packer has no equivalent of Ansible roles/handlers, so provisioner ordering
*is* the dependency graph: proxy must land before anything that hits the
network (Docker install), the custom CA before anything that needs it, and
the security baseline (AIDE init, rkhunter propupd) must run after the
security packages are installed by autoinstall but before `99-cleanup-seal.sh`
truncates logs and clears `/var/lib/cloud`. The `NN-` prefixes exist purely
to make that order legible in a directory listing; there's no dynamic
dispatch.

### ADR-3: Security hardening lives partly in cloud-init, partly in scripts

Package installation, SSH hardening (`sshd_config.d/99-hardening.conf`),
unattended-upgrades config, and the rkhunter/chkrootkit/lynis/AIDE **systemd
timers** are all declared in `http/user-data.yml.tpl` because they're
static file content cloud-init is good at writing. Anything that needs a
running system to act on (installing Docker's apt repo and packages, custom
CA import, initializing AIDE's database) is a shell provisioner instead,
because cloud-init's `runcmd` block only runs once at first boot of the
*clone*, not during the Packer build — and the whole point is to do this
work once, in the template, not on every clone.

### ADR-4: Why `80-security-scans.sh` exists

The security packages (`rkhunter`, `chkrootkit`, `lynis`, `aide`,
`aide-common`) and their systemd timers are installed via autoinstall, but
none of them have anywhere to compare *against* on first run — AIDE has no
database, and rkhunter has no recorded baseline of expected file properties.
Without initializing both during the build, the first real scan on every
cloned VM would flag the entire filesystem as "new"/"changed," which is
noise, not signal. `80-security-scans.sh` runs `aideinit`/`aide --init` and
`rkhunter --propupd` once, in the template, so the baseline reflects the
sealed image rather than whatever happened to exist after cloud-init ran on
a fresh clone.

### ADR-5: No Alloy or system_report provisioning

Host telemetry shipping (Grafana Alloy) and a compliance-scan tool
(`system_report`) are not part of this template. Neither is needed for this
workload (Elastic Stack's own stack handles observability of itself; a
Metricbeat/Elastic Agent module is the planned path for Proxmox host
telemetry). A `system_report` provisioner
shape is left commented out in `ubuntu-24.04.pkr.hcl` as a starting point if
ever wanted — commented out, not deleted, because it's inert until uncommented
and there's no live reference to break. Anything for Alloy should be added
fresh (script + variables) rather than resurrected from a commented block,
since a referenced-but-missing script/variable is a build break waiting to
happen, not a harmless no-op.

## Variables reference

Required (no default — set via `variables.pkrvars.hcl` or `PKR_VAR_*` env):

| Variable | Source in this repo |
| --- | --- |
| `proxmox_api_url`, `proxmox_api_token_id`, `proxmox_api_token_secret`, `proxmox_node`, `proxmox_skip_tls_verify` | `packer/.envrc` (`PKR_VAR_*`, decrypted from `secrets.yaml` via SOPS + direnv) |
| `password_hash` | `variables.pkrvars.hcl` — generate with `mkpasswd -m sha-512 '<password>'` |
| `ssh_private_key_file` | `variables.pkrvars.hcl` — must pair with a key in `ssh_authorized_keys` |

Everything else (VM sizing, packages, timezone, NTP, proxy, `vm_max_map_count`,
`elastic_base_dir`, …) has a default in `variables.pkr.hcl` and only needs
overriding in `variables.pkrvars.hcl` when it should differ from that default.

## Known coupling to watch

- `elastic_base_dir` (here) must match `elastic_base_dir` in
  `ansible/group_vars/all.yml` — Ansible still needs that path, unlike
  `vm_max_map_count` which is Packer-only (see ADR-1).
- `username` here must match the `ansible_user` Terraform writes into the
  generated inventory, since Ansible connects as that user.
- `boot_iso_file` points at a specific Ubuntu ISO filename already uploaded
  to the Proxmox node's ISO storage — it is not fetched by Packer.
