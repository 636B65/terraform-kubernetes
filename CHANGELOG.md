# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.8.0] - 2026-11-05

### Added
- Nightly end-to-end test on libvirt: a real cluster (one controller, one
  worker) is deployed on a KVM-enabled GitHub runner with `run_ansible`, and
  both nodes must become Ready.
- CI validates every platform and runs the module tests with OpenTofu as well
  as Terraform.
- `UPGRADING.md`: what each version changes for existing deployments, based
  on the rendered cloud-init of every release (VirtualBox and Workstation VMs
  are replaced when upgrading across 0.2.0, 0.3.3 and 0.6.0).
- `scripts/prepare-offline.sh` builds the Kubernetes bundle
  (`kubernetes-offline.tar`) without a cluster, with the role's
  `offline_build` in an Ubuntu 26.04 container (docker or podman); `-e` passes
  the add-on switches for the build, `-K` skips it. One command now collects
  everything for an offline deployment. The Ubuntu image is chosen from the
  platforms (`-i auto`: `.img` for Proxmox/libvirt, OVA otherwise).
- Workstation: `ubuntu_ova` (with `ubuntu_image_sha256` and
  `template_network`) creates `template_vmx` with ovftool when it does not
  exist yet.
- libvirt README: the AppArmor `Permission denied` fix
  (`security_driver = "none"`), found by the E2E test.
- `velero` variable for the Velero backup add-on of ansible-role-kubernetes
  (v3.3.0+): backups of all namespaces and volume data to S3/MinIO. Off by
  default.

### Changed
- The common variables, `common.tf` and `ansible.tf` (now with the Ansible
  outputs) are generated from `shared/` by `scripts/sync-common.sh`, instead of
  being kept in sync by hand; `--check` runs in pre-commit and CI. Resources
  and the rendered cloud-init are unchanged.
- Default `ansible_role_version` is `v3.3.0` (Velero add-on, Renovate).

## [0.7.0] - 2026-11-04

### Added
- The admin kubeconfig is fetched after `run_ansible` (`kubeconfig` output).
- Cluster operations with ansible-role-kubernetes:
  - `remove_nodes` drains and removes nodes from the cluster before their VMs
    are deleted; adding a VM to `vms` joins a new node.
  - `kubernetes_upgrade` runs the rolling upgrade when the role version or
    `ansible_extra_vars` change.
  - `etcd_backup_command` output fetches the newest etcd backups.
- Networking: per-VM `ipv6` (with `ipv6_prefix_length`, `ipv6_gateway`) and
  `secondary_ip` for a second NIC on every platform, with fixed MAC addresses
  so the guest can tell the NICs apart. Proxmox gets `secondary_vlan_id`.
- Ubuntu image verification: Proxmox verifies the download against
  `SHA256SUMS` (or `ubuntu_image_sha256`), VirtualBox verifies the OVA, and
  libvirt and ESXi check a local file against `ubuntu_image_sha256`.
- `scripts/prepare-offline.sh` collects the providers, Ansible, the role and
  the verified Ubuntu images for an offline install.
- `terraform test` for `modules/cloud-init` and `modules/ansible`, tflint,
  Trivy, shellcheck and a check that the common variables match, run by CI
  and by the new pre-commit configuration.
- Committed provider lock files, a workflow that regenerates them, and
  Dependabot updates for the Terraform providers.

### Changed
- Default `ansible_role_version` is `v3.2.0`, which adds optional Traefik,
  cert-manager and Argo CD (enable them with `ansible_extra_vars`).
- Proxmox needs the `hashicorp/http` provider (for `SHA256SUMS`). With
  verification on, the image download gets a checksum, which replaces the
  downloaded image once on existing deployments (the VMs are not affected).

## [0.6.1] - 2026-11-04

### Changed
- Default `ansible_role_version` is `v3.1.1`, which fixes registry pushes and
  verification failing (HTTP 500 or stale 404) on the shared registry volume.

## [0.6.0] - 2026-11-02

### Added
- Offline (air-gapped) deployment on all platforms, using the offline mode of
  ansible-role-kubernetes:
  - `stage_offline_bundle` stages a bundle on an online cluster
    (`--tags offline_stage`) and fetches it from the first controller to
    `offline_bundle` with the new `ansible/fetch-offline-bundle.yml`.
  - `offline = true` installs from that bundle: cloud-init skips package
    installs and disables the Ubuntu archive sources, `ansible/site.yml`
    unpacks the bundle to `/opt/kubernetes-offline` on every node, and the
    role runs with `kubernetes_offline_mode`.
- `apt_mirror` and `apt_security_mirror` point the VMs at an internal Ubuntu
  mirror, and `ntp_servers` sets the time servers.
