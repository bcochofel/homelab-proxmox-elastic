# Packer — Ubuntu 26.04 + Docker template

Minimal cloud-init-ready Ubuntu 26.04 template with Docker + Compose plugin
baked in. Deliberately stripped down compared to `ubuntu-24.04/`: no proxy
support, no custom CA import, no security-scanning tooling (AIDE, rkhunter,
chkrootkit, lynis, auditd). SSH hardening and unattended-upgrades are still
configured via autoinstall — see ADR-3 below for why the rest was cut.

`vm.max_map_count`, memlock/nofile ulimits, and the `/opt/elastic` compose
base directory are baked in here via cloud-init (`http/user-data.yml.tpl`),
tunable through the `vm_max_map_count`/`elastic_base_dir` variables. Changing
either value means rebuilding the template.

## Build

```bash
cp variables.pkrvars.hcl.example variables.auto.pkrvars.hcl   # fill in, gitignored, auto-loaded
make packer-init                 # non-mutating: packer init . (plugin download)
cd packer/ubuntu-26.04 && packer build .   # run directly from this directory
```

Provisioning is a single step: `scripts/20-install-docker.sh` installs Docker
CE + Compose, then `scripts/99-cleanup-seal.sh` seals the template.

Proxmox user/token setup is shared across templates — see
[`../../docs/PACKER.md`](../../docs/PACKER.md). If a build fails, see
["Troubleshooting a failed build"](../../docs/PACKER.md#troubleshooting-a-failed-build)
in that same doc for how to keep the VM alive and pull `cloud-init` logs
instead of guessing.

## What it builds

A `proxmox-iso` source boots an Ubuntu 26.04 Server ISO, autoinstalls via
cloud-init (`http/user-data.yml.tpl` + `http/meta-data.yml` served over the
Packer HTTP server), then Docker is installed before the image is sealed and
converted to a Proxmox template. Terraform later clones this template per
node (see `docs/TERRAFORM.md`, once written).

```text
ISO boot --autoinstall--> cloud-init (users, disk layout, packages,
  sysctl/limits, SSH hardening)
    --provisioners--> Docker install --provisioners--> cleanup & seal
```

## File map

| File | Role |
| --- | --- |
| `ubuntu-26.04.pkr.hcl` | `source` (Proxmox connection, VM shape, boot) + `build` (provisioner order) |
| `variables.pkr.hcl` | Every input variable, grouped by concern |
| `locals.pkr.hcl` | Renders `http/user-data.yml.tpl` into `local.user_data` |
| `versions.pkr.hcl` | Packer core + `hashicorp/proxmox` plugin version pins |
| `http/user-data.yml.tpl` | cloud-init autoinstall: disk layout (LVM), users, SSH hardening, **OS config for Elastic Stack** |
| `http/meta-data.yml` | cloud-init meta-data (mostly empty; required by the datasource) |
| `scripts/20-install-docker.sh` | Docker CE + Compose plugin, qemu-guest-agent |
| `scripts/99-cleanup-seal.sh` | Strips machine-id/SSH host keys/logs/cloud-init state before conversion to template |
| `variables.pkrvars.hcl.example` | Copy to `variables.auto.pkrvars.hcl` (gitignored, auto-loaded by Packer) and fill in |

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
*is* the dependency graph — Docker installs first, `99-cleanup-seal.sh` runs
last since it truncates logs and clears `/var/lib/cloud`. The `NN-` prefixes
exist purely to make that order legible in a directory listing, and to leave
room to slot a script back in between (e.g. `1N-*` for something that must
run before Docker) without renumbering everything else.

### ADR-3: Why this template drops proxy, custom CA, and security-scanning

Unlike `ubuntu-24.04/`, this template has no `scripts/00-configure-proxy.sh`,
no `scripts/10-install-custom-ca.sh`/`custom-ca/`, and no
`scripts/80-security-scans.sh`. The corresponding cloud-init pieces (the
`proxy:` autoinstall directive, and the rkhunter/chkrootkit/lynis/AIDE
packages + systemd timers in `http/user-data.yml.tpl`) were removed too,
not just the scripts — leaving the packages/timers installed with no
provisioner to initialize their baseline (AIDE's database, rkhunter's
file-property baseline) would mean every first real scan on a clone flags
the entire filesystem as "new," which is noise, not signal (see
`ubuntu-24.04/README.md`'s ADR-4 for the fuller explanation of that
coupling). This build doesn't need an HTTP proxy, a custom root CA, or
host-level rootkit/integrity scanning, so removing all three top to bottom
(packages, cloud-init config, provisioner scripts, and their `PKR_VAR_*`/
Packer variables) avoids dead config nobody will use. SSH hardening and
unattended-upgrades stay, since those are cheap, static file content with
no baseline-initialization dependency.

### ADR-4: `ntp_client: auto` instead of `systemd-timesyncd`

`ubuntu-24.04/` pins `ntp_client: systemd-timesyncd` in the autoinstall
`ntp:` block. On this Ubuntu 26.04 ISO that failed the build outright:
`cloud-init status --long` showed `cc_ntp` erroring with `Unit
systemd-timesyncd.service not found`, which flips the whole run to `status:
error` even though every other module reports success (visible only via
`cloud-init status --long`, not by tailing `cloud-init.log`/
`cloud-init-output.log`, since the final stage's own log line still reads
"0 failures" — the actual failure was in an earlier stage). Root cause
not fully diagnosed (may be a minimized-server package set on this ISO, or a
26.04 packaging change) — rather than guessing further, this template uses
cloud-init's own `ntp_client: auto`, which probes for whatever NTP client is
actually installed (chrony, systemd-timesyncd, ntp, ntpdate, openntpd) and
uses that. If you hit this on `ubuntu-24.04/` too, or `auto` picks something
undesired here, revisit rather than assuming this is 26.04-specific.

A second, related quirk surfaced once the NTP fix above got the build past
that first error: the "wait for cloud-init" provisioner in
`ubuntu-26.04.pkr.hcl` (first shell provisioner, before Docker install) ran
`sudo cloud-init status --wait` and failed the whole build step —
`Script exited with non-zero exit status: 2` — even though a manual
`cloud-init status --long` on the same VM showed `status: disabled` and
`errors: []`, i.e. a genuinely clean finish. `disabled` is cloud-init's own
expected terminal state here (Subiquity's `write_files_deferred` module
writes `/etc/cloud/cloud-init.disabled` after autoinstall completes, so
cloud-init doesn't re-run its own install config on the next boot — normal
behavior, not something this template's config controls). The bundled
cloud-init on this ISO (`26.1-0ubuntu2`, well newer than what `ubuntu-24.04`
ships) apparently signals that `disabled` terminal state via exit code `2`
from `status --wait`, distinct from a real unrecoverable error (`1`) —
and Packer's inline shell provisioner aborts the whole step on any nonzero
exit from any line, so that `2` was fatal. The exit-2-on-`disabled` behavior
isn't unique to `--wait` — a first attempt at fixing this added `|| true`
only to the `--wait` line and left a plain `cloud-init status --long` call
(added purely to print the status for visibility) unprotected on the next
line; that one exits 2 too, so `set -e` still killed the script, just one
line later, before ever reaching the actual check. Every direct
`cloud-init status` invocation needs its own `|| true` here — the *only*
place it's safe to let cloud-init's exit code stand is inside the final
`if`/`grep` condition itself, since a failing condition doesn't trigger
`set -e` regardless of its exit code. Fix: stop trusting the raw exit code
of `--wait` and instead check the `errors: []` field in
`cloud-init status --long` directly, which is the signal that actually
matters. `ubuntu-24.04/`'s build never hit this, so — same caveat as
above — treat it as this ISO's cloud-init version, not a config bug, unless
proven otherwise.

### ADR-5: No Alloy or system_report provisioning

Host telemetry shipping (Grafana Alloy) and a compliance-scan tool
(`system_report`) are not part of this template. Neither is needed for this
workload (Elastic Stack's own stack handles observability of itself; a
Metricbeat/Elastic Agent module is the planned path for Proxmox host
telemetry). A `system_report` provisioner shape is left commented out in
`ubuntu-26.04.pkr.hcl` as a starting point if ever wanted — commented out,
not deleted, because it's inert until uncommented and there's no live
reference to break. Anything for Alloy should be added fresh (script +
variables) rather than resurrected from a commented block, since a
referenced-but-missing script/variable is a build break waiting to happen,
not a harmless no-op.

## Variables reference

Required (no default — set via `variables.auto.pkrvars.hcl` or `PKR_VAR_*` env):

| Variable | Source in this repo |
| --- | --- |
| `proxmox_api_url`, `proxmox_api_token_id`, `proxmox_api_token_secret`, `proxmox_node`, `proxmox_skip_tls_verify` | `packer/.envrc` (`PKR_VAR_*`, decrypted from `secrets.yaml` via SOPS + direnv) |
| `password_hash` | `variables.auto.pkrvars.hcl` — generate with `mkpasswd -m sha-512 '<password>'` |
| `ssh_private_key_file` | `variables.auto.pkrvars.hcl` — must pair with a key in `ssh_authorized_keys` |

Everything else (VM sizing, packages, timezone, NTP, `vm_max_map_count`,
`elastic_base_dir`, …) has a default in `variables.pkr.hcl` and only needs
overriding in `variables.auto.pkrvars.hcl` when it should differ from that
default.

## Known coupling to watch

- `elastic_base_dir` (here) must match `elastic_base_dir` in
  `ansible/group_vars/all.yml` — Ansible still needs that path, unlike
  `vm_max_map_count` which is Packer-only (see ADR-1).
- `username` here must match the `ansible_user` Terraform writes into the
  generated inventory, since Ansible connects as that user.
- `boot_iso_file` points at a specific Ubuntu ISO filename already uploaded
  to the Proxmox node's ISO storage — it is not fetched by Packer.
