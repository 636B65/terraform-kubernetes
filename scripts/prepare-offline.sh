#!/usr/bin/env bash
# Collects everything an offline (air-gapped) deployment needs from the
# internet into one directory, on a machine that has internet access:
#
#   - Terraform providers for the chosen platforms (a filesystem mirror),
#   - Ansible (ansible-core and its dependencies as Python wheels),
#   - ansible-role-kubernetes at the pinned version (a git repository),
#   - the Ubuntu 26.04 cloud image (.img) and/or OVA the chosen platforms
#     use, verified against SHA256SUMS,
#   - the Kubernetes bundle (kubernetes-offline.tar: packages, container
#     images, charts, manifests), built with the role's offline_build in an
#     Ubuntu 26.04 container (docker or podman). No cluster is needed.
#
# Copy the directory (or the .tar) to the offline network and follow the
# README.txt written into it.
#
# Usage: scripts/prepare-offline.sh [options]
#   -o DIR        Output directory (default: ./offline-kit)
#   -p PLATFORMS  Platform directories, comma separated, e.g. workstation
#                 (default: proxmox,vcenter,esxi,workstation,libvirt,virtualbox)
#   -a TARGETS    Terraform provider targets, comma separated (default:
#                 linux_amd64), e.g. linux_amd64,darwin_arm64,windows_amd64
#   -i IMAGES     Ubuntu images: auto, img, ova, both or none (default: auto =
#                 .img for proxmox/libvirt, OVA for the VMware platforms and
#                 VirtualBox)
#   -r VERSION    Role version (default: ansible_role_version in the repo)
#   -e FILE       Ansible variables (YAML) for the bundle build, repeatable:
#                 the same add-on switches and versions as the offline
#                 cluster, e.g. kubernetes_velero_enabled: true. Add-ons are
#                 off by default, like in the role.
#   -K            Skip the Kubernetes bundle
#   -t            Also pack the directory into DIR.tar
#
# UBUNTU_IMAGE_BASE overrides where the images and SHA256SUMS come from,
# CONTAINER_ENGINE (docker or podman) and BUILD_IMAGE (default ubuntu:26.04)
# the bundle build. The bundle is built for the architecture of this machine,
# which must match the offline nodes (amd64 for the cloud images here).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="./offline-kit"
platforms="proxmox,vcenter,esxi,workstation,libvirt,virtualbox"
targets="linux_amd64"
images="auto"
role_version=""
pack=0
bundle=1
var_files=()
build_image="${BUILD_IMAGE:-ubuntu:26.04}"
role_url="https://github.com/636B65/ansible-role-kubernetes.git"
image_base="${UBUNTU_IMAGE_BASE:-https://cloud-images.ubuntu.com/releases/26.04/release}"
image_name="ubuntu-26.04-server-cloudimg-amd64"

while getopts "o:p:a:i:r:e:Kth" opt; do
  case "$opt" in
    o) out="$OPTARG" ;;
    p) platforms="$OPTARG" ;;
    a) targets="$OPTARG" ;;
    i) images="$OPTARG" ;;
    r) role_version="$OPTARG" ;;
    e) [[ -f "$OPTARG" ]] || { echo "Error: $OPTARG does not exist." >&2; exit 1; }
       var_files+=("$(cd "$(dirname "$OPTARG")" && pwd)/$(basename "$OPTARG")") ;;
    K) bundle=0 ;;
    t) pack=1 ;;
    h) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 1 ;;
  esac
done
case "$images" in auto|img|ova|both|none) ;; *) echo "Error: -i must be auto, img, ova, both or none." >&2; exit 1 ;; esac
if [[ "$images" == auto ]]; then
  want_img=0 want_ova=0
  IFS=',' read -ra auto_platforms <<<"$platforms"
  for platform in "${auto_platforms[@]}"; do
    case "$platform" in
      proxmox|libvirt) want_img=1 ;;
      vcenter|esxi|workstation|virtualbox) want_ova=1 ;;
    esac
  done
  case "$want_img$want_ova" in
    11) images=both ;; 10) images=img ;; 01) images=ova ;; *) images=none ;;
  esac
fi

