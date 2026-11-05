#!/usr/bin/env bash
# Runs inside a container of one distribution release (prepare-offline.sh -d):
# downloads the host packages the Terraform/Ansible machine needs (git,
# sshpass, xorriso, OpenSSH client, tar, gzip) with the dependencies a minimal install
# lacks, and turns them into a local apt or dnf repository in
# /out/<distribution>, which install.sh uses offline.
# Usage: host-packages.sh <uid:gid of the output owner>
set -euo pipefail

owner="${1:?owner}"
# shellcheck disable=SC1091
. /etc/os-release
like=" ${ID:-} ${ID_LIKE:-} "

case "$like" in
  *" debian "* | *" ubuntu "*)
    distro="$ID-$VERSION_ID"
    out="/out/$distro"
    rm -rf "$out"
    mkdir -p "$out/partial"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends --download-only \
      -o "Dir::Cache::archives=$out" git sshpass xorriso openssh-client tar gzip
    rm -rf "$out/partial" "$out/lock"
    apt-get install -y -q --no-install-recommends apt-utils
    (cd "$out" && apt-ftparchive packages . > Packages)
    ;;
  *" fedora "* | *" rhel "* | *" centos "*)
    if [[ "$ID" == fedora ]]; then
      distro="fedora-$VERSION_ID"
    else
      distro="el${VERSION_ID%%.*}"
      # sshpass comes from EPEL on RHEL and its rebuilds.
      dnf install -y -q epel-release dnf-plugins-core
    fi
    out="/out/$distro"
    rm -rf "$out"
    mkdir -p "$out"
    # The whole dependency closure: a minimal RHEL (or UBI) lacks packages the
    # container image has, and dnf installs only what is missing.
    dnf download -q --resolve --alldeps --destdir "$out" git-core sshpass xorriso openssh-clients tar gzip
    dnf install -y -q createrepo_c
    createrepo_c -q "$out"
    ;;
  *)
    echo "Error: unsupported distribution $PRETTY_NAME." >&2
    exit 1
    ;;
esac

chown -R "$owner" "$out"
echo "   $distro: $(find "$out" -name '*.deb' -o -name '*.rpm' | wc -l) packages"
