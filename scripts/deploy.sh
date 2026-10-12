#!/usr/bin/env bash
# Aplica os manifests do diretório k8s/ na ordem certa e espera os Deployments ficarem prontos.
# Pré-requisitos: KEDA, metrics-server, ingress-nginx e as ServiceAccounts IRSA (ver README).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for f in "${ROOT}"/k8s/0*.yaml; do
  kubectl apply -f "${f}"
done

for ns in auth flag targeting evaluation analytics; do
  kubectl rollout status "deployment/${ns}" -n "${ns}" --timeout=180s
done

kubectl get pods -A | grep -E 'auth|flag|targeting|evaluation|analytics'
kubectl get ingress -A
