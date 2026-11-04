#!/usr/bin/env bash
# Creates/deletes a VM in VirtualBox (Linux or macOS host). Called by Terraform.
# Usage: vm.sh image|create|destroy  (parameters via environment variables)
set -euo pipefail

action="${1:?image, create or destroy}"

vbox() { "$VBOXMANAGE" "$@"; }

vm_state() {
  vbox showvminfo "$VM_NAME" --machinereadable 2>/dev/null | sed -n 's/^VMState="\(.*\)"$/\1/p'
}

# Prints the VBoxManage modifyvm arguments that attach NIC <n>, one per line.
nic_args() { # nic_args <n> <type> <name>
  local n="$1" type="$2" name="$3"
  case "$type" in
    bridged)     printf '%s\n' "--nic$n" bridged "--bridgeadapter$n" "$name" ;;
    hostonly)    printf '%s\n' "--nic$n" hostonly "--hostonlyadapter$n" "$name" ;;
    hostonlynet) printf '%s\n' "--nic$n" hostonlynet "--host-only-net$n" "$name" ;;
    natnetwork)  printf '%s\n' "--nic$n" natnetwork "--nat-network$n" "$name" ;;
    *) echo "Unknown network type: $type" >&2; return 1 ;;
  esac
  printf '%s\n' "--nictype$n" virtio "--cableconnected$n" on
}

# Builds a cloud-init NoCloud seed ISO (volume label "cidata") from a directory.
make_iso() { # make_iso <dir> <iso>
  local dir="$1" iso="$2"
  if command -v xorriso >/dev/null; then
    xorriso -as mkisofs -quiet -output "$iso" -volid cidata -joliet -rock "$dir"
  elif command -v genisoimage >/dev/null; then
    genisoimage -quiet -output "$iso" -volid cidata -joliet -rock "$dir"
  elif command -v mkisofs >/dev/null; then
    mkisofs -quiet -output "$iso" -volid cidata -joliet -rock "$dir"
  elif command -v hdiutil >/dev/null; then
    hdiutil makehybrid -quiet -o "$iso" -iso -joliet -default-volume-name cidata "$dir"
  else
    echo "Error: install xorriso or genisoimage to build the cloud-init ISO." >&2
    exit 1
  fi
}

# Checks $OVA against OVA_SHA256, or against the SHA256SUMS next to the URL it
# was downloaded from. A local file without OVA_SHA256 is not verified.
verify_ova() {
  [[ "${VERIFY_SHA256:-1}" == 1 ]] || return 0
  local expected="${OVA_SHA256:-}" actual
  if [[ -z "$expected" ]]; then
    if [[ ! "$OVA_SOURCE" =~ ^https?:// ]]; then
      echo "Note: $OVA is not verified; set ubuntu_image_sha256 to verify a local file."
      return 0
    fi
    expected="$(curl -fsSL --retry 3 "${OVA_SOURCE%/*}/SHA256SUMS" \
      | awk -v f="${OVA_SOURCE##*/}" '$2 == f || $2 == "*" f { print $1 }')"
    if [[ -z "$expected" ]]; then
      echo "Error: no SHA256 for ${OVA_SOURCE##*/} in ${OVA_SOURCE%/*}/SHA256SUMS. Set ubuntu_image_sha256, or verify_ubuntu_image = false." >&2
      exit 1
    fi
  fi
  if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$OVA" | awk '{ print $1 }')"
  else
    actual="$(shasum -a 256 "$OVA" | awk '{ print $1 }')"
  fi
  if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$expected")" != "$actual" ]]; then
    echo "Error: SHA256 of $OVA is $actual, expected $expected." >&2
    exit 1
  fi
  echo "Verified SHA256 of $OVA"
}

