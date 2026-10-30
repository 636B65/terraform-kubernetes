# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
