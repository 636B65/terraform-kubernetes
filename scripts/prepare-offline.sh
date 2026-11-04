#!/usr/bin/env bash
# Collects everything an offline (air-gapped) deployment needs from the
# internet into one directory, on a machine that has internet access:
#
#   - Terraform providers for the chosen platforms (a filesystem mirror),
#   - Ansible (ansible-core and its dependencies as Python wheels),
#   - ansible-role-kubernetes at the pinned version (a git repository),
#   - the Ubuntu 26.04 cloud image and/or OVA, verified against SHA256SUMS.
#
# Copy the directory (or the .tar) to the offline network and follow the
# README.txt written into it. The Kubernetes packages and images are not
# included; stage those with stage_offline_bundle (see the main README).
#
# Usage: scripts/prepare-offline.sh [options]
#   -o DIR        Output directory (default: ./offline-kit)
#   -p PLATFORMS  Platform directories, comma separated
#                 (default: proxmox,vcenter,esxi,workstation,libvirt,virtualbox)
#   -a TARGETS    Terraform provider targets, comma separated (default:
#                 linux_amd64), e.g. linux_amd64,darwin_arm64,windows_amd64
#   -i IMAGES     Ubuntu images: img, ova, both or none (default: both)
#   -r VERSION    Role version (default: ansible_role_version in the repo)
#   -t            Also pack the directory into DIR.tar
#
# UBUNTU_IMAGE_BASE overrides where the images and SHA256SUMS come from.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="./offline-kit"
platforms="proxmox,vcenter,esxi,workstation,libvirt,virtualbox"
targets="linux_amd64"
images="both"
role_version=""
pack=0
role_url="https://github.com/636B65/ansible-role-kubernetes.git"
image_base="${UBUNTU_IMAGE_BASE:-https://cloud-images.ubuntu.com/releases/26.04/release}"
image_name="ubuntu-26.04-server-cloudimg-amd64"

while getopts "o:p:a:i:r:th" opt; do
  case "$opt" in
    o) out="$OPTARG" ;;
    p) platforms="$OPTARG" ;;
    a) targets="$OPTARG" ;;
    i) images="$OPTARG" ;;
    r) role_version="$OPTARG" ;;
    t) pack=1 ;;
    h) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 1 ;;
  esac
done
case "$images" in img|ova|both|none) ;; *) echo "Error: -i must be img, ova, both or none." >&2; exit 1 ;; esac

need() {
  command -v "$1" >/dev/null || { echo "Error: $1 is required." >&2; exit 1; }
}
need terraform
need git
need curl
python="$(command -v python3 || command -v python || true)"
[[ -n "$python" ]] || { echo "Error: python3 is required." >&2; exit 1; }

if [[ -z "$role_version" ]]; then
  role_version="$(sed -n '/variable "ansible_role_version"/,/^}/s/.*default *= *"\(.*\)"/\1/p' "$repo_root/proxmox/variables.tf")"
fi

mkdir -p "$out"
out="$(cd "$out" && pwd)"
echo "Writing the offline kit to $out"

# --- Terraform providers ---------------------------------------------------
target_args=()
IFS=',' read -ra target_list <<<"$targets"
for target in "${target_list[@]}"; do
  target_args+=("-platform=$target")
done
IFS=',' read -ra platform_list <<<"$platforms"
for platform in "${platform_list[@]}"; do
  if [[ ! -d "$repo_root/$platform" ]]; then
    echo "Error: unknown platform $platform." >&2
    exit 1
  fi
  echo "== Terraform providers for $platform ($targets)"
  (cd "$repo_root/$platform" && terraform providers mirror "${target_args[@]}" "$out/terraform-providers")
done
cat > "$out/terraformrc" <<RC
# Use with: export TF_CLI_CONFIG_FILE=/path/to/offline-kit/terraformrc
# (adjust the path below to where the kit is on the offline machine).
provider_installation {
  filesystem_mirror {
    path = "$out/terraform-providers"
  }
  direct {
    exclude = ["*/*/*"]
  }
}
RC

# --- Ansible -----------------------------------------------------------------
echo "== Ansible (Python wheels for $("$python" -c 'import sys; print(sys.platform, sys.version.split()[0])'))"
"$python" -m pip download --quiet --dest "$out/python" ansible-core

