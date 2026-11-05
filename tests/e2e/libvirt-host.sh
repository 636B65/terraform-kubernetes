#!/usr/bin/env bash
# Prepares a Linux host (a GitHub Actions runner or a lab machine) for the
# libvirt end-to-end test: KVM access, libvirt, the "default" storage pool and
# an isolated NAT network "e2e" (192.168.123.0/24, gateway and DNS on .1, no
# DHCP, so the static IPs cannot collide). Needs sudo. Safe to run again.
set -euo pipefail

if [[ ! -e /dev/kvm ]]; then
  echo "Error: /dev/kvm is missing; the host needs hardware virtualization." >&2
  exit 1
fi

step() { echo "== $*"; }

step "Allow QEMU to open /dev/kvm"
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
  | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm

step "Install QEMU and libvirt"
# Rebuilding the man page index makes apt slow on CI runners.
sudo rm -f /var/lib/man-db/auto-update
sudo timeout 300 apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive timeout 900 apt-get install -y -q --no-install-recommends \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients

step "Start libvirt"
# The AppArmor profile libvirt generates for each VM does not cover the
# volumes the provider creates, so QEMU cannot open the VM disks. The
# provider documents turning the security driver off on such hosts.
echo 'security_driver = "none"' | sudo tee -a /etc/libvirt/qemu.conf >/dev/null
sudo timeout 120 systemctl enable libvirtd
sudo timeout 120 systemctl restart libvirtd
for _ in $(seq 1 30); do
  [[ -S /var/run/libvirt/libvirt-sock ]] && break
  sleep 2
done
# The current user talks to qemu:///system without being in the libvirt group.
sudo chmod 0666 /var/run/libvirt/libvirt-sock

virsh() { timeout 60 virsh --connect qemu:///system "$@"; }

step "Storage pool"

if ! virsh pool-info default >/dev/null 2>&1; then
  virsh pool-define-as default dir --target /var/lib/libvirt/images
  virsh pool-build default
fi
virsh pool-start default 2>/dev/null || true
virsh pool-autostart default

step "Network e2e"
if ! virsh net-info e2e >/dev/null 2>&1; then
  net_xml="$(mktemp)"
  cat > "$net_xml" <<XML
<network>
  <name>e2e</name>
  <forward mode='nat'/>
  <bridge name='virbr-e2e' stp='on' delay='0'/>
  <dns enable='yes'/>
  <ip address='192.168.123.1' netmask='255.255.255.0'/>
</network>
XML
  virsh net-define "$net_xml"
  rm -f "$net_xml"
fi
virsh net-start e2e 2>/dev/null || true
virsh net-autostart e2e

virsh pool-list --all
virsh net-list --all
