# Ubuntu 26.04 VMs with Terraform

Terraform templates that create **6 virtual machines running Ubuntu 26.04** on:

| Directory      | Platform                        | Provider / method                          |
|----------------|---------------------------------|--------------------------------------------|
| `proxmox/`     | Proxmox VE                      | `bpg/proxmox`                              |
| `vcenter/`     | VMware vCenter (vSphere)        | `vmware/vsphere`                           |
| `esxi/`        | Standalone VMware ESXi          | `josenk/esxi` (requires `ovftool`)         |
| `workstation/` | VMware Workstation (Win/Linux)  | `vmrun` + `vmware-vdiskmanager` via script |

All platforms use the official Ubuntu **cloud image** and **cloud-init**
(`modules/cloud-init`) to configure:

- **IP address**, prefix, gateway, DNS and hostname per VM
- **User and password** (the user gets sudo)
- **SSH enabled** with password login (plus optional public keys)
- **CPU, memory and disk** – globally or per VM

## Quick start

```bash
cd proxmox            # or vcenter / esxi / workstation
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform apply
```

Then log in with `ssh <vm_username>@<ip>`. `terraform output vms` lists all VMs.

## Common variables

| Variable           | Description                                        | Default                 |
|--------------------|----------------------------------------------------|-------------------------|
| `vms`              | Map name → `{ ip, cpu?, memory_mb?, disk_gb? }`    | 6 VMs `ubuntu-01..06`   |
| `ip_prefix_length` | Netmask as prefix length                           | `24`                    |
| `gateway`          | Default gateway                                    | *(required)*            |
| `dns_servers`      | DNS servers                                        | `["1.1.1.1","8.8.8.8"]` |
| `dns_domain`       | Search domain                                      | `""`                    |
| `vm_username`      | User                                               | `ubuntu`                |
| `vm_password`      | Password (also used for SSH)                       | *(required)*            |
| `ssh_public_keys`  | Public SSH keys                                    | `[]`                    |
| `cpu`              | vCPUs per VM                                       | `2`                     |
| `memory_mb`        | Memory per VM (MB)                                 | `4096`                  |
| `disk_gb`          | Disk per VM (GB, at least ~10)                     | `40`                    |
| `timezone`         | Time zone                                          | `Europe/Stockholm`      |
| `extra_packages`   | Extra apt packages                                 | `[]`                    |

Example of overriding a single VM:

```hcl
vms = {
  "ubuntu-01" = { ip = "192.168.1.101" }
  # ...
  "ubuntu-06" = { ip = "192.168.1.106", cpu = 4, memory_mb = 8192, disk_gb = 80 }
}
```

The password can also be passed as an environment variable instead of in the file:
`export TF_VAR_vm_password='...'`.

> The password ends up in plain text in the cloud-init data and in the
> Terraform state. Protect the state file and prefer SSH keys in production.

---

## Proxmox

Requirements:

- An API token (or user/password) allowed to create VMs.
- **SSH access to the node** – the provider uploads cloud-init snippets over SSH.
- A file-based datastore with the **Snippets** content type (Datacenter → Storage →
  `local` → Edit → Content → tick *Snippets*).

Terraform downloads `ubuntu-26.04-server-cloudimg-amd64.img` to the node
(`image_datastore`) and creates the VMs with IDs starting at `vm_id_start`
(9101–9106). `qemu-guest-agent` is installed automatically so Proxmox shows the IPs.

## vCenter

First create a template from the Ubuntu cloud image OVA (once), e.g. with `govc`:

```bash
export GOVC_URL=vcenter.lab.local GOVC_USERNAME=administrator@vsphere.local GOVC_PASSWORD=... GOVC_INSECURE=1
curl -LO https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.ova
govc import.ova -ds=datastore1 -name=ubuntu-2604-template ubuntu-26.04-server-cloudimg-amd64.ova
govc vm.markastemplate ubuntu-2604-template
```

**Important:** do not power on the template, and **disable vApp options** on it
(Edit Settings → VM Options → vApp Options → untick *Enable vApp options*)
before converting it to a template. Otherwise cloud-init picks the OVF
datasource instead of `guestinfo` and the static IP is not applied.

Terraform clones the template, sets CPU/memory/disk and passes cloud-init via
`guestinfo.metadata` / `guestinfo.userdata`.

## ESXi (standalone host without vCenter)

Requirements:

- **SSH enabled** on the ESXi host (Host → Actions → Services → Enable SSH).
- **VMware OVF Tool** (`ovftool`) installed and in `PATH` where Terraform runs.
- Preferably download the OVA locally first and point `ubuntu_ova` at the file –
  otherwise it is downloaded once per VM:
  ```bash
  curl -Lo /var/tmp/ubuntu-26.04-server-cloudimg-amd64.ova \
    https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.ova
  ```

## VMware Workstation

There is no well-maintained Terraform provider for Workstation, so Terraform
runs `scripts/vm.sh` (Linux) or `scripts/vm.ps1` (Windows). The script clones a
template with `vmrun`, sets CPU/memory and cloud-init `guestinfo` in the `.vmx`
file, expands the disk with `vmware-vdiskmanager` and starts the VM.
`terraform destroy` stops and deletes the VMs. The host OS is auto-detected
(`host_os` can be set explicitly).

Create the template once with `ovftool` (bundled with Workstation):

```powershell
# Windows
& "C:\Program Files (x86)\VMware\VMware Workstation\OVFTool\ovftool.exe" `
  --acceptAllEulas ubuntu-26.04-server-cloudimg-amd64.ova `
  C:\VMs\templates\ubuntu-2604-template\ubuntu-2604-template.vmx
```

```bash
# Linux
ovftool --acceptAllEulas ubuntu-26.04-server-cloudimg-amd64.ova \
  ~/vmware/templates/ubuntu-2604-template/ubuntu-2604-template.vmx
```

Then open the template in Workstation **without powering it on** and select a
network (NAT/vmnet8, Bridged or a custom vmnet). The IP addresses in `vms` must
be in that network – for NAT, see *Edit → Virtual Network Editor* (the gateway
is `.2`). If the template was powered on by mistake, recreate it; cloud-init
has already run in it.

Use forward slashes (`/`) in paths in `terraform.tfvars`, also on Windows.

---

## Layout

```
modules/cloud-init/   shared cloud-init (user, password, SSH, network)
proxmox/              Proxmox VE
vcenter/              vCenter
esxi/                 standalone ESXi
workstation/          VMware Workstation (+ scripts/)
```

Each platform directory has the same `variables.tf` (common variables at the
top, platform-specific ones at the bottom), `common.tf`, `main.tf`, `outputs.tf`,
`versions.tf` and `terraform.tfvars.example`.

## Versioning and releases

The project follows [semver](https://semver.org/). The current version is in
`VERSION` and the changes are in `CHANGELOG.md`.

To make a new release:

1. Bump the version in `VERSION`: MAJOR for incompatible changes (e.g. renamed
   or removed variables), MINOR for new functionality, PATCH for bug fixes.
2. Add a `## [x.y.z] - YYYY-MM-DD` section to `CHANGELOG.md`.
3. Push/merge to `main`.

The `.github/workflows/release.yml` workflow runs `terraform fmt`/`validate` for
all platforms and then creates the tag `vx.y.z` and a GitHub release with the
section from `CHANGELOG.md`. If the tag already exists, no new release is
created. Only versions with a pre-release suffix (e.g. `1.2.0-rc.1`) are marked
as pre-release.
