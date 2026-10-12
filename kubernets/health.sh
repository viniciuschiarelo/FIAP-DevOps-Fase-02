for f in kubernets/0[4-8]*.yaml; do kubectl apply -f $f; done
kubectl get pods -A | grep -E 'auth|flag|targeting|evaluation|analytics'   # todos 1/1 Running
kubectl describe pod -n evaluation -l app=evaluation | grep -E 'Liveness|Readiness'