# --- ansible-role-kubernetes ---------------------------------------------------
echo "== ansible-role-kubernetes $role_version"
rm -rf "$out/ansible-role-kubernetes"
git clone --quiet "$role_url" "$out/ansible-role-kubernetes"
git -C "$out/ansible-role-kubernetes" rev-parse --verify --quiet "refs/tags/$role_version" >/dev/null \
  || git -C "$out/ansible-role-kubernetes" rev-parse --verify --quiet "origin/$role_version" >/dev/null \
  || { echo "Error: $role_version is not a tag or branch of $role_url." >&2; exit 1; }

# --- Ubuntu images -------------------------------------------------------------
image_files=()
case "$images" in
  img) image_files=("$image_name.img") ;;
  ova) image_files=("$image_name.ova") ;;
  both) image_files=("$image_name.img" "$image_name.ova") ;;
esac
if [[ ${#image_files[@]} -gt 0 ]]; then
  mkdir -p "$out/images"
  curl -fsSL --retry 3 -o "$out/images/SHA256SUMS" "$image_base/SHA256SUMS"
  for file in "${image_files[@]}"; do
    expected="$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' "$out/images/SHA256SUMS")"
    [[ -n "$expected" ]] || { echo "Error: $file is not in SHA256SUMS." >&2; exit 1; }
    if [[ -s "$out/images/$file" ]] && [[ "$(sha256sum "$out/images/$file" 2>/dev/null || shasum -a 256 "$out/images/$file")" == "$expected"* ]]; then
      echo "== $file already downloaded and verified"
      continue
    fi
    echo "== Downloading $file"
    curl -fL --retry 3 -o "$out/images/$file.part" "$image_base/$file"
    actual="$( (sha256sum "$out/images/$file.part" 2>/dev/null || shasum -a 256 "$out/images/$file.part") | awk '{ print $1 }')"
    if [[ "$actual" != "$expected" ]]; then
      rm -f "$out/images/$file.part"
      echo "Error: SHA256 of $file is $actual, expected $expected." >&2
      exit 1
    fi
    mv "$out/images/$file.part" "$out/images/$file"
    echo "   verified $expected"
  done
fi

# --- Instructions --------------------------------------------------------------
sha() { awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$out/images/SHA256SUMS" 2>/dev/null || true; }
cat > "$out/README.txt" <<TXT
Offline kit for terraform-kubernetes (role $role_version, providers for
$targets, platforms $platforms). Created $(date -u +%Y-%m-%dT%H:%MZ).

Copy this directory to the machine that runs Terraform on the offline
network, then (with KIT=/path/to/the/kit there):

1. Terraform providers: edit the path in \$KIT/terraformrc, then
     export TF_CLI_CONFIG_FILE=\$KIT/terraformrc
   terraform init then installs the providers from the kit.

2. Ansible:
     python3 -m pip install --no-index --find-links \$KIT/python ansible-core
   (the wheels match the Python that made the kit: same OS, architecture
   and Python version).

3. In terraform.tfvars:
     ansible_role_source  = "\$KIT/ansible-role-kubernetes"
     ansible_role_version = "$role_version"

4. Ubuntu image (in images/, checked against images/SHA256SUMS):
     libvirt:            ubuntu_image_url = "\$KIT/images/$image_name.img"
                         ubuntu_image_sha256 = "$(sha "$image_name.img")"
     VirtualBox, ESXi:   ubuntu_ova = "\$KIT/images/$image_name.ova"
                         ubuntu_image_sha256 = "$(sha "$image_name.ova")"
     Proxmox:            upload $image_name.img to the node and set
                         ubuntu_image_file_id, or serve images/ over HTTP
                         and point ubuntu_image_url at it (SHA256SUMS is
                         looked up next to it).
     vCenter, Workstation: import the OVA as described in the README.

5. Kubernetes packages and images come from the offline bundle staged with
   stage_offline_bundle = true on an online cluster (see the README section
   "Offline (air-gapped) deployment"); set offline = true and offline_bundle.
TXT

if [[ "$pack" == 1 ]]; then
  echo "== Packing $out.tar"
  tar -C "$(dirname "$out")" -cf "$out.tar" "$(basename "$out")"
fi
echo "Done. See $out/README.txt"
