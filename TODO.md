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
- [x] Rebuild the `ubuntu-26.04` template to pick up the initrd-network fix
      (see `packer/ubuntu-26.04/README.md`'s ADR-6) and re-apply — confirmed
      fixed: all six VMs now come up on their configured static IPs instead
      of DHCP
- [x] Ansible: `apm_server`, `otel_demo`, `elastic_agent` roles + matching
      playbooks — merged (PR #7). Also moved `group_vars/` under
      `inventory/` and every playbook under `playbooks/` (see
      `docs/ANSIBLE.md`). `elastic_agent` renders `elastic-agent.yml` and
      enables/starts the service (Packer pre-installs the package, disabled
      — see ADR-8 in `packer/ubuntu-26.04/README.md`), and checks the
      installed version against `stack_version`, reinstalling via Elastic's
      `.deb` if they've drifted
- [x] All six VMs green end to end: ES cluster healthy (3/3, green), Kibana
      up, APM Server up, OTel demo's 19 containers all healthy and shipping
      real trace data to APM Server, every VM running a standalone Elastic
      Agent reporting `HEALTHY`. Getting here surfaced (and fixed) several
      real bugs only visible on a live run, not from inspection — see
      PR #7's later commits and `CLAUDE.md` for the full list: Kibana's
      `elasticsearch.hosts` needing a whitespace-free JSON array (not a
      comma-joined string), the apm-server image having no curl/wget/nc at
      all (its healthcheck always failed despite the server working fine),
      several otel-demo services crash-looping on this template's
      IPv6-disabled kernel, the otel-collector's own OTLP receiver sharing
      (and breaking on) the same env var used to redirect other services'
      export target, and `elastic_agent`'s `docker/metrics` input silently
      degraded because `hosts` was set once at the input level instead of
      per-stream. The `otel_demo` role was also redesigned so re-running
      `site.yml` is genuinely idempotent (`changed=0` on a repeat run,
      verified, not assumed) — the original approach patched files tracked
      by the vendored git checkout, which broke idempotency by design

## Phase 2 — TLS + auth

- [x] Local CA via `elasticsearch-certutil` — `es_certs` role
      (`playbooks/05-elasticsearch-certs.yml`), PEM-based, distributes to
      all six VMs. Certs are cached controller-locally
      (`ansible/.certs/`, gitignored) rather than round-tripped through
      `secrets.yaml` — see docs/ANSIBLE.md's "TLS + auth" section for why
- [x] `xpack.security.enabled` wired end to end (ES transport+HTTP TLS,
      `kibana_system` password, APM Server/Elastic Agent API keys via
      `es_security_bootstrap` role) behind the single `es_security_enabled`
      flag — `ELASTIC_PASSWORD`/`KIBANA_SYSTEM_PASSWORD` go into
      `secrets.yaml` (SOPS) as designed; API keys are minted, not
      human-chosen, so they're cached in `ansible/.secrets-cache/`
      (gitignored) instead
- [x] Live cutover completed 2026-08-01 via the one-shot
      `-e es_security_enabled=true -e security_rollout=true` procedure —
      cluster reached green (3/3 nodes) with security on, Kibana/APM
      Server/OTel demo all passed `99-healthcheck.yml`, `es_security_enabled`
      is now `true` in the checked-in `all.yml`. Several real bugs surfaced
      only by running it live, not from inspection (see docs/ANSIBLE.md's
      "TLS + auth" section and the `es_certs`/`elasticsearch` role comments
      for the full incident notes):
  - `ELASTIC_PASSWORD_FILE` crash-loops ES if the file's mode is looser
    than 640 (had 644)
  - a one-off CA/node-cert mismatch, root cause never fully pinned down —
    a hard `openssl verify` check was added right after generation to
    catch this at generation time instead of three plays later as an
    opaque TLS handshake error
  - `es_certs`'s original design generated certs via `docker exec` into
    the live `elasticsearch` service container — worked for this cutover
    (an existing, already-running container from Phase 1) but would have
    broken a from-scratch bootstrap outright, since no `elasticsearch`
    container exists yet at that point in `site.yml`. Caught by review
    before it could bite a real fresh stand-up, not by hitting it live.
    Redesigned around a one-off `docker run --rm` against the pinned
    `es_image` instead, which also happens to structurally rule out the
    CA/node-cert mismatch above (both certutil invocations now share one
    bind-mounted directory — no more copying the CA in and out of a
    container)
- [ ] Re-evaluate `elastic/opentelemetry-demo` (EDOT fork) for the `otel_demo`
      VM once `xpack.security` is on — its EDOT/native-ES-OTLP-ingest modes
      need an API key our currently-unsecured cluster can't issue; a
      parallel VM (next free IP, `.36`) is the low-risk way to trial it
      against the self-managed APM Server without touching the working
      upstream-demo role
- [x] Kibana's public URL (`kibana.homelab.bcochofel.com`) served with a
      real Let's Encrypt certificate — separate from the internal
      `es_certs` CA above, since it's the one endpoint humans hit in a
      browser. `kibana_tls` role: `certbot` + `certbot-dns-cloudflare`,
      DNS-01 (Kibana has no public port 80/443 for HTTP-01), certbot's own
      systemd timer handles renewal. See docs/ANSIBLE.md's "Kibana TLS
      (Let's Encrypt)" section

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
      build time, prints a one-line OS-package CVE summary to the Packer
      build log immediately, and schedules a daily cron (`trivy rootfs`,
      full scope — OS + libraries + secrets) that writes the comprehensive
      JSON report to a path set by the `trivy_report_path` Packer variable
      (default `/var/log/trivy/report.json`)
  - [ ] Still open: ship that per-VM JSON into Elasticsearch (e.g. an
        Elastic Agent custom log/file input reading `trivy_report_path`)
        so it's queryable via CVE dashboards in Kibana instead of sitting
        as local files
  - [ ] Still open: the daily scan reports ~5900 OS-package "vulnerabilities"
        on a live es-01 (`ubuntu-26.04`) — verified via a live SSH scan, not
        assumed. `trivy --distro ubuntu/26.04` does **not** help: OS
        auto-detection already correctly identifies `ubuntu/26.04` from
        `/etc/os-release`, so passing `--distro` explicitly produced byte-
        identical results (also, it's still flagged `[EXPERIMENTAL]` in
        Trivy 0.72.0). The real cause, confirmed on the same scan: **100% of
        the ~5900 findings have no `FixedVersion`** — Trivy has no patch
        available to report, so `--ignore-unfixed` drops the count to zero.
        ~86% of the total (634 × 8 packages) is the Linux kernel's CVE list
        being repeated in full across every kernel-derived binary package
        (`linux-headers-*`, `linux-modules-*`, `linux-tools-*`, `bpftool`,
        `linux-libc-dev`, `linux-perf`) — a known Trivy/Ubuntu-kernel
        behavior, not specific to this template. Before adding
        `--ignore-unfixed` to `30-install-trivy.sh`'s daily cron, weigh the
        tradeoff: it also hides real vulnerabilities that already have a
        published fix pending a package upgrade, not just kernel noise —
        may want it paired with a separate signal for "fixable and
        outstanding" rather than applied blanket.
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
- [x] Every VM was stuck on UTC regardless of the `timezone` Packer variable
      (defaults to `Europe/Lisbon`) — not an NTP sync problem, confirmed:
      `packer/ubuntu-26.04/http/user-data.yml.tpl`'s autoinstall
      `timezone: ${timezone}` was applied, then a `runcmd` line
      unconditionally ran `timedatectl set-timezone UTC` right after,
      silently overriding it back to UTC every boot. Fixed by dropping that
      `runcmd` line — `timezone: ${timezone}` now takes effect on its own.
      Everything internally still normalizes to UTC regardless (logs, ES
      timestamps, cron), so this is a wall-clock-only change. Needs the
      template rebuilt to take effect on new VMs — not yet verified on a
      live build (`TODO.md`'s next from-scratch bootstrap covers that).

See `CLAUDE.md` for the detailed technical notes, gotchas, and ADRs behind
each of these (agent-facing context) — this file is just the status list.
