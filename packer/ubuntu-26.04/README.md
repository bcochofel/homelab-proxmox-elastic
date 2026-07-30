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

Provisioning runs three scripts in order, then seals the template:
`scripts/15-fix-initrd-network.sh` (no networking in the initrd — see
ADR-6), `scripts/20-install-docker.sh` (Docker CE + Compose), and
`scripts/30-install-trivy.sh` (OS-package vulnerability scanning — see
ADR-7). `scripts/99-cleanup-seal.sh` runs last and seals the template.

Proxmox user/token setup is shared across templates — see
[`../../docs/PACKER.md`](../../docs/PACKER.md). If a build fails, see
["Troubleshooting a failed build"](../../docs/PACKER.md#troubleshooting-a-failed-build)
in that same doc for how to keep the VM alive and pull `cloud-init` logs
instead of guessing.

## What it builds

A `proxmox-iso` source boots an Ubuntu 26.04 Server ISO, autoinstalls via
cloud-init (`http/user-data.yml.tpl` + `http/meta-data.yml` served over the
Packer HTTP server), then the initrd is stripped of networking, Docker is
installed, Trivy is installed with its daily scan scheduled, and Elastic
Agent is pre-installed (left disabled) — before the image is sealed and
converted to a Proxmox template. Terraform later clones this template per
node (see `docs/TERRAFORM.md`).

```text
ISO boot --autoinstall--> cloud-init (users, disk layout, packages,
  sysctl/limits, SSH hardening)
    --provisioners--> initrd network fix --> Docker install --> Trivy install
      --> Elastic Agent install (disabled)
        --provisioners--> cleanup & seal
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
| `scripts/15-fix-initrd-network.sh` | Omits dracut's network modules so nothing DHCPs the NIC before cloud-init's netplan config runs (see ADR-6) |
| `scripts/20-install-docker.sh` | Docker CE + Compose plugin, qemu-guest-agent |
| `scripts/30-install-trivy.sh` | Installs Trivy (pinned), pre-caches its vulnerability DB, schedules the daily scan (see ADR-7) |
| `scripts/35-install-elastic-agent.sh` | Installs Elastic Agent (pinned) and disables the service — Ansible configures and enables it later (see ADR-8) |
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

### ADR-6: No networking in the initrd (interface-rename race)

**Context.** First real `terraform apply` against this template: all six
cloned VMs came up reachable, but on the *wrong* IP — DHCP-assigned
(`192.168.68.65`-`.70`) instead of the static IPs Terraform's cloud-init
`ipconfig0` configured (`192.168.68.30`-`.35`). `cloud-init status --long`
on a clone showed `extended_status: degraded done` with:
`Unable to rename interfaces: [['<mac>', 'eth0', None, None]] due to
errors: ['[busy] Error renaming mac=<mac> from ens18 to eth0']`.

Root cause, confirmed via `journalctl -b`: Proxmox's auto-generated
cloud-init network-config always names the interface generically (`eth0`)
regardless of the guest's real predictable name (`ens18` here), so
cloud-init's netplan renderer has to rename `ens18` → `eth0` to satisfy
that name before it can apply the static address. That rename requires the
interface to be down. But dracut's default **hostonly** mode had bundled
the full network module stack (`40network`, `11systemd-networkd`, etc.)
into the initrd — not because this VM's boot path needs it (root is local
LVM, no NFS root, no network unlock), but because the *build machine*
(which needs internet to install packages) has an active NIC, and hostonly
detection includes modules based on the build host, not the target's
actual boot requirements. That initrd-stage `systemd-networkd` DHCPs
`ens18` and brings it up within ~3 seconds of boot — long before
`cloud-init-network.service` runs — so by the time cloud-init tries the
rename, the interface is already up and "busy," the rename fails, and the
static config never applies.

**Decision.** `scripts/15-fix-initrd-network.sh` drops
`/etc/dracut.conf.d/99-omit-network.conf` (`omit_dracutmodules` for every
network-related dracut module) and regenerates the initramfs
(`dracut --force --regenerate-all`) before Docker/Trivy install. With no
networking at all in the initrd, cloud-init's netplan config is the first
thing to ever touch the NIC, so the rename always succeeds.

**Alternative considered, rejected for now.** Bypass Proxmox's
auto-generated network-config entirely by uploading a custom per-VM
cloud-init network-config as a Proxmox snippet (`cicustom`), authored
without `set-name` so the static IP applies directly to `ens18` — no
rename, ever. More robust long-term (doesn't depend on what dracut decides
to bundle), but spans Terraform too: needs snippet storage, a
Terraform-generated file per VM (each has a different static IP), and the
SSH file-upload path `terraform/providers.tf`'s `ssh` block already flagged
as configured-but-unused. Revisit if the dracut-omit fix ever proves
fragile (e.g. a future ISO's hostonly detection pulls in network modules
through some path this omit list doesn't cover).

**Consequences.** `scripts/15-fix-initrd-network.sh` fails the build hard
(exits 1) if the regenerated initrd still contains the network module,
rather than silently shipping a template with the bug still latent — this
class of failure only shows up after a real `terraform apply`, so it's
worth catching at build time. If a future Ubuntu ISO drops or renames any
of the dracut modules currently listed in the omit set, this script's
verification step is what will surface that (as a build failure, not a
mystery IP later).

### ADR-7: Trivy for OS-package vulnerability scanning (not the ADR-3 tooling)

**Context.** ADR-3 above deliberately dropped AIDE/rkhunter/chkrootkit/lynis
because they need a baseline initialized on first real boot (per-clone),
and doing that generically in a shared template means either a stale
baseline (initialized against the template, not the clone) or a noisy
first scan on every clone (everything flagged "new"). `TODO.md`'s Phase 4
also calls for OS/package vulnerability scanning of this template — a
different, *stateless* problem: Trivy diffs installed packages against a
vulnerability database fresh on every run, with no baseline to initialize
and no per-clone coupling.

**Decision.** `scripts/30-install-trivy.sh` installs Trivy (pinned to the
same `TRIVY_VERSION` the Makefile uses for the IaC-scanning binary, `0.72.0`
by default — see `variables.pkr.hcl`), pre-downloads its vulnerability DB
into the template (`--download-db-only`, so a clone's first scan doesn't
need to fetch it), and installs `/etc/cron.d/trivy-scan`: daily at 03:00,
`trivy rootfs / --format json --output <trivy_report_path>`, overwriting
the same path each run (default `/var/log/trivy/report.json`, both set via
Packer variables — `install_trivy`, `trivy_version`, `trivy_report_path`).

**Consequences.** Every VM in the topology self-scans daily and keeps only
the latest JSON report locally — this is `TODO.md` Phase 4's "Step 1 plus
the cron/JSON half of Step 2," done at the Packer/OS level rather than via
an Ansible-managed schedule. What's still missing is the last piece of
Step 2: shipping that JSON into Elasticsearch (e.g. an Elastic Agent custom
log/file input reading `trivy_report_path`) for actual CVE dashboards in
Kibana — that remains open, tracked in `TODO.md`.

### ADR-8: Elastic Agent package pre-installed here, left disabled

**Context.** `CLAUDE.md` documents Elastic Agent as standalone (not
Fleet-managed), installed and configured entirely by Ansible: a deb package
plus a hand-rendered `elastic-agent.yml`, both via Ansible. Once Docker and
Trivy were already being baked in here (ADRs above), pre-installing the
Elastic Agent *package* the same way was an obvious speed win — six VMs no
longer each need to fetch and install it during the Ansible run. The
complication: unlike Docker or Trivy, Elastic Agent's version isn't
independent of the rest of this project — it needs to track
`ansible/group_vars/all.yml`'s `stack_version` for compatibility with the
ES cluster it ends up monitoring. Baking a specific version into an
immutable template creates exactly the kind of duplicated version state
`stack_version`'s single-source-of-truth design (see `CLAUDE.md`) exists to
avoid.

**Decision.** `scripts/35-install-elastic-agent.sh` downloads the pinned
`.deb` for `elastic_agent_version` directly from
`artifacts.elastic.co/downloads/beats/elastic-agent/` (same "exact pinned
version, no repo-latest drift" approach as Trivy's install script), installs
it, then immediately stops and disables the systemd service — nothing runs
until Ansible's (not yet built) `elastic_agent` role renders
`elastic-agent.yml` and enables it, once an ES cluster actually exists to
connect to. `elastic_agent_version` defaults to `9.4.2`, matching
`ansible/group_vars/all.yml`'s `stack_version` at the time this was
written — same manual-sync trade-off ADR-1 already accepts for
`elastic_base_dir`.

**Consequences.** Unlike `elastic_base_dir` drift (harmless — worst case,
compose renders to the wrong-but-consistent path), an Elastic Agent version
drift is a real compatibility risk: the first time `stack_version` gets
bumped and rolled out via playbook *without* also rebuilding this template,
every already-cloned VM's pre-installed agent silently stays on the old
version. **The `elastic_agent` Ansible role (not yet built — see
`TODO.md`'s Phase 1) must check the installed Elastic Agent version against
`stack_version` and reinstall via the same `.deb` URL pattern above if
they've drifted** — Packer can only get new clones right going forward, it
can't fix VMs cloned from an already-stale template.

## Variables reference

Required (no default — set via `variables.auto.pkrvars.hcl` or `PKR_VAR_*` env):

| Variable | Source in this repo |
| --- | --- |
| `proxmox_api_url`, `proxmox_api_token_id`, `proxmox_api_token_secret`, `proxmox_node`, `proxmox_skip_tls_verify` | `packer/.envrc` (`PKR_VAR_*`, decrypted from `secrets.yaml` via SOPS + direnv) |
| `password_hash` | `variables.auto.pkrvars.hcl` — generate with `mkpasswd -m sha-512 '<password>'` |
| `ssh_private_key_file` | `variables.auto.pkrvars.hcl` — must pair with a key in `ssh_authorized_keys` |

Everything else (VM sizing, packages, timezone, NTP, `vm_max_map_count`,
`elastic_base_dir`, `install_trivy`, `trivy_version`, `trivy_report_path`,
…) has a default in `variables.pkr.hcl` and only needs overriding in
`variables.auto.pkrvars.hcl` when it should differ from that default.

## Known coupling to watch

- `elastic_base_dir` (here) must match `elastic_base_dir` in
  `ansible/group_vars/all.yml` — Ansible still needs that path, unlike
  `vm_max_map_count` which is Packer-only (see ADR-1).
- `username` here must match the `ansible_user` Terraform writes into the
  generated inventory, since Ansible connects as that user.
- `boot_iso_file` points at a specific Ubuntu ISO filename already uploaded
  to the Proxmox node's ISO storage — it is not fetched by Packer.
- `trivy_report_path` (default `/var/log/trivy/report.json`) is where every
  VM's daily cron writes its latest scan — whatever eventually reads this
  path to ship reports into Elasticsearch (Ansible/Elastic Agent, per
  `TODO.md`) needs to agree on this same path, the same way
  `elastic_base_dir` is kept in sync today.
