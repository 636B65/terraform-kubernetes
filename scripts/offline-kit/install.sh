#!/usr/bin/env bash
# Installs the offline kit on the Linux machine that runs Terraform and
# Ansible, without internet access. Written into the kit by
# scripts/prepare-offline.sh; run it from there as root:
#
#   sudo ./install.sh [-n]
#     -n  Do not install the host packages (git, sshpass, xorriso, OpenSSH
#         client), e.g. when they are already installed.
#
# Supported: Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux and Fedora (the
# releases the kit was built for, see host-packages/), amd64 or arm64 for
# Terraform and Ansible. What it does:
#   - installs the host packages from the kit's local apt or dnf repository,
#   - installs Terraform to /usr/local/bin,
#   - creates a Python virtual environment with Ansible in the kit
#     (ansible/venv, on a portable CPython, so the system Python does not
#     matter) and links the ansible commands into /usr/local/bin,
#   - writes terraformrc for the providers mirror and sets TF_CLI_CONFIG_FILE
#     in /etc/profile.d/terraform-kubernetes-kit.sh.
set -euo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
packages=1
while getopts "nh" opt; do
  case "$opt" in
    n) packages=0 ;;
    h) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 1 ;;
  esac
done

[[ "$(id -u)" == 0 ]] || { echo "Error: run as root (sudo $0)." >&2; exit 1; }

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "Error: unsupported architecture $(uname -m)." >&2; exit 1 ;;
esac

# shellcheck disable=SC1091 # present on every supported distribution
. /etc/os-release
like=" ${ID:-} ${ID_LIKE:-} "
case "$like" in
  *" debian "* | *" ubuntu "*) family=deb ;;
  *" fedora "* | *" rhel "* | *" centos "*) family=rpm ;;
  *) family=unknown ;;
esac
# RHEL and its rebuilds share the "el<major>" packages; others are per release.
if [[ "$family" == rpm && "${ID:-}" != fedora ]]; then
  distro="el${VERSION_ID%%.*}"
else
  distro="${ID:-unknown}-${VERSION_ID:-}"
fi
echo "== $PRETTY_NAME ($arch)"

# --- Host packages -------------------------------------------------------------
host_tools() {
  local tool absent=()
  for tool in git ssh sshpass xorriso; do
    command -v "$tool" >/dev/null || absent+=("$tool")
  done
  echo "${absent[*]}"
}

repo="$kit/host-packages/$distro"
if [[ "$packages" == 0 ]]; then
  echo "== Skipping the host packages (-n)"
elif [[ "$arch" != amd64 || ! -d "$repo" ]]; then
  echo "Warning: the kit has no host packages for $distro ($arch); install git, sshpass," >&2
  echo "         xorriso and an OpenSSH client from your own repositories." >&2
elif [[ "$family" == deb ]]; then
  echo "== Host packages from $repo"
  list="$(mktemp)"
  trap 'rm -f "$list"' EXIT
  echo "deb [trusted=yes] file:$repo ./" > "$list"
  apt_opts=(-o "Dir::Etc::SourceList=$list" -o "Dir::Etc::SourceParts=-" -o "APT::Get::List-Cleanup=0")
  apt-get "${apt_opts[@]}" update -q
  DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" install -y -q --no-install-recommends \
    git sshpass xorriso openssh-client tar gzip
else
  echo "== Host packages from $repo"
  dnf install -y -q --disablerepo='*' --repofrompath="kit,file://$repo" --setopt=kit.gpgcheck=0 \
    git-core sshpass xorriso openssh-clients tar gzip
fi
missing="$(host_tools)"
[[ -z "$missing" ]] || echo "Warning: not installed: $missing" >&2

# --- Terraform -------------------------------------------------------------------
terraform_bin="$kit/terraform/linux_$arch/terraform"
if [[ -x "$terraform_bin" ]]; then
  install -m 0755 "$terraform_bin" /usr/local/bin/terraform
  echo "== $(/usr/local/bin/terraform version | head -n 1) in /usr/local/bin"
else
  echo "Warning: the kit has no Terraform for linux_$arch (prepare-offline.sh -a)." >&2
fi

cat > "$kit/terraformrc" <<RC
# Terraform CLI configuration for the offline kit (written by install.sh).
provider_installation {
  filesystem_mirror {
    path = "$kit/terraform-providers"
  }
  direct {
    exclude = ["*/*/*"]
  }
}
RC
echo "export TF_CLI_CONFIG_FILE=\"$kit/terraformrc\"" > /etc/profile.d/terraform-kubernetes-kit.sh

# --- Ansible ---------------------------------------------------------------------
python_archive=""
for candidate in "$kit"/ansible/cpython-*-"linux_$arch".tar.gz; do
  [[ -f "$candidate" ]] && python_archive="$candidate"
done
if [[ -n "$python_archive" ]]; then
  echo "== Ansible (portable $(basename "$python_archive" "-linux_$arch.tar.gz"))"
  rm -rf "$kit/ansible/python" "$kit/ansible/venv"
  mkdir -p "$kit/ansible/python"
  tar -xzf "$python_archive" -C "$kit/ansible/python" --strip-components 1
  "$kit/ansible/python/bin/python3" -m venv "$kit/ansible/venv"
  "$kit/ansible/venv/bin/python" -m pip install --quiet --no-index \
    --find-links "$kit/ansible/wheels-linux_$arch" ansible-core
  for tool in "$kit"/ansible/venv/bin/ansible*; do
    ln -sf "$tool" "/usr/local/bin/$(basename "$tool")"
  done
  echo "   $(/usr/local/bin/ansible --version | head -n 1)"
else
  echo "Warning: the kit has no Ansible for linux_$arch (prepare-offline.sh -a)." >&2
fi

cat <<TXT

Done. Open a new login shell, or run:
  export TF_CLI_CONFIG_FILE="$kit/terraformrc"
then continue with step 3 in $kit/README.txt.
TXT
