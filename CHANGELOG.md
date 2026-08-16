# 📦 Changelog

All notable changes to this infrastructure project will be documented here.

## [1.7.1](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.7.0...1.7.1) (2026-08-15)

### Bug Fixes

* **lint:** allow duplicate sibling headings in CHANGELOG.md's sections ([ce0ac85](https://github.com/bcochofel/homelab-proxmox-elastic/commit/ce0ac8528da5e81b319e71c437ad318b553311f9))
* **release:** switch changelog preset from conventionalcommits to angular ([bf632f9](https://github.com/bcochofel/homelab-proxmox-elastic/commit/bf632f966942745a6484f7befc5009a594f2e9c0))

## [1.7.0](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.6.0...1.7.0) (2026-08-15)

### Bug Fixes

* **release:** make feature/*/fix/* prereleases actually work ([6d57014](https://github.com/bcochofel/homelab-proxmox-elastic/commit/6d57014cb572d63c2a61c63d99005f13ca6251f3))
* **terraform:** correct nameserver default to CoreDNS primary + secondary ([df6adcf](https://github.com/bcochofel/homelab-proxmox-elastic/commit/df6adcfe4317291f91a265b3223d53fd74f62a9d))

### Features

* **terraform:** auto-assign VM IDs instead of hardcoding them ([6c822fd](https://github.com/bcochofel/homelab-proxmox-elastic/commit/6c822fd32d6cd431a03ada7543ffb6466362b883))

## [1.6.0](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.5.0...1.6.0) (2026-08-14)

### Features

* add Fleet Kubernetes agent policy for the K3s cluster ([023a1c4](https://github.com/bcochofel/homelab-proxmox-elastic/commit/023a1c43e220b6ba1e0a97f40848d3d410fbb146))

## [1.5.0](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.4.0...1.5.0) (2026-08-13)

### Features

* split VM disks into OS + data, add 7-day retention, rebuild on renamed template ([3bc4a69](https://github.com/bcochofel/homelab-proxmox-elastic/commit/3bc4a69f145eb7a43e96cacacd4a73b9d98eca18))

## [1.4.0](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.3.0...1.4.0) (2026-08-02)

### Features

* **ansible:** migrate Elastic Agents and APM to Fleet-managed (Phase 3 steps 2+3) ([96720c6](https://github.com/bcochofel/homelab-proxmox-elastic/commit/96720c68dd93a7f9c788813d614eec3c8b13b85b))

## [1.3.0](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.2.0...1.3.0) (2026-08-02)

### Features

* **ansible:** stand up Fleet Server (Phase 3, step 1) ([180ea51](https://github.com/bcochofel/homelab-proxmox-elastic/commit/180ea511e3ff8547c64899235fe8e0f4fa8755b5))

## [1.2.0](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.1.1...1.2.0) (2026-08-02)

### Features

* **ansible:** add Let's Encrypt TLS for Kibana's public URL ([61cd063](https://github.com/bcochofel/homelab-proxmox-elastic/commit/61cd0631babc2dae24b99d54644bed97379e5b0a))

## [1.1.1](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.1.0...1.1.1) (2026-08-01)

### Bug Fixes

* **packer:** let Europe/Lisbon timezone take effect, fix Kibana TLS docs ([f5f624e](https://github.com/bcochofel/homelab-proxmox-elastic/commit/f5f624e156d630625bb33e5833c6f6460762bbe7))

## [1.1.0](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.0.3...1.1.0) (2026-08-01)

### Features

* **ansible:** add TLS + auth (Phase 2) for the Elastic Stack cluster ([33dfc88](https://github.com/bcochofel/homelab-proxmox-elastic/commit/33dfc88f9b2ca23e3bff6f08ecbc373523a82bd8))

## [1.0.3](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.0.2...1.0.3) (2026-08-01)

### Bug Fixes

* **release:** stop double blank line in generated CHANGELOG.md ([3ba04f3](https://github.com/bcochofel/homelab-proxmox-elastic/commit/3ba04f38dd6bd793db7dc6e961d297d79d3889ac))

## [1.0.2](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.0.1...1.0.2) (2026-07-31)

### Bug Fixes

* **release:** stop double-escaping newlines in .releaserc.js ([5e0c745](https://github.com/bcochofel/homelab-proxmox-elastic/commit/5e0c745c0bc6a939f90ef808c70eae92902d8263))

## [1.0.1](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.0.0...1.0.1) (2026-07-31)

### Bug Fixes

* **ci:** drop ci.yml's push-to-main trigger — incompatible with no-commit-to-branch ([09cf76b](https://github.com/bcochofel/homelab-proxmox-elastic/commit/09cf76b1075656afdb9266f5bb19ca873f907a76))

## 1.0.0 (2026-07-31)

### Features

* **ansible:** implement full Ansible layer (apm_server, otel_demo, elastic_agent) and restructure playbooks/inventory ([a685d20](https://github.com/bcochofel/homelab-proxmox-elastic/commit/a685d2029d8822a21bae8932eae35e44eaf59b75))
* **packer:** add Packer pipeline for Ubuntu 24.04 template ([a471202](https://github.com/bcochofel/homelab-proxmox-elastic/commit/a4712027875ea34cd945c8c6f21df650318d6eb7))
* **packer:** add stripped-down Ubuntu 26.04 template ([3e21a20](https://github.com/bcochofel/homelab-proxmox-elastic/commit/3e21a200775342ee799f480c3740d297353f0901))
* **terraform:** add apm_server and otel_demo VM modules ([9979ff9](https://github.com/bcochofel/homelab-proxmox-elastic/commit/9979ff97829faa865fbcf232c70101a7c8b07b21))
* **terraform:** add Terraform layer to clone Elastic Stack VMs on Proxmox ([015b122](https://github.com/bcochofel/homelab-proxmox-elastic/commit/015b122f3b790e3b8e1749b6afd021527e75379d))

### Bug Fixes

* **ansible:** make otel_demo idempotent, fix elastic-agent docker/metrics, add service URLs to README ([2407be2](https://github.com/bcochofel/homelab-proxmox-elastic/commit/2407be2b4978c992550b9bee2cc63544f14e1e32))
* **ansible:** resolve real failures found running the pipeline against the live cluster ([77862aa](https://github.com/bcochofel/homelab-proxmox-elastic/commit/77862aaf0988b75e97316afaa5a724456195bc3f))
* **ci:** bump release.yml's Node version — semantic-release@25 needs >=22.14 ([d4299b6](https://github.com/bcochofel/homelab-proxmox-elastic/commit/d4299b66f737a857e8c1ad0c72161b34fbb7dd12)), closes [#11](https://github.com/bcochofel/homelab-proxmox-elastic/issues/11)
* **packer:** correct Proxmox host IP and grant SDN.Use for template build ([6e0de17](https://github.com/bcochofel/homelab-proxmox-elastic/commit/6e0de17489dc0b5ff7fe24e97d729142c2c892b3))
* **packer:** fix ubuntu-26.04 initrd network race, env-var passthrough, and add Trivy/Elastic Agent ([2a13e4d](https://github.com/bcochofel/homelab-proxmox-elastic/commit/2a13e4d7589b5e2344568ffddbec94e7c0c5d9bd))
* **packer:** run an initial Trivy scan at build time and quiet its output ([7372986](https://github.com/bcochofel/homelab-proxmox-elastic/commit/737298606e85b1f3dc6698c2ea8a81142b7e05e8))
* **packer:** scope Trivy's build-time scan, keep the daily cron comprehensive ([2080115](https://github.com/bcochofel/homelab-proxmox-elastic/commit/208011537c7c0b9acbed1b6a5b4c4c580f2ed9c5))
* **terraform:** bump kibana/apm_server disk defaults to match template ([84cee2c](https://github.com/bcochofel/homelab-proxmox-elastic/commit/84cee2c93e2c363df81d9adf64333f5193b656ae))
