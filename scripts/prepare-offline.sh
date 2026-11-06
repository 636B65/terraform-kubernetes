#!/usr/bin/env bash
# Collects everything an offline (air-gapped) deployment needs from the
# internet into one directory, on a machine that has internet access:
#
#   - Terraform (the binary) and the providers of the chosen platforms (a
#     filesystem mirror), for every target in -a,
#   - Ansible for Linux: a portable CPython (python-build-standalone) and the
#     ansible-core wheels, independent of the distribution's Python,
#   - host packages for the Terraform/Ansible machine (git, sshpass, xorriso,
#     OpenSSH client) as local apt/dnf repositories for Debian, Ubuntu,
#     RHEL/Rocky/AlmaLinux and Fedora, built in containers of those releases,
#   - ansible-role-kubernetes at the pinned version (a git repository),
#   - the Ubuntu 26.04 cloud image (.img) and/or OVA the chosen platforms
#     use, verified against SHA256SUMS,
#   - the Kubernetes bundle (kubernetes-offline.tar: packages, container
#     images, charts, manifests), built with the role's offline_build in an
#     Ubuntu 26.04 container (docker or podman). No cluster is needed.
#
# Copy the directory (or the .tar) to the offline network, run install.sh
# (Linux, as root) or install.ps1 (Windows: Terraform only, Ansible does not
# run on Windows) and follow the README.txt written into it.
#
# Usage: scripts/prepare-offline.sh [options]
#   -o DIR        Output directory (default: ./offline-kit)
#   -p PLATFORMS  Platform directories, comma separated, e.g. workstation
#                 (default: proxmox,vcenter,esxi,workstation,libvirt,virtualbox)
#   -a TARGETS    Targets of the offline Terraform machine, comma separated
#                 (default: linux_amd64), e.g. linux_amd64,windows_amd64.
#                 Ansible is included for the linux_* targets.
#   -d RELEASES   Container images of the distributions the offline machine
#                 may run, for the host packages, comma separated, or none
#                 (default: the current releases debian:13,ubuntu:26.04,
#                 almalinux:10,fedora:latest). The AlmaLinux 10 packages
#                 serve RHEL 10 and Rocky Linux 10 as well. amd64 only.
#   -i IMAGES     Ubuntu images: auto, img, ova, both or none (default: auto =
#                 .img for proxmox/libvirt, OVA for the VMware platforms and
#                 VirtualBox)
#   -r VERSION    Role version (default: ansible_role_version in the repo)
#   -f TFVARS     The terraform.tfvars of the offline cluster: the bundle
#                 gets the add-ons and versions it sets (ansible_extra_vars,
#                 velero). Without it, the bundle has the template defaults
#                 (Argo CD on, the other add-ons off).
#   -e FILE       More Ansible variables (YAML) for the bundle build,
#                 repeatable, applied after -f, e.g.
#                 kubernetes_velero_enabled: true.
#   -K            Skip the Kubernetes bundle
#   -t            Also pack the directory into DIR.tar
#
# UBUNTU_IMAGE_BASE overrides where the images and SHA256SUMS come from,
# CONTAINER_ENGINE (docker or podman) and BUILD_IMAGE (default ubuntu:26.04)
# the bundle build, TERRAFORM_VERSION the Terraform release (default: the
# local terraform), PYTHON_STANDALONE_TAG and PYTHON_VERSION the portable
# CPython (default: release 20261020, Python 3.13). The bundle is built for the architecture of this machine,
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
tfvars=""
build_image="${BUILD_IMAGE:-ubuntu:26.04}"
releases="debian:13,ubuntu:26.04,almalinux:10,fedora:latest"
python_tag="${PYTHON_STANDALONE_TAG:-20261020}"
python_version="${PYTHON_VERSION:-3.13}"
python_base="https://github.com/astral-sh/python-build-standalone/releases/download/$python_tag"
role_url="https://github.com/636B65/ansible-role-kubernetes.git"
image_base="${UBUNTU_IMAGE_BASE:-https://cloud-images.ubuntu.com/releases/26.04/release}"
image_name="ubuntu-26.04-server-cloudimg-amd64"