need() {
  command -v "$1" >/dev/null || { echo "Error: $1 is required." >&2; exit 1; }
}
need terraform
need git
need curl
need tar
if [[ "$bundle" == 1 ]]; then
  engine="${CONTAINER_ENGINE:-$(command -v docker >/dev/null && echo docker || echo podman)}"
  command -v "$engine" >/dev/null \
    || { echo "Error: docker or podman is required to build the Kubernetes bundle (or skip it with -K)." >&2; exit 1; }
fi
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
if git -C "$out/ansible-role-kubernetes" rev-parse --verify --quiet "refs/tags/$role_version" >/dev/null; then
  role_ref="refs/tags/$role_version"
elif git -C "$out/ansible-role-kubernetes" rev-parse --verify --quiet "origin/$role_version" >/dev/null; then
  role_ref="origin/$role_version"
else
  echo "Error: $role_version is not a tag or branch of $role_url." >&2
  exit 1
fi

# --- Kubernetes bundle ------------------------------------------------------------
if [[ "$bundle" == 1 ]]; then
  echo "== Kubernetes bundle (role $role_version, in $build_image with $engine)"
  role_tree="$(mktemp -d)"
  trap 'rm -rf "$role_tree"' EXIT
  mkdir -p "$role_tree/ansible-role-kubernetes"
  git -C "$out/ansible-role-kubernetes" archive "$role_ref" | tar -x -C "$role_tree/ansible-role-kubernetes"
  [[ -f "$role_tree/ansible-role-kubernetes/examples/offline-build.yml" ]] \
    || { echo "Error: role $role_version cannot build a bundle without a cluster (needs v3.4.0 or later)." >&2; exit 1; }

  mounts=(-v "$role_tree:/roles:ro" -v "$out:/kit")
  extra=()
  for i in "${!var_files[@]}"; do
    mounts+=(-v "${var_files[$i]}:/vars/$i.yml:ro")
    extra+=("-e" "@/vars/$i.yml")
  done
  # The bundle stays inside the container until it is packed into the kit.
  # shellcheck disable=SC2016 # expanded by the shell in the container
  "$engine" run --rm "${mounts[@]}" "$build_image" bash -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends ansible-core python3-apt
    owner="$1"; shift
    ANSIBLE_ROLES_PATH=/roles ansible-playbook -i localhost, -c local \
      -e ansible_become=false "$@" /roles/ansible-role-kubernetes/examples/offline-build.yml
    tar -C /opt/kubernetes-offline -cf /kit/kubernetes-offline.tar.part .
    chown "$owner" /kit/kubernetes-offline.tar.part
  ' bundle "$(id -u):$(id -g)" "${extra[@]}"
  mv "$out/kubernetes-offline.tar.part" "$out/kubernetes-offline.tar"
  tar -xOf "$out/kubernetes-offline.tar" ./VERSIONS > "$out/kubernetes-offline.VERSIONS"
  echo "   $(du -h "$out/kubernetes-offline.tar" | cut -f1) kubernetes-offline.tar"
fi

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
if [[ "$bundle" == 1 ]]; then
  bundle_text="kubernetes-offline.tar (versions in
   kubernetes-offline.VERSIONS). In terraform.tfvars:
     offline        = true
     offline_bundle = \"\$KIT/kubernetes-offline.tar\"
     run_ansible    = true
   and turn on the same add-ons (ansible_extra_vars, velero) as in the -e
   files of the build: add-ons that were not built in are missing offline."
else
  bundle_text="not included (-K). Build them with
   scripts/prepare-offline.sh, or stage them with stage_offline_bundle = true
   on an online cluster (README section \"Offline (air-gapped) deployment\"),
   then set offline = true and offline_bundle."
fi
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
     Workstation:        ubuntu_ova = "\$KIT/images/$image_name.ova"
                         ubuntu_image_sha256 = "$(sha "$image_name.ova")"
                         creates template_vmx from it (template_network =
                         nat, bridged, hostonly or vmnetN)
     vCenter:            import the OVA as a template, see the README.

5. Kubernetes packages and images: $bundle_text
TXT

if [[ "$pack" == 1 ]]; then
  echo "== Packing $out.tar"
  tar -C "$(dirname "$out")" -cf "$out.tar" "$(basename "$out")"
fi
echo "Done. See $out/README.txt"