case "$action" in
  image)
    : "${OVA_SOURCE:?}" "${OVA:?}"
    if [[ "$OVA_SOURCE" =~ ^https?:// ]]; then
      if [[ -s "$OVA" ]]; then
        echo "Using downloaded $OVA"
      else
        mkdir -p "$(dirname "$OVA")"
        echo "Downloading $OVA_SOURCE"
        curl -fL --retry 3 -o "$OVA.part" "$OVA_SOURCE"
        mv "$OVA.part" "$OVA"
      fi
    elif [[ ! -s "$OVA" ]]; then
      echo "Error: $OVA not found." >&2
      exit 1
    fi
    verify_ova
    ;;

  create)
    : "${VBOXMANAGE:?}" "${OVA:?}" "${VM_NAME:?}" "${WORK_DIR:?}" "${CPU:?}" "${MEMORY_MB:?}" "${DISK_GB:?}"
    : "${NETWORK_TYPE:?}" "${NETWORK_NAME:?}" "${USERDATA_B64:?}" "${METADATA_B64:?}" "${NETWORK_CONFIG_B64:?}"

    if [[ -n "$(vm_state)" ]]; then
      echo "Error: a VirtualBox VM named $VM_NAME already exists." >&2
      exit 1
    fi

    seed="$WORK_DIR/$VM_NAME"
    rm -rf "$seed"
    mkdir -p "$seed/cidata"
    printf '%s' "$USERDATA_B64" | base64 --decode > "$seed/cidata/user-data"
    printf '%s' "$METADATA_B64" | base64 --decode > "$seed/cidata/meta-data"
    printf '%s' "$NETWORK_CONFIG_B64" | base64 --decode > "$seed/cidata/network-config"
    make_iso "$seed/cidata" "$seed/seed.iso"

    echo "[$VM_NAME] Importing $OVA"
    vbox import "$OVA" --vsys 0 --vmname "$VM_NAME" --ostype Ubuntu_64 \
      --cpus "$CPU" --memory "$MEMORY_MB" --options importtovdi

    info="$(vbox showvminfo "$VM_NAME" --machinereadable)"
    vm_dir="$(dirname "$(sed -n 's/^CfgFile="\(.*\)"$/\1/p' <<<"$info")")"

    # The first hard disk, as "<controller>-<port>-<device>"="<path>".
    disk_line="$(grep -E '^"[^"]+-[0-9]+-[0-9]+"="[^"]+\.(vdi|vmdk|VDI|VMDK)"$' <<<"$info" | head -n1)"
    if [[ -z "$disk_line" ]]; then
      echo "Error: no disk found on $VM_NAME after import." >&2
      exit 1
    fi
    key="$(sed -E 's/^"([^"]+)"=.*/\1/' <<<"$disk_line")"
    disk="$(sed -E 's/^"[^"]+"="(.*)"$/\1/' <<<"$disk_line")"
    controller="${key%-*-*}"
    port_dev="${key#"$controller"-}"
    port="${port_dev%-*}"
    device="${port_dev#*-}"

    # VMDK cannot be resized; convert it if the import kept that format.
    if [[ "$(tr "[:upper:]" "[:lower:]" <<<"$disk")" == *.vmdk ]]; then
      echo "[$VM_NAME] Converting $disk to VDI"
      vdi="${disk%.*}.vdi"
      vbox clonemedium disk "$disk" "$vdi" --format VDI
      vbox storageattach "$VM_NAME" --storagectl "$controller" --port "$port" --device "$device" --type hdd --medium "$vdi"
      vbox closemedium disk "$disk" --delete
      disk="$vdi"
    fi

    echo "[$VM_NAME] Expanding disk to ${DISK_GB}GB"
    vbox modifymedium disk "$disk" --resize $((DISK_GB * 1024)) \
      || echo "[$VM_NAME] Warning: could not expand the disk (is it already larger?)" >&2

    nic=()
    while IFS= read -r arg; do nic+=("$arg"); done < <(nic_args 1 "$NETWORK_TYPE" "$NETWORK_NAME")
    if [[ -n "${MAC1:-}" ]]; then
      nic+=(--macaddress1 "$MAC1")
    fi
    # A second NIC (with fixed MACs, so the guest can tell the NICs apart).
    if [[ -n "${SECONDARY_NETWORK_TYPE:-}" ]]; then
      while IFS= read -r arg; do nic+=("$arg"); done < <(nic_args 2 "$SECONDARY_NETWORK_TYPE" "$SECONDARY_NETWORK_NAME")
      nic+=(--macaddress2 "${MAC2:?}")
    fi

    # Ubuntu cloud images log to ttyS0 and boot slowly without a serial port.
    echo "[$VM_NAME] Setting network, serial console and cloud-init seed"
    vbox modifyvm "$VM_NAME" "${nic[@]}" \
      --uart1 0x3F8 4 --uartmode1 file "$vm_dir/console.log" \
      --description "Ubuntu 26.04 - managed by Terraform"

    vbox storagectl "$VM_NAME" --name cidata --add sata --controller IntelAhci --portcount 1
    vbox storageattach "$VM_NAME" --storagectl cidata --port 0 --device 0 --type dvddrive --medium "$seed/seed.iso"

    echo "[$VM_NAME] Starting"
    vbox startvm "$VM_NAME" --type "${START_TYPE:-headless}"
    ;;

  destroy)
    : "${VBOXMANAGE:?}" "${VM_NAME:?}" "${WORK_DIR:?}"
    if [[ -n "$(vm_state)" ]]; then
      if [[ "$(vm_state)" != "poweroff" && "$(vm_state)" != "aborted" ]]; then
        vbox controlvm "$VM_NAME" poweroff || true
      fi
      # Wait for the VM to stop and release its session lock.
      for _ in $(seq 1 30); do
        state="$(vm_state)"
        [[ "$state" == "poweroff" || "$state" == "aborted" ]] && vbox unregistervm "$VM_NAME" --delete 2>/dev/null && break
        sleep 2
      done
      if [[ -n "$(vm_state)" ]]; then
        echo "Error: could not delete $VM_NAME." >&2
        exit 1
      fi
      # The seed ISO stays registered as a DVD medium; remove it.
      vbox closemedium dvd "$WORK_DIR/$VM_NAME/seed.iso" 2>/dev/null || true
    else
      echo "$VM_NAME does not exist, nothing to delete."
    fi
    rm -rf "${WORK_DIR:?}/$VM_NAME"
    ;;

  *)
    echo "Unknown action: $action" >&2
    exit 1
    ;;
esac
