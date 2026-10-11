#!/usr/bin/env bash
# Builda as imagens dos microserviços e importa no nó do cluster do Docker Desktop (modo kind).
# O cluster NÃO enxerga as imagens do "docker images" do host, por isso o import manual.
# Uso: ./kubernets/load-images.sh [servico...]   (ex.: ./kubernets/load-images.sh auth flag)
# Variáveis: NODE (default desktop-control-plane), CTX (contexto docker, default desktop-linux)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${NODE:-desktop-control-plane}"
# O nó do Kubernetes roda dentro do engine do Docker Desktop, não no Docker Engine nativo.
CTX="${CTX:-desktop-linux}"
SERVICES=("${@:-auth flag targeting evaluation analytics}")

if ! docker --context "${CTX}" inspect "${NODE}" >/dev/null 2>&1; then
  echo "ERRO: container '${NODE}' não encontrado no contexto docker '${CTX}'." >&2
  echo "Abra o Docker Desktop e habilite Kubernetes (Settings > Kubernetes, provisioning 'kind')." >&2
  echo "Contextos/nós disponíveis: docker context ls ; docker --context ${CTX} ps" >&2
  exit 1
fi

for svc in ${SERVICES[@]}; do
  image="fiap-techchallenge-fase02-${svc}-service:latest"
  echo ">> build ${image}"
  docker --context "${CTX}" build -t "${image}" "${ROOT}/${svc}-service"
  echo ">> import ${image} -> ${NODE}"
  docker --context "${CTX}" save "${image}" | docker --context "${CTX}" exec -i "${NODE}" ctr -n k8s.io images import -
done
