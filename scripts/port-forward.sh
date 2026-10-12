#!/usr/bin/env bash
# Abre port-forward de todos os serviços do cluster em paralelo.
# Usa as portas 1800X no host porque 800X já estão ocupadas pelo docker-compose.
# Ctrl+C encerra todos.
set -euo pipefail

trap 'kill $(jobs -p) 2>/dev/null' EXIT

for svc in auth:8001 flag:8002 targeting:8003 evaluation:8004 analytics:8005; do
  name="${svc%%:*}"
  port="${svc##*:}"
  kubectl port-forward "svc/${name}" -n "${name}" "1${port}:${port}" &
done

wait
