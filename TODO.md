# TODO / Roadmap

The single place phase status lives. When a phase is done, check it off
here — no need to also edit `README.md` or `CLAUDE.md`; both point here
instead of duplicating status inline.

Roughly in dependency order — later phases build on earlier ones.

## Phase 1 — Green cluster

- [x] Packer -> Terraform -> Ansible pipeline, `xpack.security.enabled: false`
- [x] Terraform layer: 6-VM topology (ES x3, Kibana, APM Server, OTel demo),
      `vm` module, per-role inventory groups
- [ ] Ansible layer: `apm_server`, `otel_demo`, `elastic_agent` roles +
      matching playbooks (separate PR from Terraform)
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
- [ ] Metricbeat/Elastic Agent module for the *Proxmox host* itself (the
      MS-01 hypervisor) — distinct from the per-guest-VM agents in Phase 1
- [ ] Trivy vulnerability/CVE scanning of the built Packer template — the
      actual OS image/packages baked into the VM, not the Terraform IaC
      scan that already runs in pre-commit today. Needs:
  - a scan step (Packer post-processor against the built template, or a
        scheduled scan against a running/exported instance)
  - results shipped into Elasticsearch so they're queryable in Kibana,
        not left as a build-log artifact
  - run on a recurring schedule (cron), not just once at build time, so
        CVEs disclosed after a template is built still surface

## Phase 5 — Elastic Security / SIEM

- [ ] A proper Elastic Security (SIEM) platform: detection rules, alerting,
      case management. Sequenced last on purpose — rules are only as good
      as the telemetry feeding them, so this depends on Fleet-managed
      agents (Phase 3) and OSQuery + host + vulnerability data (Phase 4)
      actually flowing first.

## Tooling / agent integrations (parallel track, doesn't block the above)

- [x] GitHub MCP (official remote server, fine-grained PAT)
- [x] Proxmox MCP (`gilby125/mcp-proxmox`, pinned commit, read-only token)
- [ ] Self-hosted GitHub Actions runner — moves `terraform apply` off the
      local write credential entirely
- [ ] Custom Elasticsearch MCP server (`cluster_health`, `list_indices`,
      shard allocation)

See `CLAUDE.md` for the detailed technical notes, gotchas, and ADRs behind
each of these (agent-facing context) — this file is just the status list.
