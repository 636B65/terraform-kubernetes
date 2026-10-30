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

Optionally, Terraform also installs Kubernetes on the VMs with
[ansible-role-kubernetes](https://github.com/636B65/ansible-role-kubernetes),
see [Kubernetes with Ansible](#kubernetes-with-ansible).

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
| `vms`              | Map name → `{ ip, role?, cpu?, memory_mb?, disk_gb? }` | `kube-cp01..03`, `kube-wl01..03` |
| `ip_prefix_length` | Netmask as prefix length                           | `24`                    |
| `gateway`          | Default gateway                                    | *(required)*            |
| `dns_servers`      | DNS servers                                        | `["1.1.1.1","8.8.8.8"]` |
| `dns_domain`       | Search domain                                      | `""`                    |
| `vm_username`      | User                                               | `ubuntu`                |
| `vm_password`      | Password (also used for SSH)                       | *(required)*            |
| `ssh_public_keys`  | Public SSH keys                                    | `[]`                    |
| `cpu`              | vCPUs per VM                                       | `2`                     |
| `memory_mb`        | Memory per VM (MB)                                 | `4096`                  |
| `disk_gb`          | Disk per VM (GB, at least ~10)                     | `60`                    |
| `timezone`         | Time zone                                          | `Europe/Stockholm`      |
| `extra_packages`   | Extra apt packages                                 | `["open-iscsi","nfs-common"]` |

Example of overriding a single VM:

```hcl
vms = {
  "kube-cp01" = { ip = "192.168.1.101", role = "control_plane" }
  # ...
  "kube-wl03" = { ip = "192.168.1.113", role = "worker", cpu = 4, memory_mb = 8192, disk_gb = 100 }
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

## Kubernetes with Ansible

Every platform writes an Ansible inventory for
[ansible-role-kubernetes](https://github.com/636B65/ansible-role-kubernetes) to
`<platform>/.ansible/inventory.yml`. VMs with `role = "control_plane"` go into
the `k8s_control_plane` group and the rest into `k8s_workers`. The role
variables (`kubernetes_api_vip`, `kubernetes_keepalived_auth_pass`,
`loginusername`, ...) are included.

Set `run_ansible = true` and Terraform installs the role (pinned with
`ansible_role_version`) and runs [`ansible/site.yml`](ansible/site.yml) right
after the VMs are created. The playbook first waits for SSH and cloud-init, then
runs the role. It runs again when the inventory, role version or playbook changes.

```hcl
run_ansible                     = true
ssh_public_keys                 = ["ssh-ed25519 AAAA... user@host"]
ansible_ssh_private_key_file    = "~/.ssh/id_ed25519"
kubernetes_api_vip              = "192.168.1.100" # free IP, not used by any VM
kubernetes_keepalived_auth_pass = "k8s-vip1"      # at most 8 characters
ansible_extra_vars              = { kubernetes_observability_enabled = true }
```

| Variable                          | Description                                              | Default       |
|-----------------------------------|----------------------------------------------------------|---------------|
| `run_ansible`                     | Run the role after the VMs are created                   | `false`       |
| `ansible_ssh_private_key_file`    | SSH key for Ansible; `null` = use `vm_password` (needs `sshpass`) | `null` |
| `ansible_role_source`             | Git URL of the role                                      | GitHub repo   |
| `ansible_role_version`            | Tag, branch or commit of the role                        | `v2.0.0`      |
| `kubernetes_api_vip`              | Kubernetes API virtual IP (required with `run_ansible`)  | `null`        |
| `kubernetes_keepalived_auth_pass` | Keepalived password, max 8 characters (required with `run_ansible`) | `null` |
| `ansible_extra_vars`              | Extra role variables                                     | `{}`          |
| `ansible_playbook_args`           | Extra `ansible-playbook` arguments, e.g. `["--tags", "bootstrap"]` | `[]` |

Requirements: `ansible-playbook` (Ansible Core 2.16+) and `git` on the machine
running Terraform. Ansible does not run natively on Windows; for VMware
Workstation on Windows, run Terraform from WSL or leave `run_ansible = false`
and run the playbook from another machine.

To run the role manually instead (e.g. with `run_ansible = false`):

```bash
terraform output -raw ansible_command   # prints the full command
cd .ansible
ansible-galaxy role install --force -r requirements.yml -p roles
ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventory.yml ../../ansible/site.yml
```

> The inventory contains `vm_password` (when no SSH key is set) and the
> Keepalived password. It is written with mode `0600` and ignored by git.

---

## Layout

```
modules/cloud-init/   shared cloud-init (user, password, SSH, network)
modules/ansible/      Ansible inventory and optional run of ansible-role-kubernetes
ansible/site.yml      playbook that runs ansible-role-kubernetes
proxmox/              Proxmox VE
vcenter/              vCenter
esxi/                 standalone ESXi
workstation/          VMware Workstation (+ scripts/)
```

Each platform directory has the same `variables.tf` (common variables at the
top, platform-specific ones at the bottom), `common.tf`, `ansible.tf`, `main.tf`, `outputs.tf`,
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
