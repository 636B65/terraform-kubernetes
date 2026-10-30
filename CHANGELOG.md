# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-30

### Added
- Terraform templates that create 6 Ubuntu 26.04 VMs on Proxmox (`bpg/proxmox`),
  vCenter (`vmware/vsphere`), standalone ESXi (`josenk/esxi`) and
  VMware Workstation (`vmrun` scripts for Linux and Windows).
- Shared cloud-init module for static IP, user/password, SSH and
  CPU/memory/disk, globally or per VM.
- CI workflow that validates Terraform and creates a tag and GitHub release
  from `VERSION`.
