# Ubuntu 26.04 VMs with Terraform

[![Release](https://github.com/636B65/terraform-kubernetes/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/636B65/terraform-kubernetes/actions/workflows/release.yml)
[![Track ansible-role-kubernetes](https://github.com/636B65/terraform-kubernetes/actions/workflows/track-ansible-role.yml/badge.svg)](https://github.com/636B65/terraform-kubernetes/actions/workflows/track-ansible-role.yml)
[![Latest release](https://img.shields.io/github/v/release/636B65/terraform-kubernetes?sort=semver)](https://github.com/636B65/terraform-kubernetes/releases/latest)
[![ansible-role-kubernetes](https://img.shields.io/github/v/release/636B65/ansible-role-kubernetes?sort=semver&label=ansible-role-kubernetes)](https://github.com/636B65/ansible-role-kubernetes/releases/latest)

Terraform templates that create **6 virtual machines running Ubuntu 26.04** on:

| Directory      | Platform                        | Provider / method                          |
|----------------|---------------------------------|--------------------------------------------|
| `proxmox/`     | Proxmox VE                      | `bpg/proxmox`                              |
| `vcenter/`     | VMware vCenter (vSphere)        | `vmware/vsphere`                           |
| `esxi/`        | Standalone VMware ESXi          | `josenk/esxi` (requires `ovftool`)         |
| `workstation/` | VMware Workstation (Win/Linux)  | `vmrun` + `vmware-vdiskmanager` via script |
| `libvirt/`     | KVM/QEMU via libvirt            | `dmacvicar/libvirt`                        |
| `virtualbox/`  | VirtualBox (Win/macOS/Linux)    | `VBoxManage` via script                    |

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
cd proxmox            # or vcenter / esxi / workstation / libvirt / virtualbox
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform apply
```

Then log in with `ssh <vm_username>@<ip>`. `terraform output vms` lists all VMs.

## Common variables

| Variable           | Description                                        | Default                 |
|--------------------|----------------------------------------------------|-------------------------|
| `vms`              | Map name → `{ ip, role?, ansible_host?, ipv6?, secondary_ip?, cpu?, memory_mb?, disk_gb? }` | `kube-cp01..03`, `kube-wl01..03` |
| `ip_prefix_length` | Netmask as prefix length                           | `24`                    |
| `gateway`          | Default gateway                                    | *(required)*            |
| `ipv6_prefix_length` | Prefix length of the per-VM `ipv6` addresses     | `64`                    |
| `ipv6_gateway`     | IPv6 default gateway                               | `null`                  |
| `secondary_prefix_length` | Prefix length of the second NIC's network   | `24`                    |
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

## Networking: IPv6, a second NIC and VLANs

Each VM can get a static IPv6 address next to its IPv4 address, and a second
NIC with its own IPv4 address (e.g. a storage or cluster network, without a
default route):

```hcl
ipv6_gateway = "2001:db8::1"
vms = {
  "kube-cp01" = { ip = "192.168.1.101", role = "control_plane", ipv6 = "2001:db8::101", secondary_ip = "10.10.0.101" }
  # ...
}
```

VMs with a `secondary_ip` get fixed MAC addresses on both NICs (derived from
the VM name, in VMware's static range `00:50:56:00-3f`), so cloud-init can tell
the NICs apart. Each platform has its own setting for the second NIC's network,
and VLANs work as follows:

| Platform | Second NIC network | VLAN |
|----------|--------------------|------|
| Proxmox | `secondary_bridge` | `vlan_id` and `secondary_vlan_id` tag the NICs |
| vCenter | `secondary_network` (port group) | Set on the port group |
| ESXi | `secondary_network` (port group) | Set on the port group |
| libvirt | `secondary_network_name` or `secondary_network_bridge` | Use a bridge on a VLAN interface (e.g. `br0.20`) |
| VirtualBox | `secondary_network_type` + `secondary_network_name` | Not supported by VirtualBox; use a host adapter on the VLAN |
| Workstation | `secondary_vnet` (e.g. `vmnet2`) | Not supported by Workstation; bridge a vmnet to a host VLAN adapter |

IPv6 and the second NIC are applied by cloud-init on the **first boot**.
VirtualBox and Workstation VMs are recreated when they change; on the other
platforms recreate existing VMs to apply them, e.g.
`terraform apply -replace='proxmox_virtual_environment_vm.vm["kube-cp01"]'`.
Kubernetes keeps using the IPv4 address in `ip` (or set `kubernetes_node_ip`
through `ansible_extra_vars` per your network design).

## Verifying the Ubuntu image

| Platform | Verification |
|----------|--------------|
| Proxmox | The node verifies the download. The SHA256 is looked up in the `SHA256SUMS` next to `ubuntu_image_url`, or set `ubuntu_image_sha256`. Turn off with `verify_ubuntu_image = false`. |
| VirtualBox | The script verifies the OVA after downloading it (against `SHA256SUMS`, or `ubuntu_image_sha256`). A local `ubuntu_ova` is verified when `ubuntu_image_sha256` is set. |
| libvirt, ESXi | Set `ubuntu_image_sha256` and use a **local** file in `ubuntu_image_url`/`ubuntu_ova`; it is checked at plan time. URLs are downloaded by the provider/ovftool and cannot be verified. |
| vCenter, Workstation | Verify the OVA before importing the template: `sha256sum -c SHA256SUMS --ignore-missing`. |

`scripts/prepare-offline.sh` downloads and verifies the images for you (see
[Offline](#offline-air-gapped-deployment)).

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

Terraform can create the template itself: set `ubuntu_ova` to the local OVA
(e.g. from the offline kit) and, if needed, `template_network` (`nat` by
default, `bridged`, `hostonly` or a custom `vmnetN`). When `template_vmx` does
not exist yet, `ovftool` imports the OVA there and connects it to that network;
it is never powered on, and `terraform destroy` keeps it.

Or create the template once by hand with `ovftool` (bundled with Workstation):

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

## libvirt (KVM/QEMU)

Requirements:

- A Linux host with KVM, QEMU and libvirt (`libvirtd` or the modular
  `virtqemud`), and a user in the `libvirt` group – or a remote host reached
  with `libvirt_uri = "qemu+ssh://user@kvm01/system"`.
- A storage pool (`storage_pool`, default `default`):
  `virsh pool-define-as default dir --target /var/lib/libvirt/images && virsh pool-autostart default && virsh pool-start default`.
- A network: either a libvirt network (`network_name`, default `default`, NAT on
  `192.168.122.0/24` with gateway `.1`) or a host bridge such as `br0`
  (`network_bridge`) to put the VMs directly on the LAN.

Terraform downloads the Ubuntu 26.04 cloud image into the pool once, gives
every VM a copy-on-write disk on top of it, and attaches a cloud-init NoCloud
ISO with the user, password, SSH settings and static IP. The guest CPU defaults
to `host-passthrough`; a VNC console listens on `127.0.0.1` on the host
(`virsh domdisplay <vm>`).

The default libvirt network hands out DHCP leases from `.2` to `.254`. Shrink
that range (`virsh net-edit default`) or use a bridge, so DHCP does not hand out
the static IPs in `vms`.

If the VMs do not start with `Could not open '/var/lib/libvirt/images/...':
Permission denied`, the AppArmor profile libvirt generates for each VM (Ubuntu
and Debian hosts) does not cover the disks. Add `security_driver = "none"` to
`/etc/libvirt/qemu.conf` and restart libvirtd (`virtqemud`), as the libvirt
provider documents. The E2E test does the same.

## VirtualBox

There is no well-maintained Terraform provider for VirtualBox, so Terraform runs
`scripts/vm.sh` (Linux/macOS) or `scripts/vm.ps1` (Windows). For each VM the
script:

1. builds a cloud-init NoCloud seed ISO (volume label `cidata`) with the user,
   password, SSH settings and static IP,
2. imports the Ubuntu 26.04 cloud image OVA with `VBoxManage import`, with the
   VM's CPU and memory,
3. converts the disk to VDI if needed and expands it to `disk_gb`,
4. sets the network adapter (virtio), a serial port (Ubuntu cloud images boot
   slowly without one; the console is logged to `console.log` in the VM
   folder) and attaches the seed ISO,
5. starts the VM (headless unless `start_gui = true`).

`terraform destroy` powers the VMs off and deletes them with their disks. The
OVA is downloaded once into `vm_directory` (or set `ubuntu_ova` to a local
file); the VMs are created in VirtualBox's default machine folder.

Requirements:

- VirtualBox 7.x (6.1 should work) with `VBoxManage` in `PATH`, or set
  `vboxmanage_path`. On Windows the default install path is used.
- To build the seed ISO: `xorriso` or `genisoimage` on Linux
  (`apt install xorriso`); macOS uses the built-in `hdiutil` and Windows the
  built-in IMAPI2 API.
- `curl` on Linux/macOS to download the OVA.

Networking (`network_type` and `network_name`):

| `network_type` | `network_name`                          | Notes |
|----------------|-----------------------------------------|-------|
| `bridged`      | Host adapter, see `VBoxManage list bridgedifs` | **Recommended.** VMs are on the LAN with internet access; use LAN IPs and gateway. |
| `natnetwork`   | NAT network, see `VBoxManage list natnets` | Internet access and VM-to-VM traffic, but the host cannot reach the VMs without port forwarding, so Ansible cannot run from the host. Gateway is the NAT network's `.1`. |
| `hostonly`     | Host-only adapter, e.g. `vboxnet0`      | Host and VMs can talk, but there is no internet access, which the Kubernetes install needs. |
| `hostonlynet`  | Host-only network (VirtualBox 7, macOS) | As `hostonly`. |

---

## Kubernetes with Ansible

Every platform writes an Ansible inventory for
[ansible-role-kubernetes](https://github.com/636B65/ansible-role-kubernetes) to
`<platform>/.ansible/inventory.yml`. VMs with `role = "control_plane"` go into
the `k8s_control_plane` group and the rest into `k8s_workers`. The role
variables (`kubernetes_api_vip`, `kubernetes_keepalived_auth_pass`,
`loginusername`, ...) are included.

Node names and addresses come from `vms` (role v3.0.0+ reads them from the
inventory):

- The key (e.g. `kube-cp01`) is the VM name, the hostname set by cloud-init and
  the Kubernetes node name. It must be lowercase letters, digits and hyphens.
- `ip` is the node's cluster address and becomes `ansible_host`.
- If Ansible should connect another way (e.g. a DNS name or a management
  address), set `ansible_host` on the VM. `ip` is then passed as
  `kubernetes_node_ip`:

  ```hcl
  "kube-cp01" = { ip = "192.168.1.101", role = "control_plane", ansible_host = "kube-cp01.mgmt.lab.local" }
  ```

The workflow [`track-ansible-role.yml`](.github/workflows/track-ansible-role.yml)
checks daily for new role releases and opens a pull request that updates
`ansible_role_version`. For that, enable *Settings → Actions → General →
Allow GitHub Actions to create and approve pull requests*; otherwise it opens an
issue with the update branch instead. Pull requests created by GitHub Actions
do not start CI themselves; the checks run when the change is merged to `main`
(or push an empty change to the branch to run them earlier).

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
| `ansible_role_version`            | Tag, branch or commit of the role                        | `v3.4.1`      |
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

### kubeconfig

After the playbook has run, Terraform fetches the admin kubeconfig from the
first controller (its server is the API virtual IP):

```bash
export KUBECONFIG=$(terraform output -raw kubeconfig)
kubectl get nodes
```

### Add-ons: ingress, cert-manager, Argo CD, Velero

ansible-role-kubernetes (v3.2.0+) can install Traefik as ingress controller,
cert-manager and Argo CD, and (v3.3.0+) Velero for backups of workloads and
volume data to S3/MinIO (see its
[add-on guide](https://github.com/636B65/ansible-role-kubernetes/blob/main/docs/addons.md)).
Argo CD is installed by default (since 0.9.0); the others are off. Change
them through `ansible_extra_vars`:

```hcl
ansible_extra_vars = {
  kubernetes_ingress_enabled      = true  # Traefik, NodePort 30080/30444
  kubernetes_cert_manager_enabled = true  # with a "selfsigned" ClusterIssuer
  kubernetes_argocd_enabled       = false # without Argo CD
}
```

Velero has its own (sensitive) variable, since it needs S3 credentials. It is
off unless `enabled = true`; then it backs up all namespaces, and with
`volume_backups` (default) the volume data, every day at 03:00 (`schedule`),
kept for 30 days (`ttl`):

```hcl
velero = {
  enabled    = true
  bucket     = "velero"
  s3_url     = "http://minio.lab.local:9000" # leave out for AWS S3
  region     = "minio"
  access_key = "velero"
  secret_key = "..." # e.g. TF_VAR_velero='{...}' or a secret store
}
```

Keep the keys out of version control: the inventory holding them is written
with mode `0600`.

The offline kit puts the add-ons of your settings into the bundle: build it
with `scripts/prepare-offline.sh -f terraform.tfvars` (see "Offline").

### Add and remove nodes

- **Add:** add a VM to `vms` and apply. Terraform creates it, the inventory
  changes, and the playbook runs again and joins the new node.
- **Remove:** in two applies, so the node leaves the cluster cleanly before
  its VM is deleted:
  1. `remove_nodes = ["kube-wl03"]` and apply: the role drains the node, moves
     Longhorn replicas away and removes it from Kubernetes (see its
     [scaling guide](https://github.com/636B65/ansible-role-kubernetes/blob/main/docs/scaling.md)).
     The VM keeps running.
  2. Remove the VM from `vms` and from `remove_nodes`, and apply: the VM is
     deleted and the playbook updates the remaining nodes.

### Upgrade Kubernetes

Set `kubernetes_upgrade = true`. Whenever `ansible_role_version` (which pins
the Kubernetes version) or `ansible_extra_vars` (e.g. `kubernetes_version`)
change, Terraform runs the role's rolling upgrade, one node at a time (see its
[upgrade guide](https://github.com/636B65/ansible-role-kubernetes/blob/main/docs/upgrade.md)).

### etcd backups

The role takes a daily etcd snapshot on every controller. Fetch the newest
snapshot and configuration archive of each controller to `etcd_backup_dir`
(default `.ansible/etcd-backups`) with:

```bash
eval "$(terraform output -raw etcd_backup_command)"
```

| Variable             | Description                                                    | Default |
|----------------------|----------------------------------------------------------------|---------|
| `remove_nodes`       | VMs to drain and remove from the cluster (VMs stay)            | `[]`    |
| `kubernetes_upgrade` | Run the rolling upgrade when the role version or extra vars change | `false` |
| `etcd_backup_dir`    | Where `etcd_backup_command` saves the backups                  | `null`  |

---

## Offline (air-gapped) deployment

ansible-role-kubernetes can install a cluster without internet access from a
bundle of packages, container images, charts and manifests (see its
[offline guide](https://github.com/636B65/ansible-role-kubernetes/blob/main/docs/offline.md)).
These templates build that bundle, together with everything else the offline
side needs, and install from it.

> The offline flow has not been verified end to end on an air-gapped network
> yet, in these templates or in the role. Test it in a lab first.

### 1. Build the offline kit (online, no cluster needed)

On a Linux machine with internet access, docker or podman, Terraform, git,
curl and Python (with pip), one command collects everything for the
platforms you use:

```bash
scripts/prepare-offline.sh -o offline-kit -p workstation -t
```

The kit holds:

- Terraform and the providers of the chosen platforms (a filesystem mirror)
  for each target in `-a`, e.g. `-a linux_amd64,windows_amd64` for a Windows
  Workstation host,
- Ansible for Linux on a portable CPython
  ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)),
  so it does not depend on the distribution's Python, and
  ansible-role-kubernetes at the pinned version,
- the host packages the Terraform/Ansible machine needs (git, sshpass,
  xorriso, OpenSSH client) as local apt/dnf repositories for the current
  releases: Debian 13, Ubuntu 26.04, RHEL/Rocky/AlmaLinux 10 and Fedora,
  built in containers of those releases (`-d` changes the list, `-d none`
  skips them),
- `install.sh` (Linux) and `install.ps1` (Windows, Terraform only) to install
  it all offline,
- the Ubuntu 26.04 image the platforms need, verified against `SHA256SUMS`:
  the `.img` for Proxmox and libvirt, the OVA for vCenter, ESXi, Workstation
  and VirtualBox (`-i` overrides),
- `kubernetes-offline.tar`: the Kubernetes packages with their dependencies,
  the container images, the Cilium chart and CLI, Helm and the add-on charts
  and manifests, built by the role's `offline_build` tasks (role v3.4.0+) in
  an Ubuntu 26.04 container. No cluster is deployed.

The bundle holds exactly the add-ons the offline cluster installs. Pass the
cluster's `terraform.tfvars` with `-f`, and the kit reads its
`ansible_extra_vars` and `velero` through the same module that writes the
inventory (`modules/role-vars`). Without `-f` the bundle has the defaults
(Argo CD on, the other add-ons off). The result is in
`kubernetes-offline.vars.json` in the kit:

```bash
scripts/prepare-offline.sh -o offline-kit -p workstation -f workstation/terraform.tfvars -t
```

`-e file.yml` adds more role variables for the build.

The kit's `README.txt` lists the settings to use offline. Run the script with
`-h` for all options; `-K` skips the Kubernetes bundle.

**Alternative: stage on an online cluster.** Deploy a cluster that has
internet access, with the same Ubuntu release, CPU architecture and role
version as the offline cluster, and let Terraform stage and fetch the bundle:

```hcl
run_ansible          = true
stage_offline_bundle = true
offline_bundle       = "~/kubernetes-offline.tar" # written here
```

After the normal install, Terraform runs the role with `--tags offline_stage`,
then [`ansible/fetch-offline-bundle.yml`](ansible/fetch-offline-bundle.yml)
packs the bundle on the first controller and fetches it to `offline_bundle`.
Expect several GB. The staging cluster can be destroyed afterwards.

### 2. Prepare the offline side

Copy the kit and this repository to the machine that runs Terraform on the
offline network and install it:

```bash
sudo /path/to/offline-kit/install.sh   # Debian, Ubuntu, RHEL, Rocky, AlmaLinux, Fedora
```

```powershell
powershell -ExecutionPolicy Bypass -File C:\offline-kit\install.ps1   # Windows: Terraform only
```

`install.sh` installs the host packages from the kit's repository for that
release, Terraform, and Ansible in a virtual environment in the kit (linked
into `/usr/local/bin`), and sets `TF_CLI_CONFIG_FILE` to the kit's
`terraformrc` so `terraform init` uses the providers mirror. `install.ps1`
does the Terraform part for the current user. Ansible does not run on
Windows: there, set `run_ansible = false` and run the `ansible_command`
output from a Linux machine or WSL with the kit installed.

Then follow the kit's `README.txt`: set `ansible_role_source`, the image
(`ubuntu_ova`, `ubuntu_image_url`, ...) and `offline_bundle` to the files in
the kit. On Workstation, `ubuntu_ova` lets Terraform create the template. A
weekly CI job installs a kit without network access on each of these
distributions and on Windows, and runs `terraform init` from the mirror.

Or do it by hand:

| What | How |
|------|-----|
| Terraform providers | On a connected machine: `terraform providers mirror /path/to/mirror` in each platform directory you use. Offline, point the CLI at it in `~/.terraformrc`: `provider_installation { filesystem_mirror { path = "/path/to/mirror" } }`. |
| Ansible | `pip download ansible-core` on a connected machine, `pip install --no-index --find-links ...` offline. |
| The role | Clone ansible-role-kubernetes to the Terraform machine and set `ansible_role_source = "/path/to/ansible-role-kubernetes"` (a local git repository; `ansible_role_version` must be a tag or branch in it). |
| Ubuntu image | Copy the cloud image or OVA. libvirt (`ubuntu_image_url`), VirtualBox, ESXi and Workstation (`ubuntu_ova`) take a local path. Proxmox: upload the `.img` to the node and set `ubuntu_image_file_id` (e.g. `local:iso/ubuntu-26.04-server-cloudimg-amd64.img`), or point `ubuntu_image_url` at an internal web server. vCenter uses the template you import. |
| DNS and time | Set `dns_servers` and `ntp_servers` to internal servers. The role needs synchronized clocks. |

### 3. Install offline

```hcl
offline        = true
offline_bundle = "/path/to/offline-kit/kubernetes-offline.tar" # from step 1
run_ansible    = true
ntp_servers    = ["10.0.0.5"]
dns_servers    = ["10.0.0.53"]
# apt_mirror   = "http://mirror.lab.local/ubuntu" # if you have an internal mirror
```

With `offline = true`:

- cloud-init installs no packages and disables the Ubuntu archive sources
  (`ubuntu.sources` is renamed to `ubuntu.sources.disabled`), so `apt-get
  update` only uses the bundle's local repository. With `apt_mirror` set, the
  sources point at the mirror instead and packages are installed from it.
- [`ansible/site.yml`](ansible/site.yml) unpacks `offline_bundle` into
  `/opt/kubernetes-offline` on every node (skipped when it is already there),
  then runs the role with `kubernetes_offline_mode: true`, which installs
  packages from the bundle and imports the images into containerd.

`apt_mirror` and `ntp_servers` can also be used without `offline`, for
example on a network that only reaches an internal mirror.

| Variable              | Description                                                        | Default |
|-----------------------|--------------------------------------------------------------------|---------|
| `offline`             | Install without internet access from `offline_bundle`              | `false` |
| `offline_bundle`      | Bundle archive on the Terraform machine (written by staging, read offline) | `null` |
| `stage_offline_bundle`| Stage a bundle after the online install and fetch it to `offline_bundle` | `false` |
| `apt_mirror`          | Internal Ubuntu archive mirror                                     | `null`  |
| `apt_security_mirror` | Internal Ubuntu security mirror (`null` = `apt_mirror`)            | `null`  |
| `ntp_servers`         | NTP servers                                                        | `[]`    |

kube-prometheus-stack is installed from its upstream Helm repository and is
not available offline (role limitation).

---

## Layout

```
modules/cloud-init/   shared cloud-init (user, password, SSH, network)
modules/ansible/      Ansible inventory, optional run of ansible-role-kubernetes and offline bundle staging
ansible/site.yml      playbook that unpacks an offline bundle and runs ansible-role-kubernetes
ansible/fetch-offline-bundle.yml  packs and fetches a staged offline bundle
ansible/fetch-kubeconfig.yml      fetches the admin kubeconfig
ansible/remove-node.yml           drains and removes nodes (remove_nodes)
ansible/upgrade.yml               rolling Kubernetes upgrade (kubernetes_upgrade)
ansible/fetch-etcd-backup.yml     fetches the newest etcd backups
scripts/prepare-offline.sh        collects everything for an offline install
scripts/sync-common.sh           writes the shared files from shared/ into every platform
shared/                           the common variables, common.tf and ansible.tf of all platforms
proxmox/              Proxmox VE
vcenter/              vCenter
esxi/                 standalone ESXi
workstation/          VMware Workstation (+ scripts/)
libvirt/              KVM/QEMU via libvirt
virtualbox/           VirtualBox (+ scripts/)
```

Each platform directory has `variables.tf` (common variables at the top,
platform-specific ones at the bottom), `common.tf`, `ansible.tf`, `main.tf`,
`outputs.tf`, `versions.tf` and `terraform.tfvars.example`.

The parts every platform shares are written from `shared/` and must not be
edited in the platform directories: the common variables (the top of
`variables.tf`, up to the platform's own banner), `common.tf` and `ansible.tf`
(with the Ansible outputs). Edit the file in `shared/`, then run
`scripts/sync-common.sh` and commit the result. CI and pre-commit fail when a
platform is out of date (`scripts/sync-common.sh --check`). A platform adds
packages to cloud-init with `local.platform_packages` in its `main.tf`.

## Development

CI (`.github/workflows/release.yml`) runs on every push and pull request:

- `fmt`, `init` and `validate` for every platform, with both Terraform and
  OpenTofu,
- `terraform test` / `tofu test` for `modules/cloud-init` (rendered cloud-init,
  networking, offline), `modules/ansible` (inventory, guards; mocked provider)
  and `modules/role-vars` (defaults, Velero, bundle variables),
- the Workstation platform end to end with fake `vmrun`, `vmware-vdiskmanager`
  and `ovftool` (`tests/workstation/run.sh`: template from the OVA, clones,
  `.vmx` edits, destroy),
- pre-commit with tflint, shellcheck, YAML checks and
  `scripts/sync-common.sh --check`, plus a Trivy misconfiguration scan,
- a syntax check of every playbook in `ansible/` against the pinned role.

End-to-end tests (`.github/workflows/e2e-libvirt.yml`) turn a GitHub runner
into a KVM host and deploy real clusters with the libvirt platform: one
controller and one worker, installed with `run_ansible` (without Longhorn, the
registry and Headlamp to fit the runner). Scenarios
(`tests/e2e/scenario.sh`):

| Scenario | When | Checks |
|----------|------|--------|
| `basic` | nightly | both nodes Ready, Cilium and Argo CD running |
| `addons` | weekly | also Traefik, cert-manager (ClusterIssuer ready) and Velero, with a backup written to an S3 server (moto) on the runner |
| `offline` | weekly | the VMs have no route out; the kit is built with `scripts/prepare-offline.sh -f terraform.tfvars` and the cluster is installed from its bundle |
| `upgrade` | weekly | the previous release is deployed, this commit is applied on top, no VM may be replaced, and the cluster must be healthy afterwards |

All run by hand too (`workflow_dispatch`, one scenario or `all`).
`tests/e2e/libvirt-host.sh` prepares any Ubuntu machine with KVM the same way,
to run them in a lab.

Run the same checks locally:

```bash
pip install pre-commit && pre-commit install   # needs terraform and tflint
pre-commit run --all-files
(cd modules/cloud-init && terraform init && terraform test)
(cd modules/ansible && terraform init && terraform test)
(cd modules/role-vars && terraform init && terraform test)
tests/workstation/run.sh
```

Provider versions are pinned by the committed `.terraform.lock.hcl` in every
platform directory (with checksums for Linux, macOS and Windows). Dependabot
proposes provider and GitHub Actions updates; after changing a version
constraint by hand, run the *Update provider lock files* workflow
(`.github/workflows/providers-lock.yml`) on your branch.

## Versioning and releases

The project follows [semver](https://semver.org/). The current version is in
`VERSION` and the changes are in `CHANGELOG.md`.

To upgrade an existing deployment, follow [UPGRADING.md](UPGRADING.md): it
says which versions replace VMs on which platform. Always read
`terraform plan` before `apply`.

To make a new release:

1. Bump the version in `VERSION`: MAJOR for incompatible changes (e.g. renamed
   or removed variables), MINOR for new functionality, PATCH for bug fixes.
2. Add a `## [x.y.z] - YYYY-MM-DD` section to `CHANGELOG.md`.
3. Push/merge to `main`.

The `.github/workflows/release.yml` workflow runs the checks above for
all platforms and then creates the tag `vx.y.z` and a GitHub release with the
section from `CHANGELOG.md`. If the tag already exists, no new release is
created. Only versions with a pre-release suffix (e.g. `1.2.0-rc.1`) are marked
as pre-release.
