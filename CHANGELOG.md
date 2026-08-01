# 📦 Changelog

All notable changes to this infrastructure project will be documented here.

## [1.1.1](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.1.0...1.1.1) (2026-08-01)

## [1.1.0](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.0.3...1.1.0) (2026-08-01)

## [1.0.3](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.0.2...1.0.3) (2026-08-01)

## [1.0.2](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.0.1...1.0.2) (2026-07-31)

## [1.0.1](https://github.com/bcochofel/homelab-proxmox-elastic/compare/1.0.0...1.0.1) (2026-07-31)

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
