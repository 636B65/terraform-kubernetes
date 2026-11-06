#!/usr/bin/env bash
# Writes the parts that every platform shares from shared/ into the platform
# directories, so they are edited in one place:
#
#   shared/variables.common.tf.tmpl -> top of <platform>/variables.tf (the
#                                      platform's own variables follow the
#                                      last "# ---" banner and are kept)
#   shared/common.tf.tmpl           -> <platform>/common.tf
#   shared/ansible.tf.tmpl          -> <platform>/ansible.tf (__VM_RESOURCE__
#                                      becomes the platform's VM resource)
#   shared/terraform.tfvars.example.tmpl
#                                   -> <platform>/terraform.tfvars.example from
#                                      "# --- Login" on (the platform's own
#                                      settings above it are kept)
#
# Usage: scripts/sync-common.sh          write the files
#        scripts/sync-common.sh --check  only report files that differ (CI)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

declare -A vm_resource=(
  [proxmox]=proxmox_virtual_environment_vm.vm
  [vcenter]=vsphere_virtual_machine.vm
  [esxi]=esxi_guest.vm
  [workstation]=terraform_data.vm
  [libvirt]=libvirt_domain.vm
  [virtualbox]=terraform_data.vm
)
# Per platform in terraform.tfvars.example: an API VIP in the example network,
# the second-NIC settings and the image checksum hint ("" leaves it out).
declare -A api_vip=(
  [proxmox]=192.168.1.100 [vcenter]=192.168.1.100 [esxi]=192.168.1.100
  [workstation]=192.168.80.100 [libvirt]=192.168.122.100 [virtualbox]=192.168.1.100
)
declare -A secondary=(
  [proxmox]=$'# secondary_bridge  = "vmbr1"\n# secondary_vlan_id = 20'
  [vcenter]='# secondary_network = "Storage Network"'
  [esxi]='# secondary_network = "Storage Network"'
  [workstation]='# secondary_vnet = "vmnet2"'
  [libvirt]='# secondary_network_bridge = "br1"'
  [virtualbox]=$'# secondary_network_type = "hostonly"\n# secondary_network_name = "vboxnet0"'
)
declare -A image_sha=(
  [proxmox]='# ubuntu_image_sha256 = "..." # default: looked up in SHA256SUMS next to the URL'
  [vcenter]=''
  [esxi]='# ubuntu_image_sha256 = "..." # verifies a local ubuntu_ova at plan time'
  [workstation]='# ubuntu_image_sha256 = "..." # verifies ubuntu_ova at plan time'
  [libvirt]='# ubuntu_image_sha256 = "..." # verifies a local ubuntu_image_url at plan time'
  [virtualbox]='# ubuntu_image_sha256 = "..." # default: looked up in SHA256SUMS for a URL'
)
platforms=(proxmox vcenter esxi workstation libvirt virtualbox)
check=0
[[ "${1:-}" == "--check" ]] && check=1

generated() { # generated <source>: the header of a generated file
  printf '# Generated from %s by scripts/sync-common.sh; edit that file instead.\n\n' "$1"
}

platform_variables() { # platform_variables <file>: from the last banner on
  awk '{ line[NR] = $0 } /^# -{75}$/ { banner[++n] = NR }
       END { if (n < 2) exit 1; for (i = banner[n - 1]; i <= NR; i++) print line[i] }' "$1"
}

render() { # render <platform> <file>: the generated content
  local platform="$1" file="$2"
  case "$file" in
    variables.tf)
      generated shared/variables.common.tf.tmpl
      cat shared/variables.common.tf.tmpl
      echo
      platform_variables "$platform/variables.tf" \
        || { echo "Error: no platform banner in $platform/variables.tf." >&2; exit 1; }
      ;;
    common.tf)
      generated shared/common.tf.tmpl
      cat shared/common.tf.tmpl
      ;;
    ansible.tf)
      generated shared/ansible.tf.tmpl
      sed "s/__VM_RESOURCE__/${vm_resource[$platform]}/" shared/ansible.tf.tmpl
      ;;
    terraform.tfvars.example)
      sed '/^# --- Login/,$d' "$platform/terraform.tfvars.example"
      PLATFORM_VIP="${api_vip[$platform]}" PLATFORM_SECONDARY="${secondary[$platform]}" \
        PLATFORM_IMAGE_SHA="${image_sha[$platform]}" awk '
          /__SECONDARY__/ { print ENVIRON["PLATFORM_SECONDARY"]; next }
          /__IMAGE_SHA__/ {
            if (ENVIRON["PLATFORM_IMAGE_SHA"] != "") {
              print ""
              print "# --- Image verification -----------------------------------------------------------"
              print ENVIRON["PLATFORM_IMAGE_SHA"]
            }
            print ""
            next
          }
          { gsub(/__API_VIP__/, ENVIRON["PLATFORM_VIP"]); print }
        ' shared/terraform.tfvars.example.tmpl
      ;;
  esac
}

status=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for platform in "${platforms[@]}"; do
  for file in variables.tf common.tf ansible.tf terraform.tfvars.example; do
    render "$platform" "$file" > "$tmp"
    if ! cmp -s "$tmp" "$platform/$file"; then
      if [[ "$check" == 1 ]]; then
        echo "$platform/$file is out of date:" >&2
        diff -u --label "$platform/$file" --label "generated" "$platform/$file" "$tmp" >&2 || true
        status=1
      else
        cp "$tmp" "$platform/$file"
        echo "Updated $platform/$file"
      fi
    fi
  done
done
if [[ "$check" == 1 && "$status" == 0 ]]; then
  echo "The shared files are in sync in: ${platforms[*]}"
elif [[ "$check" == 1 ]]; then
  echo "Run scripts/sync-common.sh and commit the result." >&2
fi
exit "$status"
