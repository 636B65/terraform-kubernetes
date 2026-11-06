#!/usr/bin/env bash
# Runs the Workstation platform (workstation/, scripts/vm.sh) end to end with
# fake vmrun, vmware-vdiskmanager and ovftool, so the template creation from
# the OVA, the VM clone and .vmx edits, and destroy are tested without
# VMware Workstation. The fakes record their calls in calls.log.
# Usage: tests/workstation/run.sh   (needs terraform; run from anywhere)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
log="$work/calls.log"
mkdir -p "$bin" "$work/vms"

cat > "$bin/ovftool" <<SH
#!/usr/bin/env bash
echo "ovftool \$*" >> "$log"
vmx="\${*: -1}"
mkdir -p "\$(dirname "\$vmx")"
printf '%s\n' 'displayName = "ubuntu"' 'scsi0:0.fileName = "disk1.vmdk"' 'ethernet0.virtualDev = "vmxnet3"' > "\$vmx"
touch "\$(dirname "\$vmx")/disk1.vmdk"
SH
cat > "$bin/vmrun" <<SH
#!/usr/bin/env bash
echo "vmrun \$*" >> "$log"
case "\$3" in
  clone) mkdir -p "\$(dirname "\$5")"; cp "\$4" "\$5"; touch "\$(dirname "\$5")/disk1.vmdk" ;;
  deleteVM) rm -rf "\$(dirname "\$4")" ;;
  start|stop) ;;
  *) echo "unexpected vmrun call" >&2; exit 1 ;;
esac
SH
cat > "$bin/vmware-vdiskmanager" <<SH
#!/usr/bin/env bash
echo "vmware-vdiskmanager \$*" >> "$log"
SH
chmod +x "$bin"/*

echo "fake ova" > "$work/ubuntu.ova"
ova_sha="$(sha256sum "$work/ubuntu.ova" | cut -d' ' -f1)"
template="$work/templates/ubuntu/ubuntu.vmx"

cp -r "$repo_root" "$work/repo"
rm -rf "$work/repo/workstation/.terraform" "$work/repo/workstation/terraform.tfstate"*
cd "$work/repo/workstation"
cat > terraform.tfvars <<HCL
vms = {
  "ws-cp01" = { ip = "192.168.80.11", role = "control_plane" }
  "ws-wl01" = { ip = "192.168.80.21", role = "worker", secondary_ip = "10.10.0.21" }
}
gateway                 = "192.168.80.2"
vm_password             = "secret"
secondary_vnet          = "vmnet2"
secondary_prefix_length = 24
disk_gb                 = 40
template_vmx            = "$template"
ubuntu_ova              = "$work/ubuntu.ova"
ubuntu_image_sha256     = "$ova_sha"
template_network        = "vmnet8"
vm_directory            = "$work/vms"
host_os                 = "linux"
vmrun_path              = "$bin/vmrun"
vdiskmanager_path       = "$bin/vmware-vdiskmanager"
ovftool_path            = "$bin/ovftool"
HCL

fail() { echo "FAIL: $*" >&2; cat "$log" >&2; exit 1; }
vmx_has() { grep -qF "$2" "$1" || fail "$1 lacks: $2"; }

echo "== apply"
terraform init -input=false -no-color >/dev/null
terraform apply -auto-approve -input=false -no-color >/dev/null

echo "== template"
vmx_has "$template" 'ethernet0.connectionType = "custom"'
vmx_has "$template" 'ethernet0.vnet = "vmnet8"'
[[ "$(grep -c '^ovftool' "$log")" == 1 ]] || fail "ovftool must run once"

echo "== VMs"
for vm in ws-cp01 ws-wl01; do
  vmx="$work/vms/$vm/$vm.vmx"
  [[ -f "$vmx" ]] || fail "$vmx was not created"
  vmx_has "$vmx" 'guestinfo.userdata.encoding = "base64"'
  vmx_has "$vmx" 'numvcpus = "2"'
  vmx_has "$vmx" 'memsize = "4096"'
  base64 -d <<<"$(sed -n 's/^guestinfo.userdata = "\(.*\)"$/\1/p' "$vmx")" | grep -q '"hostname": "'"$vm"'"' \
    || fail "$vm: user-data without its hostname"
  grep -q "vmrun -T ws start $vmx nogui" "$log" || fail "$vm was not started"
  grep -q "vmware-vdiskmanager -x 40GB $work/vms/$vm/disk1.vmdk" "$log" || fail "$vm: disk not expanded"
done
vmx_has "$work/vms/ws-wl01/ws-wl01.vmx" 'ethernet1.vnet = "vmnet2"'
if grep -q '^ethernet1' "$work/vms/ws-cp01/ws-cp01.vmx"; then fail "ws-cp01 has no secondary_ip"; fi

echo "== second apply changes nothing"
terraform plan -detailed-exitcode -input=false -no-color >/dev/null || fail "the second plan is not empty"

echo "== destroy keeps the template"
terraform destroy -auto-approve -input=false -no-color >/dev/null
[[ ! -e "$work/vms/ws-cp01" && ! -e "$work/vms/ws-wl01" ]] || fail "VM directories remain"
[[ -f "$template" ]] || fail "the template was deleted"

echo "== apply again uses the existing template"
terraform apply -auto-approve -input=false -no-color >/dev/null
[[ "$(grep -c '^ovftool' "$log")" == 1 ]] || fail "ovftool ran again for an existing template"
terraform destroy -auto-approve -input=false -no-color >/dev/null
echo "OK"
