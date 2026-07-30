# TODO / Roadmap

The single place phase status lives. When a phase is done, check it off
here — no need to also edit `README.md` or `CLAUDE.md`; both point here
instead of duplicating status inline.

Roughly in dependency order — later phases build on earlier ones.

## Phase 1 — Green cluster

- [x] Packer: `ubuntu-26.04` template builds cleanly (Docker + Compose,
      OS config for the Elastic Stack baked in via cloud-init, Trivy +
      daily scan, Elastic Agent package pre-installed but left disabled)
- [x] Terraform: 6-VM topology (ES x3, Kibana, APM Server, OTel demo), `vm`
      module, per-role inventory groups — merged (PR #3) and applied; all
      six VMs exist. Needed two `TerraformRole` privilege fixes
      (`VM.Allocate`, `VM.Config.CDROM`) not caught until the real apply —
      see `docs/TERRAFORM.md`'s incident notes
- [ ] Rebuild the `ubuntu-26.04` template to pick up the initrd-network fix
      (see `packer/ubuntu-26.04/README.md`'s ADR-6), then re-apply — the
      six VMs currently up got DHCP addresses instead of their static IPs
      because of that bug, so the generated `hosts.ini` doesn't match
      reality yet and Ansible can't run against them as-is
- [ ] Ansible: `apm_server`, `otel_demo`, `elastic_agent` roles + matching
      playbooks (separate PR from Terraform, not started). The
      `elastic_agent` role only needs to render `elastic-agent.yml` and
      enable/start the service (Packer pre-installs the package, disabled
      — see ADR-8 in `packer/ubuntu-26.04/README.md`) — but it must also
      check the installed Elastic Agent version against `stack_version`
      and reinstall via Elastic's `.deb` if they've drifted, since a
      `stack_version` bump rolled out without a template rebuild would
      otherwise leave every VM's pre-installed agent silently stale
- [ ] All six VMs green end to end: ES cluster healthy, Kibana up, APM
      Server up, OTel demo shipping traces to APM Server, every VM running
      a standalone Elastic Agent for OS + Docker metrics/logs

## Phase 2 — TLS + auth

- [ ] Local CA via `elasticsearch-certutil`, run-once Ansible play
- [ ] `xpack.security.enabled: true`; bootstrap password + certs into
      `secrets.yaml` (SOPS)

## Phase 3 — Fleet

- [ ] Fleet Server on the Kibana VM (needs Phase 2 — Fleet enrollment
      requires TLS)
- [ ] Migrate the standalone Elastic Agents (all six VMs) to Fleet-managed
- [ ] Migrate APM ingestion from the self-managed APM Server to the
      Fleet-managed APM integration

## Phase 4 — Broader telemetry & vulnerability data

- [ ] OSQuery Manager integration via Fleet-managed Elastic Agent (needs
      Phase 3)
- [ ] Elastic Defend + Auditd Manager integrations via Fleet-managed Elastic
      Agent (needs Phase 3) — the AIDE/rkhunter replacements: Defend gives
      FIM (file integrity monitoring) + basic host protection, Auditd
      Manager gives kernel-level audit events for rootkit/tamper detection
      and forensic-style querying after the fact
- [ ] Metricbeat/Elastic Agent module for the *Proxmox host* itself (the
      MS-01 hypervisor) — distinct from the per-guest-VM agents in Phase 1
- [x] Trivy vulnerability/CVE scanning of the Packer template — the actual
      OS image/packages baked into the VM, not the Terraform IaC scan that
      already runs in pre-commit today. Done at the Packer/OS level
      (`packer/ubuntu-26.04/scripts/30-install-trivy.sh`, see its ADR-7):
      every VM installs a pinned Trivy, pre-caches its vulnerability DB at
      build time, and runs a daily cron (`trivy rootfs`) that overwrites a
      JSON report at a path set by the `trivy_report_path` Packer variable
      (default `/var/log/trivy/report.json`)
  - [ ] Still open: ship that per-VM JSON into Elasticsearch (e.g. an
        Elastic Agent custom log/file input reading `trivy_report_path`)
        so it's queryable via CVE dashboards in Kibana instead of sitting
        as local files
- [ ] Osquery-based package/CVE correlation — a DIY learning exercise
      cross-referencing osquery's package-inventory tables against the
      Trivy CVE data once it's landed in Elasticsearch (see the "still
      open" item above), done by hand in ES|QL/Kibana rather than reaching
      for a pre-built integration (needs OSQuery Manager above and Trivy
      data actually shipped to Elasticsearch)

## Phase 5 — Elastic Security / SIEM

- [ ] Elastic Security app + MITRE ATT&CK-mapped detection rules, built on
      top of telemetry already being collected once security/TLS is on
      (Phase 2) — no new data sources needed to start, just rules against
      what's already flowing (agent OS/Docker metrics, APM traces, and
      whatever of Defend/Auditd/OSQuery from Phase 4 is live by then).
      Sequenced last on purpose — rules are only as good as the telemetry
      feeding them, so this depends on Fleet-managed agents (Phase 3) and
      OSQuery + host + vulnerability data (Phase 4) actually flowing first.

## Tooling / agent integrations (parallel track, doesn't block the above)

- [x] GitHub MCP (official remote server, fine-grained PAT)
- [x] Proxmox MCP (`gilby125/mcp-proxmox`, pinned commit, read-only token)
- [ ] Self-hosted GitHub Actions runner — moves `terraform apply` off the
      local write credential entirely
- [ ] Custom Elasticsearch MCP server (`cluster_health`, `list_indices`,
      shard allocation)

## Improvements (revisit once there's more operational experience)

- [ ] Split the template disk into OS-only + a second Terraform-provisioned
      data disk, instead of the current single disk sized by the biggest
      consumer (`terraform/variables.tf`'s per-node `disk`). Packer's
      template would carry a small, fixed, uniform disk across all six
      VMs; Terraform would attach a second disk per node, sized per role
      (ES needs more than Kibana/APM), and Ansible would format/mount it
      — likely at `/opt`, with Docker's `data-root` (`/etc/docker/
      daemon.json`) pointed at a subdirectory there, since `esdata` in
      `ansible/roles/elasticsearch/templates/docker-compose.yml.j2` is a
      *named* Docker volume (lives under `/var/lib/docker/volumes/` by
      default) — mounting a disk at `/opt` alone wouldn't actually capture
      it without that redirect. Considered and deliberately deferred: a
      same-day attempt hit the fact that bpg/proxmox can only grow a
      cloned disk, never shrink it, which is itself a good reason to
      revisit this once there's real experience running the current
      single-disk template rather than guessing at split sizing upfront.

See `CLAUDE.md` for the detailed technical notes, gotchas, and ADRs behind
each of these (agent-facing context) — this file is just the status list.
