# Upgrading

How to move an existing deployment to a newer version of these templates.
The [CHANGELOG](CHANGELOG.md) lists every change; this guide covers what can
affect VMs and clusters that already exist.

## Every upgrade

1. Read the sections below for every version between yours and the target.
2. Pull the new version and run `terraform init -upgrade` in your platform
   directory.
3. **Run `terraform plan` and read it before `apply`.** Look for
   `must be replaced` and `destroy` on VMs (`terraform_data.vm`,
   `*_virtual_machine`, `*_vm`, `libvirt_domain`, `esxi_guest`). A replaced VM
   is a new, empty machine.
4. With `run_ansible = true`, a new default `ansible_role_version` runs the
   playbook again on `apply`. Read the role's
   [upgrade notes](https://github.com/636B65/ansible-role-kubernetes/blob/main/CHANGELOG.md)
   for the versions in between. Kubernetes itself is only upgraded by the
   rolling upgrade (`kubernetes_upgrade = true`, see the README).

### When VMs are replaced

The guest only reads cloud-init on its first boot. On **VirtualBox** and
**VMware Workstation** a VM is replaced (destroyed and created again) when its
rendered cloud-init changes, so a changed template replaces every VM there.
On Proxmox, vCenter, ESXi and libvirt the new cloud-init data is stored but
the running VMs keep their configuration.

The rendered cloud-init changed in **0.2.0**, **0.3.3** and **0.6.0** (and
changes whenever you change a setting in it, such as `extra_packages`). On
VirtualBox and Workstation, upgrading across one of these versions replaces
the VMs. To keep a cluster there, stay on the version you have, or rebuild it
deliberately: back up what you need (`etcd_backup_command`, your workloads),
apply, and run the playbook on the new VMs.

## 0.7.x → 0.8.0

- No change to resources or rendered cloud-init.
- Contributors: the common variables, `common.tf` and `ansible.tf` are
  generated from `shared/` (`scripts/sync-common.sh`); edit them there.

## 0.6.x → 0.7.0

- **Lock files are committed.** If you have a local
  `<platform>/.terraform.lock.hcl` that git does not track, `git pull` refuses
  to overwrite it: delete it, pull, and run `terraform init`.
- **Proxmox** needs the `hashicorp/http` provider, and the image download is
  now verified against `SHA256SUMS`. Adding the checksum can replace the
  download resource once (the image is downloaded again); the VMs are not
  affected because their disk ignores later image changes. Set
  `verify_ubuntu_image = false` to opt out.
- Default `ansible_role_version` `v3.2.0` (optional add-ons, off by default).
- IPv6 and a second NIC apply to new VMs only (first boot).

## 0.5.x → 0.6.0

- **Rendered cloud-init changed: VirtualBox and Workstation VMs are
  replaced** (see above).
- Proxmox: the image download resource got `count`; a `moved` block keeps the
  existing image, so nothing is downloaded again.

## 0.3.x → 0.4.0 / 0.5.0

- New platforms only (libvirt, VirtualBox). Nothing changes for existing ones.

## 0.3.2 → 0.3.3

- **Rendered cloud-init changed (`power_state` reboot): Workstation VMs are
  replaced.**
- Default `ansible_role_version` `v3.1.0`.

## 0.2.x → 0.3.0

- Default `ansible_role_version` `v3.0.0`, which takes node names and
  addresses from the inventory and can rename machines on the next run; read
  its upgrade notes first.
- VM names must now be lowercase letters, digits and hyphens, and IPs must be
  unique (`plan` fails otherwise).

## 0.1.x → 0.2.0

- **The default `vms` changed** from `ubuntu-01..06` to `kube-cp01..03` and
  `kube-wl01..03`. If you relied on the default, set `vms` explicitly to your
  old names, or every VM is replaced.
- Default `disk_gb` 40 → 60: Proxmox and vCenter grow the disks in place;
  ESXi and Workstation may replace the VMs. Set `disk_gb = 40` to keep them.
- Default `extra_packages` adds `open-iscsi` and `nfs-common`, which changes
  the rendered cloud-init (**Workstation VMs are replaced**); set
  `extra_packages = []` to keep the old value.
- The templates need the `hashicorp/local` provider: run
  `terraform init -upgrade`.
