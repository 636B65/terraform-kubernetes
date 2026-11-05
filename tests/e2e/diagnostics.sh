#!/usr/bin/env bash
# Collects what is needed to see why the E2E cluster failed: the libvirt
# view of the VMs and the network, QEMU's log, and - from the VM disks,
# mounted read-only after the VMs are powered off - the guest's cloud-init
# output, journal and netplan configuration. Also tries SSH first.
# Usage: diagnostics.sh <vm>=<ip> ...
set -uo pipefail

virsh() { timeout 60 virsh --connect qemu:///system "$@"; }
section() { printf '\n===== %s\n' "$*"; }

section "Host"
ip -br addr
virsh list --all
virsh net-dumpxml e2e
virsh net-dhcp-leases e2e

for pair in "$@"; do
  vm="${pair%%=*}"
  ip="${pair#*=}"
  section "$vm ($ip): SSH"
  ssh -i ~/.ssh/e2e -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ubuntu@$ip" \
    'cloud-init status --long; ip -br addr; sudo journalctl -u kubelet --no-pager | tail -n 50; sudo crictl ps -a 2>/dev/null | head -n 30'
  section "$vm: domain"
  virsh dominfo "$vm"
  virsh domifaddr "$vm" --source arp
  virsh dumpxml "$vm" | sed -n '/<os>/,/<\/os>/p;/<disk/,/<\/disk>/p;/<interface/,/<\/interface>/p'
  section "$vm: QEMU log"
  sudo tail -n 40 "/var/log/libvirt/qemu/$vm.log"
done

section "Guest disks"
virsh list --name | while read -r vm; do [[ -n "$vm" ]] && virsh destroy "$vm"; done
sudo modprobe nbd max_part=8
mnt="$(mktemp -d)"
for pair in "$@"; do
  vm="${pair%%=*}"
  disk="/var/lib/libvirt/images/$vm.qcow2"
  section "$vm: $disk"
  sudo qemu-img info "$disk"
  sudo qemu-nbd --read-only --connect /dev/nbd0 "$disk" || continue
  sleep 2
  sudo lsblk -f /dev/nbd0
  if sudo mount -o ro,noload /dev/nbd0p1 "$mnt"; then
    section "$vm: netplan"
    sudo sh -c "ls -l '$mnt/etc/netplan'; cat '$mnt'/etc/netplan/*.yaml"
    section "$vm: cloud-init-output.log"
    sudo tail -n 60 "$mnt/var/log/cloud-init-output.log"
    section "$vm: cloud-init.log (warnings)"
    sudo grep -E 'WARNING|ERROR|Traceback' "$mnt/var/log/cloud-init.log" | tail -n 40
    section "$vm: journal"
    sudo journalctl -D "$mnt/var/log/journal" --no-pager -o short-monotonic 2>/dev/null \
      | grep -Ei 'network|netplan|enp|eth|link|cloud-init|ssh|error|fail' | tail -n 80
    sudo umount "$mnt"
  else
    echo "Could not mount the root partition (the VM may never have booted)."
  fi
  sudo qemu-nbd --disconnect /dev/nbd0
  sleep 1
done
exit 0
