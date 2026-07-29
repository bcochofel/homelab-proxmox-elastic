# Packer

First stage of the Packer -> Terraform -> Ansible pipeline: builds the
Proxmox VM template(s) that Terraform later clones.

Each subdirectory under `packer/` is one self-contained template — its own
`*.pkr.hcl`/`variables.pkr.hcl`/`variables.pkrvars.hcl.example` and a README
with build instructions and the full deep-dive (what it builds, file map,
ADRs, variables reference) for that template. This doc covers what's shared
across all of them.

## Shared setup

- `packer/.envrc` exports `PKR_VAR_proxmox_api_url`, `_api_token_id`,
  `_api_token_secret`, `_node`, `_skip_tls_verify` via direnv, decrypted from
  the repo-root `secrets.yaml` (SOPS + age). All templates authenticate with
  the same `packer@pve` token.
- `make packer-init` runs `packer init .` (plugin download, non-mutating).
  `packer build` is not a Makefile target — run it directly from the
  template's own directory, so the one command that actually writes to
  Proxmox stays explicit rather than hidden behind a wrapper.

## Proxmox user & API token

Packer authenticates as its own Proxmox user/token, separate from the
Terraform and MCP tokens used elsewhere in this repo, so each tool's blast
radius matches what it actually needs. Current token id:
`packer@pve!packer-automation`. This one user/token is shared by every
template under `packer/` — there's no per-template Proxmox identity.

Create the role, user, and token from the Proxmox shell (or Datacenter ->
Permissions in the UI):

```bash
# 1. Role scoped to what the proxmox-iso builder actually does:
#    create a VM, configure it, boot/monitor it, allocate disk space,
#    and convert the finished VM to a template.
pveum role add PackerRole -privs "VM.Allocate,VM.Audit,VM.Config.CDROM,VM.Config.CPU,\
VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.Console,VM.Monitor,VM.PowerMgmt,Datastore.AllocateSpace,Datastore.AllocateTemplate,\
Datastore.Audit,Sys.Modify"

# 2. User for the role (no password needed; auth is via API token only)
pveum user add packer@pve --comment "Packer template builder"
pveum aclmod / -user packer@pve -role PackerRole

# 3. API token. --privsep 0 means the token inherits the user's ACL directly;
#    with --privsep 1 (default) you'd also need to ACL the token id itself.
pveum user token add packer@pve packer-automation --privsep 0
```

The last command prints the token secret once — it is not retrievable again.
Put `proxmox_api_token_id = "packer@pve!packer-automation"` and the printed
secret into `secrets.yaml` (SOPS-encrypted) so `packer/.envrc` can export them
as `PKR_VAR_proxmox_api_token_id` / `PKR_VAR_proxmox_api_token_secret`.

| Privilege | Why the builder needs it |
| --- | --- |
| `VM.Allocate` | Create the VM the ISO installs into |
| `VM.Audit` | Read VM config/state while polling build status |
| `VM.Config.CDROM` | Attach the boot ISO, unmount it post-install (`boot_iso.unmount`) |
| `VM.Config.CPU`, `VM.Config.Memory`, `VM.Config.Disk`, `VM.Config.HWType`, `VM.Config.Network` | Set cores/sockets/CPU type, memory, disks/SCSI controller, qemu-guest-agent flag, network adapter |
| `VM.Config.Options` | Set template description, tags |
| `VM.Console`, `VM.Monitor` | Send boot-command keystrokes and QEMU monitor commands during autoinstall |
| `VM.PowerMgmt` | Start/stop/reset the VM around the build |
| `Datastore.AllocateSpace` | Allocate the VM disk on `storage_pool` |
| `Datastore.AllocateTemplate` | Convert the finished VM into a template |
| `Datastore.Audit` | Read storage info (space checks, ISO lookup) |
| `Sys.Modify` | Node-level changes the plugin makes around VM lifecycle (e.g. temporary firewall/network state during boot) |

Not granted: `VM.Config.Cloudinit` and `Pool.Allocate` — no current template
uses Proxmox-native cloud-init (`cloud_init = false`, autoinstall drives OS
setup instead) or a resource pool, so neither privilege is exercised yet. Add
them only if a template's config changes to need them.
