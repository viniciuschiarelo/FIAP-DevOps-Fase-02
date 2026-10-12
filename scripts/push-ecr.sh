#!/usr/bin/env bash
# Builda a imagem de cada microserviço e publica no repositório do ECR correspondente (<servico>-image).
# Uso: ./scripts/push-ecr.sh [servico...]   (ex.: ./scripts/push-ecr.sh auth flag)
# Variáveis: AWS_REGION (default us-east-1), ACCOUNT_ID (default: conta do aws configure), TAG (default latest)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
TAG="${TAG:-latest}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SERVICES=("${@:-auth flag targeting evaluation analytics}")

aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${REGISTRY}"

for svc in ${SERVICES[@]}; do
  image="${REGISTRY}/${svc}-image:${TAG}"
  echo ">> build ${image}"
  docker build -t "${image}" "${ROOT}/services/${svc}-service"
  echo ">> push ${image}"
  docker push "${image}"
done
