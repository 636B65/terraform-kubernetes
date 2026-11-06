#!/usr/bin/env bash
# The parts of the E2E workflow that differ per scenario.
#
#   scenario.sh tfvars <scenario>   write libvirt/terraform.tfvars
#   scenario.sh prepare <scenario>  host side, after tfvars: MinIO (addons),
#                                   the offline kit (offline)
#   scenario.sh check <scenario>    check the cluster ("nodes": only the nodes
#                                   and Cilium)
#   scenario.sh no-replaced-vms     fail if the saved plan (libvirt/upgrade.plan)
#                                   replaces or deletes a VM
#
# Scenarios: basic (the cluster), addons (Argo CD, Traefik, cert-manager and
# Velero with a backup to MinIO on the host), offline (VMs without a route
# out, installed from a kit built with scripts/prepare-offline.sh), upgrade
# (the previous release, then this commit applied on top).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
kit="$HOME/e2e-kit"
minio_user=e2e-velero
minio_password_file="$HOME/.e2e-minio-password"

tfvars() {
  local scenario="$1"
  [[ -f ~/.ssh/e2e ]] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/e2e
  [[ -s "$minio_password_file" ]] || openssl rand -hex 16 > "$minio_password_file"
  E2E_IMAGE="$HOME/e2e-image/$IMAGE_NAME"
  E2E_SSH_KEY="$HOME/.ssh/e2e"
  E2E_SSH_PUBLIC_KEY="$(cat ~/.ssh/e2e.pub)"
  E2E_PASSWORD="$(openssl rand -hex 12)"
  E2E_WORKER_MEMORY=4096
  E2E_EXTRA_VARS=""
  case "$scenario" in
    addons)
      E2E_WORKER_MEMORY=7168
      E2E_EXTRA_VARS="  kubernetes_ingress_enabled      = true
  kubernetes_cert_manager_enabled = true"
      ;;
  esac
  export E2E_IMAGE E2E_IMAGE_SHA256 E2E_SSH_KEY E2E_SSH_PUBLIC_KEY E2E_PASSWORD E2E_WORKER_MEMORY E2E_EXTRA_VARS
  envsubst < "$repo_root/tests/e2e/libvirt.tfvars.tftpl" > "$repo_root/libvirt/terraform.tfvars"

  case "$scenario" in
    addons)
      cat >> "$repo_root/libvirt/terraform.tfvars" <<HCL

# Velero backs up to MinIO on the runner (the network's gateway).
velero = {
  enabled        = true
  bucket         = "velero"
  s3_url         = "http://192.168.123.1:9000"
  region         = "minio"
  access_key     = "$minio_user"
  secret_key     = "$(cat "$minio_password_file")"
  volume_backups = false
}
HCL
      ;;
    offline)
      cat >> "$repo_root/libvirt/terraform.tfvars" <<HCL

# The VMs have no route out; everything comes from the kit's bundle.
offline        = true
offline_bundle = "$kit/kubernetes-offline.tar"
HCL
      ;;
  esac
}

prepare() {
  case "$1" in
    addons)
      mkdir -p "$HOME/e2e-minio/velero"
      docker run -d --name e2e-minio -p 192.168.123.1:9000:9000 \
        -e MINIO_ROOT_USER="$minio_user" -e MINIO_ROOT_PASSWORD="$(cat "$minio_password_file")" \
        -v "$HOME/e2e-minio:/data" quay.io/minio/minio:latest server /data >/dev/null
      for _ in $(seq 1 30); do
        curl -fsS http://192.168.123.1:9000/minio/health/live >/dev/null && break
        sleep 2
      done
      ;;
    offline)
      # The kit's bundle is built from the scenario's terraform.tfvars, the
      # same way a user would build it.
      "$repo_root/scripts/prepare-offline.sh" -o "$kit" -p libvirt -i none -d none \
        -f "$repo_root/libvirt/terraform.tfvars"
      ;;
  esac
}

wait_deployments() { # wait_deployments <namespace>...
  local ns
  for ns in "$@"; do
    echo "== deployments in $ns"
    kubectl -n "$ns" wait --for=condition=Available deployment --all --timeout=10m
  done
}

check() {
  kubectl wait --for=condition=Ready nodes --all --timeout=10m
  kubectl get nodes -o wide
  test "$(kubectl get nodes --no-headers | wc -l)" -eq 2
  kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
  # "nodes" stops here (the upgrade scenario, before the upgrade).
  [[ "$1" != nodes ]] || return 0
  # Argo CD is installed by default.
  wait_deployments argocd
  case "$1" in
    addons)
      wait_deployments traefik cert-manager velero
      kubectl get clusterissuer selfsigned -o jsonpath='{.status.conditions[0].status}' | grep -qx True
      echo "== Velero backup to MinIO"
      for _ in $(seq 1 60); do
        phase="$(kubectl -n velero get backupstoragelocations default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "$phase" == Available ]] && break
        sleep 5
      done
      [[ "$phase" == Available ]] || { kubectl -n velero get backupstoragelocations -o yaml; exit 1; }
      kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: e2e
  namespace: velero
spec:
  includedNamespaces: [argocd]
  storageLocation: default
YAML
      for _ in $(seq 1 60); do
        phase="$(kubectl -n velero get backup e2e -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "$phase" == Completed || "$phase" == Failed || "$phase" == PartiallyFailed ]] && break
        sleep 5
      done
      echo "backup: $phase"
      [[ "$phase" == Completed ]]
      sudo find "$HOME/e2e-minio/velero" -maxdepth 3 | head -n 20
      ;;
    offline)
      echo "== the VMs have no route out"
      ! ssh -i ~/.ssh/e2e -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@192.168.123.11 \
        'curl -sS --max-time 10 -o /dev/null https://registry.k8s.io'
      ;;
  esac
  kubectl get pods --all-namespaces -o wide
}

no_replaced_vms() {
  cd "$repo_root/libvirt"
  terraform show -json upgrade.plan | python3 -c '
import json, sys
plan = json.load(sys.stdin)
changes = [(c["address"], c["change"]["actions"]) for c in plan.get("resource_changes", [])
           if c["change"]["actions"] != ["no-op"]]
for address, actions in changes:
    print(f"  {address}: {actions}")
lost = [a for a, actions in changes if a.startswith("libvirt_domain.") and "delete" in actions]
if lost:
    sys.exit(f"The upgrade replaces or deletes VMs: {lost}. UPGRADING.md must say so, and this check must allow it.")
'
}

case "${1:-}" in
  tfvars) tfvars "${2:?scenario}" ;;
  prepare) prepare "${2:?scenario}" ;;
  check) check "${2:?scenario}" ;;
  no-replaced-vms) no_replaced_vms ;;
  *) echo "Usage: $0 tfvars|prepare|check <scenario> | no-replaced-vms" >&2; exit 1 ;;
esac