while getopts "o:p:a:d:i:r:f:e:Kth" opt; do
  case "$opt" in
    o) out="$OPTARG" ;;
    p) platforms="$OPTARG" ;;
    a) targets="$OPTARG" ;;
    d) releases="$OPTARG" ;;
    i) images="$OPTARG" ;;
    r) role_version="$OPTARG" ;;
    e) [[ -f "$OPTARG" ]] || { echo "Error: $OPTARG does not exist." >&2; exit 1; }
       var_files+=("$(cd "$(dirname "$OPTARG")" && pwd)/$(basename "$OPTARG")") ;;
    f) [[ -f "$OPTARG" ]] || { echo "Error: $OPTARG does not exist." >&2; exit 1; }
       tfvars="$(cd "$(dirname "$OPTARG")" && pwd)/$(basename "$OPTARG")" ;;
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
if [[ "$bundle" == 1 || "$releases" != none ]]; then
  engine="${CONTAINER_ENGINE:-$(command -v docker >/dev/null && echo docker || echo podman)}"
  command -v "$engine" >/dev/null \
    || { echo "Error: docker or podman is required for the Kubernetes bundle and the host packages (or skip them with -K -d none)." >&2; exit 1; }
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
  # The local modules must be installed before the providers can be listed.
  (cd "$repo_root/$platform" && terraform get >/dev/null \
    && terraform providers mirror "${target_args[@]}" "$out/terraform-providers")
done

sha256() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{ print $1 }'; }

# download <url> <file> <expected sha256>
download() {
  curl -fsSL --retry 3 -o "$2.part" "$1"
  local actual
  actual="$(sha256 "$2.part")"
  if [[ "$actual" != "$3" ]]; then
    rm -f "$2.part"
    echo "Error: SHA256 of $1 is $actual, expected $3." >&2
    exit 1
  fi
  mv "$2.part" "$2"
}

# --- Terraform -------------------------------------------------------------------
terraform_version="${TERRAFORM_VERSION:-$(terraform version -json | "$python" -c 'import json, sys; print(json.load(sys.stdin)["terraform_version"])')}"
echo "== Terraform $terraform_version ($targets)"
tf_base="https://releases.hashicorp.com/terraform/$terraform_version"
tf_sums="$(curl -fsSL --retry 3 "$tf_base/terraform_${terraform_version}_SHA256SUMS")"
for target in "${target_list[@]}"; do
  zip="terraform_${terraform_version}_${target}.zip"
  expected="$(awk -v f="$zip" '$2 == f { print $1 }' <<<"$tf_sums")"
  [[ -n "$expected" ]] || { echo "Error: no Terraform $terraform_version for $target." >&2; exit 1; }
  mkdir -p "$out/terraform/$target"
  download "$tf_base/$zip" "$out/terraform/$zip" "$expected"
  "$python" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
    "$out/terraform/$zip" "$out/terraform/$target"
  chmod 0755 "$out/terraform/$target"/terraform* 2>/dev/null || true
  rm -f "$out/terraform/$zip"
done

# --- Ansible (Linux) ----------------------------------------------------------------
python_sums=""
for target in "${target_list[@]}"; do
  case "$target" in
    linux_amd64) triple=x86_64-unknown-linux-gnu machine=x86_64 ;;
    linux_arm64) triple=aarch64-unknown-linux-gnu machine=aarch64 ;;
    *) continue ;;
  esac
  [[ -n "$python_sums" ]] || python_sums="$(curl -fsSL --retry 3 "$python_base/SHA256SUMS")"
  archive="$(awk -v v="$python_version" -v t="$triple" '
    { f = $2; sub(/^\*/, "", f) }
    index(f, "cpython-" v ".") == 1 && f ~ ("-" t "-install_only\\.tar\\.gz$") { print $1, f; exit }
  ' <<<"$python_sums")"
  [[ -n "$archive" ]] || { echo "Error: no CPython $python_version for $triple in python-build-standalone $python_tag." >&2; exit 1; }
  file="${archive#* }"
  full_version="$(sed -E 's/^cpython-([0-9.]+)\+.*/\1/' <<<"$file")"
  echo "== Ansible for $target (portable CPython $full_version)"
  mkdir -p "$out/ansible"
  rm -f "$out/ansible/cpython-"*"-$target.tar.gz"
  download "$python_base/${file//+/%2B}" "$out/ansible/cpython-$full_version-$target.tar.gz" "${archive%% *}"
  abi="cp${python_version/./}"
  rm -rf "$out/ansible/wheels-$target"
  "$python" -m pip download --quiet --dest "$out/ansible/wheels-$target" --only-binary=:all: \
    --python-version "$python_version" --implementation cp --abi "$abi" --abi abi3 --abi none \
    --platform "manylinux2014_$machine" --platform "manylinux_2_17_$machine" \
    --platform "manylinux_2_28_$machine" --platform "manylinux_2_34_$machine" --platform any \
    ansible-core
