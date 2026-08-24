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
- [x] Kibana's public URL (`kibana.homelab.bcochofel.com`) served with a
      real Let's Encrypt certificate — separate from the internal
      `es_certs` CA above, since it's the one endpoint humans hit in a
      browser. `kibana_tls` role: `certbot` + `certbot-dns-cloudflare`,
      DNS-01 (Kibana has no public port 80/443 for HTTP-01), certbot's own
      systemd timer handles renewal. See docs/ANSIBLE.md's "Kibana TLS
      (Let's Encrypt)" section

## Phase 3 — Fleet

- [x] Fleet Server on the Kibana VM (`fleet_bootstrap` + `fleet_server`
      roles, `playbooks/35-fleet-server.yml`, gated on
      `fleet_server_enabled`). Own TLS listener (port 8220) reuses the
      internal `es_certs` CA, not the Kibana Let's Encrypt cert — every
      agent that'll eventually enroll already trusts that CA. Kibana-side
      setup (agent policy, Fleet Server host) scripted via
      `ansible.builtin.uri` against Kibana's Fleet HTTP API, same
      API-driven style as `es_security_bootstrap`, not the
      `elastic-agent` container's own `KIBANA_FLEET_SETUP` auto-bootstrap.
- [x] Migrate the standalone Elastic Agents (all six VMs) to Fleet-managed.
      `elastic_agent` role rewritten one-way (no standalone fallback) —
      es-01/02/03, kibana, otel-demo share `homelab-agents-policy` (System
      + Docker, Fleet's own default inputs); apm-server gets its own
      `apm-server-agent-policy` (System + Docker + APM), since Fleet
      agents belong to exactly one policy. Real bug found live: Fleet's
      auto-created default output pointed at plain `http://localhost:9200`,
      wrong for this HTTPS/secured cluster — every agent's metrics/docker
      output silently failed until `fleet_bootstrap` was extended to
      explicitly point the output at the real ES hosts + internal CA
- [x] Migrate APM ingestion from the self-managed APM Server to the
      Fleet-managed APM integration. `apm_server` role/playbook/compose
      stack deleted once verified live; `otel_demo`'s OTLP target needed no
      changes (same host:port). Real bug found live: Elastic Agent 9.x's
      default `basic` install flavor doesn't include the APM input at all
      (`"input not supported... install the correct flavor"`) — apm-server
      needs the `servers` flavor specifically (`ELASTIC_AGENT_FLAVOR=servers`),
      which needs a purge + reinstall since dpkg tracks package version,
      not flavor. See docs/ANSIBLE.md's "Fleet (Phase 3, complete)" section
      for the full writeup and other bugs found live (Fleet Server
      self-enrollment needing `FLEET_URL`/`FLEET_CA`, the APM package
      policy's input-key naming, `ansible.builtin.uri` not sending Basic
      auth preemptively against Kibana's API, and agent self-monitoring
      needing `monitoring_enabled` explicitly set on every agent policy or
      Kibana's Logs/Metrics tabs show as disabled even though the
      System/Docker integrations are collecting data fine)

## Phase 4 — Broader telemetry & vulnerability data

- [ ] OSQuery Manager integration via Fleet-managed Elastic Agent (needs
      Phase 3)
- [ ] Elastic Defend + Auditd Manager integrations via Fleet-managed Elastic
      Agent (needs Phase 3) — the AIDE/rkhunter replacements: Defend gives
      FIM (file integrity monitoring) + basic host protection, Auditd
      Manager gives kernel-level audit events for rootkit/tamper detection
      and forensic-style querying after the fact
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
- [x] Elasticsearch MCP (`elastic-mcp` npm package, pinned version,
      read-only API key) — community server, not the custom build
      originally planned here; see `CLAUDE.md`'s Agent-tooling rollout
- [ ] Self-hosted GitHub Actions runner — moves `terraform apply` off the
      local write credential entirely

## Phase 6 — SRE AI-autonomy: health alerting & investigation (parallel track, health/monitoring only — not infrastructure deployment)

Context: <https://sre.google/resources/practices-and-processes/ai-engineering-reliable-operations/>'s
five-stage AI-autonomy ladder (L0 Manual → L1 Assisted Automation → L2
Partial Autonomy (human approval) → L3 High Autonomy (bounded scenarios) →
L4 Full Autonomy). Goal: move from "a human notices something and opens
Claude Code" to properly automated detection + investigation for outages
across all three homelab repos, with mitigation staying human (L1) and then
approval-gated (L2) before any bounded autonomous remediation (L3) is
considered. Deliberately excludes `packer`/`terraform`/`ansible` provisioning
— that stays human-gated exactly as it is today; this track is about runtime
health only.

- [ ] Kibana alerting rules against telemetry already flowing: ES cluster
      color (yellow/red), node down, disk watermark breach, APM error
      rate/latency, host CPU/mem/disk thresholds (Elastic Agent metrics) —
      this is the actual bottleneck today, since no automated detection
      exists anywhere in the homelab yet
- [ ] Trigger wiring from a fired alert to an investigation agent — start
      poll-based (a scheduled agent checking for active alerts via the
      Elastic MCP server) before considering a push-based webhook receiver
- [ ] Standard investigation runbook: given a fired alert, fan out across
      Elastic MCP (logs/traces/metrics) + the other repos' MCP servers,
      produce Symptom → Evidence → Probable cause → Recommended remediation
      → confidence/blast-radius, landed as a GitHub issue in the repo that
      owns the failing component
- [ ] L2 stepping stone: make the recommended remediation approvable
      (issue comment/reaction) instead of retyped from scratch
- [ ] L3 candidates (only after L1/L2 are proven): a short, explicit
      catalog of pre-approved, self-verifying playbooks for
      already-diagnosed recurring issues, each behind its own
      least-privilege write credential — not a general write grant

### Phase 6a — command audit trail (prerequisite, do before the SLO/burn-rate work above)

Neither interactive zsh commands nor Claude Code's own Bash tool calls are
logged anywhere today — no non-repudiation, no way to separate
human-trajectory from agent-trajectory data for the SLO/burn-rate
experiments above. Schema: ECS-native from the start (not a compact custom
schema), so no remapping is needed once this ships to Elasticsearch.

- [ ] zsh command-audit hook (`~/.zshrc` or a sourced file): `preexec`/
      `precmd` registered via `add-zsh-hook` (additive — doesn't clobber
      p10k's own hooks), appending one ECS-native NDJSON line per command
      to `~/.command_audit.jsonl`. Fields: `@timestamp`, `user.name`,
      `host.name`, `process.working_directory`, `process.command_line`,
      `process.exit_code` (from `$?`, captured as the first statement in
      `precmd`), `event.duration` (nanoseconds — needs `zmodload
      zsh/datetime` for `$EPOCHREALTIME`), `event.kind: "event"`,
      `event.category: ["process"]`, `labels.source: "zsh"`. Build the
      JSON via `jq -n --arg`/`--argjson` (not string interpolation), so
      arbitrary quoting/newlines in the command itself can't break the
      NDJSON line.
- [ ] Claude Code `PostToolUse` hook, matcher `"Bash"`, in the
      **user-level** `~/.claude/settings.json` (confirmed: applies
      machine-wide, to every session regardless of project directory — no
      need to duplicate into each repo's own `.claude/settings.json`).
      Pipes the hook's stdin JSON through `jq` into the same
      `~/.command_audit.jsonl`, mapped to the same ECS fields plus
      `labels.source: "claude-code"` and `labels.session_id` (from the
      event's `session_id`). **Known gap, confirmed against current
      Claude Code docs**: the Bash tool's `tool_response` is only `{type,
      text}` — no structured exit-code field — so `process.exit_code`
      will be absent/unreliable for Claude-Code-sourced entries. Accepted
      Bronze-tier limitation, not worth parsing out of free-text output.
- [ ] Later: Elastic Agent custom-logs (or Filebeat) input reading
      `~/.command_audit.jsonl` with `json.keys_under_root: true` — zero
      transformation needed since the schema is already ECS-native, ships
      through the same Fleet Server this repo already runs.
- [ ] Bronze/Silver/Gold framing for the resulting trajectory data (not a
      checklist item, just the model to keep in mind when this lands in
      Kibana): Claude Code's self-reported log + the zsh self-reported log
      = Bronze (editable, self-reported); `auditd`→Elastic on the real
      Proxmox VMs (see Phase 4 above) = Gold (kernel-level ground truth);
      the WSL2 dev box has no working `auditd` (custom MS kernel, no audit
      subsystem), so Bronze is the correct/only tier achievable there —
      not a gap to fix, a property of the platform.

### Identity separation: read-only / RW-CI / RW-human (shared across all 3 repos, not split per repo)

Packer, Terraform, and Ansible each currently have exactly **one**
credential per tool, shared across all three homelab repos and between
interactive zsh use and anything Claude Code runs. There is no separate
"agent" identity in this model — Claude Code write actions only happen
when the human approves the existing `ask` prompt, so they run under the
same RW-human credential the human already uses; attribution between "I
typed this" and "Claude Code ran this" comes from the audit trail above
(`labels.source`), not a different Proxmox credential. MCP tokens
(`mcp@pve!mcp`) are already the correct read-only/agent tier by
construction, since MCP tools are only ever invoked by an agent — no
change needed there. What's actually missing is a read-only tier for
Terraform/Packer's own dry-run subcommands (`plan`/`validate`), which
today share the same RW token as `apply`/`build`.

Target: **three tokens per process** (Packer, Terraform), shared across
all three repos exactly like today's single token already is — not
tripled per repo. Naming convention:
`<pve-user>@pve!<tool>-<verb>-<tier>`, e.g.
`terraform@pve!terraform-plan-readonly`,
`terraform@pve!terraform-apply-ci` (reserved),
`packer@pve!packer-validate-readonly`,
`packer@pve!packer-build-ci` (reserved). The existing
`packer@pve!packer-automation`/`terraform@pve!terraform-automation` names
are misleading relative to how they're actually used today (interactively,
not by automation) — an optional future rename to `*-apply-human`/
`*-build-human`, not bundled into this pass since Proxmox tokens can't be
renamed in place (would mean minting a replacement, revoking the old one,
and updating `secrets.yaml`/`.envrc` in all three repos).

- [ ] Mint one shared `<tool>-<verb>-readonly` token each for Packer and
      Terraform (confirm whether it can reuse `mcp@pve!mcp`'s existing
      role/privilege set, or needs its own). Wire it into whatever invokes
      `plan`/`validate`, separate from the apply/build token — same value
      added to `secrets.yaml` in core, elastic, *and* k3s.
- [ ] Reserve (don't yet mint) one shared `<tool>-<verb>-ci` token each for
      Packer and Terraform — created only when the self-hosted GitHub
      Actions runner item above is actually picked up; also gets added to
      all three repos' `secrets.yaml` once it exists.
- [ ] No change needed to the existing shared apply/build token — already
      correct for the RW-human tier despite its legacy `-automation` name.
- [ ] Ansible's identity axis is SSH keys, not a Proxmox token — same
      shared-identity pattern applies: one automation keypair, its public
      half added as an additional `ssh_authorized_keys` entry in all three
      repos' Packer templates (alongside the human's existing key, not
      replacing it), reserved for a future CI runner.
      `ansible-playbook --check` (Ansible's own dry-run mode) is the
      practical read-only equivalent — no separate SSH identity needed for
      that tier.
- [ ] k3s-only addition (no equivalent here or in core, since there's only
      one cluster): tracked in the k3s repo's own `TODO.md`.

### Ansible secrets: move to inventory-scoped SOPS

Ansible currently gets every secret indirectly: direnv decrypts the root
`secrets.yaml` into shell env vars, `ansible/.envrc` re-exports the ones
Ansible needs, and roles/`group_vars` read them via `lookup('env',
'VAR_NAME')`. Target: give Ansible its own inventory-scoped,
SOPS-encrypted file that Ansible decrypts directly at playbook-run time
via the `community.sops` collection — cleaner separation from
Packer/Terraform/HCP-Cloud secrets, and Ansible's secret values no longer
have to pass through the shell's environment at all (a smaller exposure
surface than env vars, which are visible via `/proc/<pid>/environ` and
inherited by every child process).

- [ ] Add `community.sops` to `ansible/requirements.yml`, installed the
      same way other collections already are (`make ansible-deps`).
      Provides a `community.sops.sops` lookup plugin (and optionally a
      vars plugin for transparent auto-loading — decide which when
      implementing).
- [ ] Create `ansible/inventory/group_vars/all/secrets.sops.yaml` (or
      split per host-group if a secret is genuinely group-scoped, e.g.
      `ELASTIC_PASSWORD` only mattering to the `elasticsearch` group),
      encrypted with the same age recipient already in this repo's
      `.sops.yaml`. Add a matching `path_regex` creation rule to
      `.sops.yaml`.
- [ ] Move `ELASTIC_PASSWORD`/`KIBANA_SYSTEM_PASSWORD` there; update the
      roles/`group_vars` currently doing `lookup('env', ...)` for them to
      read the SOPS-sourced variable instead. Once verified working end to
      end, remove both keys from the root `secrets.yaml` and
      `ansible/.envrc`'s export list — the root file keeps only what
      genuinely isn't Ansible's (Proxmox Packer/Terraform tokens,
      `cipassword`, the HCP Terraform Cloud token).
- [ ] Ownership boundary, same as today's `secrets.yaml` convention:
      creating the new file's structure, the collection/`.sops.yaml`/role
      wiring, and updating `group_vars` references are agent-doable.
      Moving real secret *values* into the new file and deleting them from
      the old one stays a user-owned edit.

## Improvements (revisit once there's more operational experience)

- [x] Split the template disk into OS-only + a second Terraform-provisioned
      data disk, instead of the previous single disk sized by the biggest
      consumer. Landed alongside a full VM recreation (new template
      hostname + DNS servers, see below): Packer's template now carries a
      small, fixed 40G OS disk across all five VMs (`http/user-data.yml.tpl`'s
      `/opt` LVM partition dropped, `root` takes the rest); Terraform's
      `modules/vm` attaches a second disk per node (`data_disk` field —
      100G for ES, 20G for Kibana/APM), and Ansible's new `data_disk` role
      formats/mounts it at `/opt`, redirecting Docker's `data-root`
      (`/etc/docker/daemon.json`) into a subdirectory there so `esdata`
      (a *named* Docker volume, `ansible/roles/elasticsearch/templates/
      docker-compose.yml.j2`) actually lands on it. Turned out the real
      disk-space ceiling wasn't "biggest consumer sizing" as originally
      guessed — it was the OS disk's `root` LVM volume being hardcoded to a
      fixed 25G regardless of overall disk size, which no amount of
      bumping `disk_size` alone would have fixed. See
      `packer/ubuntu-26.04/README.md`'s ADR-9. A 7-day Data Stream
      Lifecycle retention policy (`es_data_lifecycle` role,
      `docs/ANSIBLE.md`'s "Data retention" section) was added alongside
      this so growth is an actual enforced bound, not just "however big
      the disk happens to be."
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