- Proxmox: `ubuntu_image_file_id` uses a cloud image already on the node
  instead of downloading `ubuntu_image_url`.
- README guide for offline deployment: provider mirror, local role copy,
  images, staging and installing.
- CI also syntax-checks `ansible/fetch-offline-bundle.yml`.

## [0.5.0] - 2026-11-02

### Added
- `virtualbox/`: the 6 Ubuntu 26.04 VMs on VirtualBox (Windows, macOS and
  Linux hosts). Terraform runs `VBoxManage` through `scripts/vm.sh` or
  `scripts/vm.ps1`: it imports the Ubuntu cloud image OVA (downloaded once),
  sets CPU, memory and disk size, attaches a cloud-init NoCloud seed ISO with
  the user, password, SSH and static IP, and starts the VMs. Bridged, NAT
  network and host-only networking are supported. Inventory generation and
  `run_ansible` work as on the other platforms.

## [0.4.0] - 2026-11-01

### Added
- `libvirt/`: the 6 Ubuntu 26.04 VMs on KVM/QEMU with the `dmacvicar/libvirt`
  provider (0.9.x). The cloud image is downloaded into a storage pool once and
  each VM gets a copy-on-write disk and a cloud-init NoCloud ISO with the
  user, password, SSH and static IP. VMs attach to a libvirt network or a host
  bridge. Inventory generation and `run_ansible` work as on the other platforms.

## [0.3.3] - 2026-10-31

### Changed
- Default `ansible_role_version` is `v3.1.0`, which can turn off Longhorn and
  the internal registry on small hosts and fixes the bootstrap order.

### Fixed
- Proxmox VMs reboot once on first boot when cloud-init lost the interface
  rename race and the static address is missing.
- `.gitignore` covers saved plan files (`tfplan*`), which contain secrets.

## [0.3.2] - 2026-10-30

### Changed
- README shows badges for the Release and Track ansible-role-kubernetes
  workflows, the latest release and the latest ansible-role-kubernetes release.

## [0.3.1] - 2026-10-30

### Changed
- CI uses `actions/checkout` v7, `actions/setup-python` v7 and
  `hashicorp/setup-terraform` v4, which run on Node.js 24 instead of the
  deprecated Node.js 20.
- Dependabot keeps the GitHub Actions versions up to date.

## [0.3.0] - 2026-10-30

### Added
- `ansible_host` per VM in `vms`: Ansible connects to that address and the VM's
  `ip` is passed to the role as `kubernetes_node_ip`.
- Validation that VM names are valid hostnames/Kubernetes node names and that
  every VM has a unique IP address.
- `track-ansible-role` workflow that checks daily for new
  ansible-role-kubernetes releases and opens a pull request that updates
  `ansible_role_version`.

### Changed
- Default `ansible_role_version` is `v3.0.0`, which takes node names and
  addresses from the inventory. With `run_ansible = true`, the next apply runs
  the new role version; read its
  [upgrade notes](https://github.com/636B65/ansible-role-kubernetes/releases/tag/v3.0.0)
  first for existing clusters.

## [0.2.0] - 2026-10-30

### Added
- Integration with [ansible-role-kubernetes](https://github.com/636B65/ansible-role-kubernetes):
  every platform generates `.ansible/inventory.yml` with the `k8s_control_plane`
  and `k8s_workers` groups and the role variables.
- `run_ansible` option that installs the role (pinned with `ansible_role_version`,
  default `v2.0.0`) and runs `ansible/site.yml` after the VMs are created.
- New variables: `ansible_ssh_private_key_file`, `ansible_role_source`,
  `ansible_role_version`, `kubernetes_api_vip`, `kubernetes_keepalived_auth_pass`,
  `ansible_extra_vars` and `ansible_playbook_args`.
- `role` (`control_plane` or `worker`) per VM in `vms`.

### Changed
- Default VMs are now `kube-cp01..03` (control plane) and `kube-wl01..03`
  (workers). Existing deployments with the old default names are replaced;
  set `vms` explicitly to keep them.
- Default `disk_gb` is 60 and `extra_packages` defaults to `open-iscsi` and
  `nfs-common`, as required by Longhorn in ansible-role-kubernetes.
- The templates now also need the `hashicorp/local` provider.

## [0.1.0] - 2026-10-30

### Added
- Terraform templates that create 6 Ubuntu 26.04 VMs on Proxmox (`bpg/proxmox`),
  vCenter (`vmware/vsphere`), standalone ESXi (`josenk/esxi`) and
  VMware Workstation (`vmrun` scripts for Linux and Windows).
- Shared cloud-init module for static IP, user/password, SSH and
  CPU/memory/disk, globally or per VM.
- CI workflow that validates Terraform and creates a tag and GitHub release
  from `VERSION`.
