# Troubleshooting the libvirt platform on Ubuntu

This document records every problem we hit while deploying the `libvirt/`
platform on a fresh **Ubuntu 26.04** host, in the order we hit them, with the
commands that fixed each one. On Arch Linux everything below worked out of the
box with the stock `libvirtd` + group membership; Ubuntu behaves differently in
several places, mostly because of its daemon setup, group configuration and
AppArmor.

The workflow that exercises this platform end to end (VMs created with
Terraform, Kubernetes installed with `ansible-role-kubernetes`, cluster checks)
is `.github/workflows/e2e-libvirt.yml`.

## 1. `Unable to Connect to Libvirt: no such file or directory`

```
Error: failed to dial libvirt: dial unix /var/run/libvirt/libvirt-sock:
connect: no such file or directory
```

On Arch, `libvirtd.service` starts on demand and the socket exists. On a fresh
Ubuntu the daemon may not be running yet, or only partially enabled.

```bash
sudo apt install -y libvirt-daemon-system libvirt-clients
sudo systemctl enable --now libvirtd   # legacy monolithic daemon (this repo's URI path)
# or the modular equivalents: virtqemud.socket virtstoraged.socket virtnetworkd.socket

ls -l /run/libvirt/        # libvirt-sock must exist here afterwards
virsh -c qemu:///system list --all
```

Note the socket is `/run/libvirt/libvirt-sock` (`/var/run` is a symlink).

## 2. `Permission denied` on the socket when connecting as your user

With the daemon up, the next failure is connecting as your user:

```
error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': Permission denied
```

The socket is `root:libvirt  srw-rw----`. Your user must be in the `libvirt`
group — on Arch this is often already the case, on Ubuntu it is not:

```bash
sudo usermod -aG libvirt $USER
```

**Important:** the group only applies to *new* sessions. Log out completely
(and back in), not just reopen the terminal. Until then:

```bash
newgrp libvirt          # temporary shell with the group active
virsh -c qemu:///system list --all
```

Verify with `id` (shows your *session's* groups) rather than `id $USER`
(shows what future sessions will get). This exact distinction cost us an hour.

As a stopgap, `sudo terraform plan` also works — but it leaves root-owned
`.terraform/` and state files behind (`sudo chown -R $USER:$USER` them later),
so prefer fixing the group.

## 3. `Storage pool 'default' not found`

```
Error: Pool Not Found ... no storage pool with matching name 'default'
```

Ubuntu does **not** ship a `default` storage pool (Arch setups usually have one
created by virt-manager). `terraform.tfvars` sets `storage_pool = "default"`,
so create it once:

```bash
sudo virsh pool-define-as --name default --type dir --target /var/lib/libvirt/images
sudo virsh pool-start default
sudo virsh pool-autostart default
sudo virsh pool-list --all
```

## 4. QEMU cannot open the disk: `Permission denied` on the .qcow2

The VMs get defined but fail to start:

```
internal error: process exited while connecting to monitor:
qemu-system-x86_64: -blockdev ... Could not open
'/var/lib/libvirt/images/kube01.qcow2': Permission denied
```

QEMU runs as the `libvirt-qemu` user. There are two separate causes on Ubuntu;
we hit both — check for **both** before burning more attempts.

### 4a. File permissions (DAC)

Terraform-created volumes were `root:root 0600`, unreadable by `libvirt-qemu`.
Give the QEMU user access and make new files inherit it:

```bash
sudo apt install -y acl
sudo chown root:root /var/lib/libvirt/images
sudo chmod 755 /var/lib/libvirt/images
sudo setfacl -m  u:libvirt-qemu:rwx /var/lib/libvirt/images
sudo setfacl -m  d:u:libvirt-qemu:rwx /var/lib/libvirt/images   # default (inherit) ACL
sudo setfacl -R -m u:libvirt-qemu:rw /var/lib/libvirt/images/*.qcow2
sudo setfacl -R -m u:libvirt-qemu:rx /var/lib/libvirt/images/*.iso 2>/dev/null
```

Verify:

```bash
sudo getfacl /var/lib/libvirt/images
sudo getfacl /var/lib/libvirt/images/kube01.qcow2
```

The `d:` (default) ACL entry is the important one: without it every newly
created volume reintroduces the problem on the next apply.

### 4b. AppArmor denies the read (MAC)

Even with correct DAC, Ubuntu's libvirt builds a dynamic AppArmor profile per
domain. When domains are redefined repeatedly during failed applies, stale
profiles can deny the read:

```
kernel: audit: type=1400 apparmor="DENIED" operation="open" ...
profile="libvirt-<uuid>" name="/var/lib/libvirt/images/kubeXX.qcow2" ...
```

Check for *fresh* (timestamped after your fixes) DENIED lines:

```bash
sudo journalctl -k --since "10 minutes ago" | grep -i "apparmor.*DENIED"
```

For a lab host, disable libvirt's AppArmor confinement of QEMU (ordinary UNIX
permissions above still protect the files):

```bash
sudo sed -i 's/^#\?security_driver.*/security_driver = "none"/' /etc/libvirt/qemu.conf
grep security_driver /etc/libvirt/qemu.conf      # must show: security_driver = "none"
sudo systemctl restart libvirtd
sudo rm -f /etc/apparmor.d/libvirt/libvirt-*     # drop stale per-domain profiles
```

Then re-run `terraform apply`. For production hosts prefer keeping AppArmor and
extending `/etc/apparmor.d/libvirt/TEMPLATE.qemu` with a rule for the images
directory instead.

### 4c. Half-failed applies leave stale state

After a failed start, domains may be undefined again but volumes remain in the
pool — and Terraform's state disagrees with libvirt. Symptoms include:

- `failed to get domain 'kubeXX'` when trying `virsh start` — the domains are
  gone; a plain `terraform apply` recreates them.
- `Storage volume '...' exists already` — old volumes are still in the pool.
- `Storage volumes cannot be updated. All changes require replacement.` —
  a diff on `libvirt_volume.ubuntu`; usually resolved by removing and
  re-importing/recreating the volume.
- `Cannot import non-existent remote object` — the volume really is gone;
  just `terraform apply` to recreate it (the base image download is several GB,
  so import instead when possible:
  `terraform import libvirt_volume.ubuntu default/<volume-name>`).

Clean up so the next apply starts fresh, keeping the big base image (already
downloaded and checksum-verified):

```bash
sudo virsh vol-list default
for v in kube01 kube02 kube03 kube04 kube05 kube06; do
  sudo virsh vol-delete ${v}.qcow2 --pool default
  sudo virsh vol-delete ${v}-cloudinit.iso --pool default
done
terraform apply
```

## 5. Terraform applied the VMs but Ansible did not run

Expected behaviour, not an error: the role only runs when `run_ansible = true`
in `terraform.tfvars`. Otherwise Terraform stops after creating the VMs and
writing `.ansible/inventory.yml`. Run the role manually:

```bash
terraform output -raw ansible_command        # prints the ready-made command
```

or set `run_ansible = true` and apply again.

## 6. First boot smoke test

```bash
sudo virsh list                              # 6 VMs running
ping -c1 192.168.122.111                     # or ssh ubuntu@192.168.122.111
sudo virsh net-dhcp-leases default           # shows assigned IPs
```

On hosts where the guests cannot use hardware virtualization (or ARM hosts),
adjust `cpu_mode` in `terraform.tfvars`; the default mode may otherwise not
give the guests `kvm` acceleration.
