#!/usr/bin/env bash
# Creates/deletes a VM in VMware Workstation (Linux host). Called by Terraform.
# Usage: vm.sh create|destroy  (parameters via environment variables)
set -euo pipefail

action="${1:?create or destroy}"
: "${VMRUN:?}" "${VM_VMX:?}"

set_vmx() { # set_vmx <key> <value>
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -F'=' '{ n=$1; gsub(/[ \t]+$/, "", n); if (tolower(n) != tolower(k)) print }' "$VM_VMX" > "$tmp"
  printf '%s = "%s"\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$VM_VMX"
  rm -f "$tmp"
}

case "$action" in
  create)
    : "${VDISKMANAGER:?}" "${TEMPLATE_VMX:?}" "${VM_NAME:?}" "${CPU:?}" "${MEMORY_MB:?}" "${DISK_GB:?}"
    : "${METADATA_B64:?}" "${USERDATA_B64:?}"

    if [[ -e "$VM_VMX" ]]; then
      echo "Error: $VM_VMX already exists." >&2
      exit 1
    fi
    mkdir -p "$(dirname "$VM_VMX")"

    echo "[$VM_NAME] Cloning $TEMPLATE_VMX"
    "$VMRUN" -T ws clone "$TEMPLATE_VMX" "$VM_VMX" full "-cloneName=$VM_NAME"

    echo "[$VM_NAME] Setting CPU=$CPU, memory=${MEMORY_MB}MB and cloud-init guestinfo"
    set_vmx numvcpus "$CPU"
    set_vmx cpuid.coresPerSocket "1"
    set_vmx memsize "$MEMORY_MB"
    set_vmx guestinfo.metadata "$METADATA_B64"
    set_vmx guestinfo.metadata.encoding "base64"
    set_vmx guestinfo.userdata "$USERDATA_B64"
    set_vmx guestinfo.userdata.encoding "base64"

    disk="$(grep -iE '^(scsi|sata|nvme|ide)[0-9]+:0\.fileName *=' "$VM_VMX" | grep -i '\.vmdk' | head -n1 | sed -E 's/.*= *"(.*)".*/\1/')"
    if [[ -n "$disk" ]]; then
      [[ "$disk" = /* ]] || disk="$(dirname "$VM_VMX")/$disk"
      echo "[$VM_NAME] Expanding disk to ${DISK_GB}GB"
      "$VDISKMANAGER" -x "${DISK_GB}GB" "$disk" \
        || echo "[$VM_NAME] Warning: could not expand the disk (is it already larger?)" >&2
    else
      echo "[$VM_NAME] Warning: no disk found in $VM_VMX" >&2
    fi

    echo "[$VM_NAME] Starting"
    "$VMRUN" -T ws start "$VM_VMX" "${START_MODE:-nogui}"
    ;;

  destroy)
    if [[ ! -e "$VM_VMX" ]]; then
      echo "$VM_VMX does not exist, nothing to delete."
      exit 0
    fi
    "$VMRUN" -T ws stop "$VM_VMX" hard 2>/dev/null || true
    "$VMRUN" -T ws deleteVM "$VM_VMX"
    rmdir "$(dirname "$VM_VMX")" 2>/dev/null || true
    ;;

  *)
    echo "Unknown action: $action" >&2
    exit 1
    ;;
esac