done

# --- Host packages ---------------------------------------------------------------
if [[ "$releases" != none ]]; then
  IFS=',' read -ra release_list <<<"$releases"
  mkdir -p "$out/host-packages"
  for release in "${release_list[@]}"; do
    echo "== Host packages for $release"
    "$engine" run --rm -v "$repo_root/scripts/offline-kit/host-packages.sh:/host-packages.sh:ro" \
      -v "$out/host-packages:/out" "$release" bash /host-packages.sh "$(id -u):$(id -g)"
  done
fi

cp "$repo_root/scripts/offline-kit/install.sh" "$repo_root/scripts/offline-kit/install.ps1" "$out/"
chmod 0755 "$out/install.sh"

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

  # The role variables the cluster will use (modules/role-vars, the same
  # module that writes the inventory), so the bundle has what it installs.
  vars_root="$role_tree/role-vars"
  mkdir -p "$vars_root"
  cat > "$vars_root/main.tf" <<TF
variable "ansible_extra_vars" {
  type    = any
  default = {}
}

variable "velero" {
  type      = any
  default   = {}
  sensitive = true
}

module "role_vars" {
  source     = "$repo_root/modules/role-vars"
  extra_vars = var.ansible_extra_vars
  velero     = var.velero
}

output "bundle_vars" {
  value = module.role_vars.bundle_vars
}
TF
  tf_args=()
  [[ -z "$tfvars" ]] || tf_args=("-var-file=$tfvars")
  terraform -chdir="$vars_root" init -backend=false -input=false >/dev/null
  terraform -chdir="$vars_root" plan -input=false -compact-warnings -out=plan "${tf_args[@]}" >/dev/null
  terraform -chdir="$vars_root" show -json plan \
    | "$python" -c 'import json, sys; json.dump(json.load(sys.stdin)["planned_values"]["outputs"]["bundle_vars"]["value"], sys.stdout, indent=2, sort_keys=True)' \
    > "$out/kubernetes-offline.vars.json"
  echo >> "$out/kubernetes-offline.vars.json"
  echo "   Role variables for the bundle (kubernetes-offline.vars.json):"
  sed 's/^/     /' "$out/kubernetes-offline.vars.json"

  mounts=(-v "$role_tree:/roles:ro" -v "$out:/kit")
  extra=("-e" "@/kit/kubernetes-offline.vars.json")
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
   The bundle holds the add-ons in kubernetes-offline.vars.json (from
   -f terraform.tfvars and -e). Turn on no other add-ons offline: they are
   not in the bundle."
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

1. Install the tools on the machine that runs Terraform:
     Linux (Debian, Ubuntu, RHEL, Rocky, AlmaLinux, Fedora), as root:
       sudo \$KIT/install.sh
     It installs git, sshpass, xorriso and the OpenSSH client from the kit
     (host packages for: $(cd "$out/host-packages" 2>/dev/null && echo -- * | sed 's/^-- //')),
     Terraform $terraform_version, and Ansible on a portable Python, and sets
     TF_CLI_CONFIG_FILE to \$KIT/terraformrc (the providers mirror).
     Windows (Terraform only), in PowerShell:
       powershell -ExecutionPolicy Bypass -File \$KIT\\install.ps1
     Ansible does not run on Windows: set run_ansible = false and run the
     ansible_command output from Linux or WSL after install.sh there.

2. Copy the terraform-kubernetes repository (same version as the kit) next
   to the kit, and run terraform init in the platform directory.

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
