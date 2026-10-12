# ToggleMaster no Kubernetes — tutorial prático

Passo a passo para subir os 5 microserviços do ToggleMaster no Kubernetes local do **Docker Desktop**, expostos por um **Ingress** em `http://togglemaster.local`.

Siga na ordem. Todos os comandos são executados a partir da **raiz do repositório** (`FIAP-TechChallenge-Fase02/`).

---

## Sumário

1. [Como a aplicação fica montada](#1-como-a-aplicação-fica-montada)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Passo 1 — Ligar o Kubernetes do Docker Desktop](#passo-1--ligar-o-kubernetes-do-docker-desktop)
4. [Passo 2 — Subir os bancos e a fila (Docker Compose)](#passo-2--subir-os-bancos-e-a-fila-docker-compose)
5. [Passo 3 — Buildar as imagens e carregar no cluster](#passo-3--buildar-as-imagens-e-carregar-no-cluster)
6. [Passo 4 — Aplicar os manifests](#passo-4--aplicar-os-manifests)
7. [Passo 5 — Instalar o Ingress Controller](#passo-5--instalar-o-ingress-controller)
8. [Passo 6 — Configurar o domínio local e aplicar o Ingress](#passo-6--configurar-o-domínio-local-e-aplicar-o-ingress)
9. [Passo 7 — Testar o fluxo completo](#passo-7--testar-o-fluxo-completo)
10. [Passo 8 — Testar a escalabilidade (KEDA)](#passo-8--testar-a-escalabilidade-keda)
11. [Dia a dia: atualizar, ver logs, escalar](#dia-a-dia-atualizar-ver-logs-escalar)
12. [Problemas comuns](#problemas-comuns)
13. [Derrubar tudo](#derrubar-tudo)
14. [Glossário rápido](#glossário-rápido)

---

## 1. Como a aplicação fica montada

```
                      sua máquina
  curl / navegador ──► http://togglemaster.local  (/etc/hosts → 127.0.0.1)
                                │
 ┌──────────────────────────────┼──────── cluster Kubernetes (Docker Desktop) ───┐
 │                              ▼                                                │
 │                 Ingress Controller (ingress-nginx)                            │
 │                              │  roteia pelo caminho (path)                    │
 │     /validate,/admin   /flags          /rules            /evaluate            │
 │            ▼             ▼               ▼                  ▼                 │
 │   ns auth          ns flag         ns targeting       ns evaluation   ns analytics
 │   Service auth     Service flag    Service targeting  Service evaluation  (sem Ingress,
 │   :8001            :8002           :8003              :8004               só consome
 │   2–8 pods         2–5 pods        2–5 pods           2–10 pods           a fila, 1–5 pods)
 └──────────┬───────────────┬───────────────┬──────────────────┬───────────────┬──┘
            │               │               │                  │               │
            ▼   host.docker.internal (pods acessando portas da sua máquina)   ▼
 ┌──────────────────────────── Docker Compose (fora do cluster) ─────────────────┐
 │  auth_db :5438   flags_db :5437   targeting_db :5436   evaluation_db (Redis) :6379
 │  sqs-local (ElasticMQ) :9324      dynamodb-local :8000   dynamodb-admin :9002 │
 └───────────────────────────────────────────────────────────────────────────────┘
```

- **Os microserviços** rodam no Kubernetes: cada um tem seu **namespace**, um **Deployment**, um **Service** ClusterIP e um **ScaledObject** do KEDA, que controla quantas réplicas rodam.
- **Os bancos e a fila** continuam no Docker Compose. Os pods chegam neles por `host.docker.internal`, que aponta para a sua máquina.
- **O Ingress** é a única porta de entrada HTTP. Ele recebe tudo em `togglemaster.local` e manda para o Service certo de acordo com o caminho da URL.

### Arquivos desta pasta

| Arquivo | O que cria |
|---|---|
| `01-namespaces.yaml` | Os 5 namespaces: `auth`, `flag`, `targeting`, `evaluation`, `analytics` |
| `02-configMap.yaml` | Configurações não sensíveis (porta, URLs entre serviços, região AWS) |
| `03-secrets.yaml` | Dados sensíveis (connection strings, chaves de API, credenciais AWS) |
| `04-authService.yaml` … `08-analytics-service.yaml` | Deployment + Service + ScaledObject (KEDA) de cada microserviço |
| `09-ingress.yaml` | As regras de roteamento HTTP (um Ingress por namespace) |
| `load-images.sh` | Builda as imagens e importa no nó do cluster |
| `port-forward.sh` | Alternativa ao Ingress: expõe cada Service em `localhost:1800X` |
| `pod.yaml`, `deployment.yaml`, `cluster.yaml` | Exemplos de estudo com nginx (**não fazem parte da aplicação**) |

---

## 2. Pré-requisitos

- **Docker Desktop** com o Kubernetes habilitado (Passo 1)
- **kubectl** instalado (`kubectl version --client`)
- **curl** para os testes
- Permissão de `sudo` para editar o `/etc/hosts`

---

## Passo 1 — Ligar o Kubernetes do Docker Desktop

1. Abra o Docker Desktop → **Settings** → **Kubernetes**.
2. Marque **Enable Kubernetes** e clique em **Apply & restart**. Os scripts deste projeto assumem o modo **kind**, em que o nó se chama `desktop-control-plane`.
3. Espere o ícone do Kubernetes ficar verde.

Confira no terminal:

```bash
kubectl config use-context docker-desktop
kubectl get nodes
```

O esperado é algo assim:

```
NAME                    STATUS   ROLES           AGE   VERSION
desktop-control-plane   Ready    control-plane   1m    v1.36.1
```

> Se o nó tiver outro nome, anote. Você vai precisar dele no Passo 3.

---

## Passo 2 — Subir os bancos e a fila (Docker Compose)

Suba **só a infraestrutura**. Os microserviços vão rodar no Kubernetes.

```bash
docker compose up -d auth_db flags_db targeting_db evaluation_db \
  sqs-local dynamodb-local dynamodb-init dynamodb-admin
```

Confira:

```bash
docker compose ps
```

Os bancos devem aparecer como `Up (healthy)`. O `dynamodb-init` roda uma vez, cria a tabela `ToggleMasterAnalytics` e termina. É normal ele aparecer como `Exited (0)`.

> **Por que não subir o compose inteiro?** O `docker-compose.yaml` também tem os microserviços. Se eles ficarem rodando, você terá duas cópias da aplicação ao mesmo tempo. Pior: o `analytics_service` do compose passa a disputar as mensagens da fila com os pods do analytics. Se já estiverem rodando, pare com:
> ```bash
> docker compose stop auth_service flags_service targeting_service evaluation_service analytics_service
> ```

---

## Passo 3 — Buildar as imagens e carregar no cluster

O cluster **não enxerga** as imagens do seu `docker images`. Ele tem um registro de imagens próprio dentro do nó. Por isso os Deployments usam `imagePullPolicy: Never`, e as imagens precisam ser importadas no nó manualmente. O script faz isso:

```bash
chmod +x kubernets/load-images.sh
./kubernets/load-images.sh
```

Para cada serviço, o script roda `docker build` e importa a imagem no nó com `ctr images import`. Na primeira vez demora alguns minutos.

Se o nó tiver outro nome (veja o Passo 1):

```bash
NODE=nome-do-seu-no ./kubernets/load-images.sh
```

Para conferir que as imagens chegaram no nó:

```bash
docker exec desktop-control-plane crictl images | grep fiap-techchallenge
```

---

## Passo 4 — Aplicar os manifests

### 4.0 Instalar o KEDA e o metrics-server (uma vez por cluster)

Os manifests dos serviços têm um `ScaledObject`, que é um recurso do **KEDA**. Sem o KEDA instalado, o `kubectl apply` falha com `no matches for kind "ScaledObject"`.

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda -n keda --create-namespace
kubectl get pods -n keda      # 3 pods Running
```

Os serviços HTTP escalam por CPU, e quem mede CPU é o **metrics-server**. O Docker Desktop não vem com ele. No cluster local, o kubelet usa um certificado autoassinado, por isso precisa da flag `--kubelet-insecure-tls`:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl top nodes             # depois de ~1 min deve mostrar CPU/memória
```

### 4.1 Aplicar

A ordem importa: o namespace precisa existir antes do que mora nele, e o ConfigMap e o Secret precisam existir antes dos pods que os leem.

```bash
kubectl apply -f kubernets/01-namespaces.yaml
kubectl apply -f kubernets/02-configMap.yaml
kubectl apply -f kubernets/03-secrets.yaml
kubectl apply -f kubernets/04-authService.yaml
kubectl apply -f kubernets/05-flag-service.yaml
kubectl apply -f kubernets/06-targeting-service.yaml
kubectl apply -f kubernets/07-evaluation-service.yaml
kubectl apply -f kubernets/08-analytics-service.yaml
```

> Não use `kubectl apply -f kubernets/`. Isso aplicaria também os arquivos de estudo (`pod.yaml`, `deployment.yaml`, `cluster.yaml`) e criaria pods de nginx no namespace `default`.

Espere todos os pods ficarem prontos:

```bash
for ns in auth flag targeting evaluation analytics; do
  kubectl rollout status deployment/$ns -n $ns
done
```

```bash
kubectl get pods -A | grep -E 'auth|flag|targeting|evaluation|analytics'
```

O esperado são 9 pods no mínimo (2 de auth, flag, targeting e evaluation, mais 1 de analytics), todos `1/1 Running`. O KEDA sobe mais réplicas conforme a carga.

---

## Passo 5 — Instalar o Ingress Controller

O objeto **Ingress** é só uma regra escrita. Quem lê essas regras e roteia o tráfego de verdade é o **Ingress Controller**. Usamos o ingress-nginx, e ele só precisa ser instalado **uma vez por cluster**.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
```

Espere o controller ficar pronto:

```bash
kubectl wait -n ingress-nginx --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s
```

Confira:

```bash
kubectl get ingressclass
```

```
NAME    CONTROLLER             PARAMETERS   AGE
nginx   k8s.io/ingress-nginx   <none>       1m
```

O nome `nginx` é o que os nossos Ingresses usam em `ingressClassName: nginx`.

---

## Passo 6 — Configurar o domínio local e aplicar o Ingress

### 6.1 Apontar `togglemaster.local` para a sua máquina

O Ingress roteia pelo cabeçalho `Host` da requisição. O domínio `togglemaster.local` não existe na internet, então você ensina o seu computador a resolvê-lo para `127.0.0.1`:

```bash
grep -q togglemaster.local /etc/hosts || echo "127.0.0.1 togglemaster.local" | sudo tee -a /etc/hosts
```

### 6.2 Aplicar as regras

```bash
kubectl apply -f kubernets/09-ingress.yaml
kubectl get ingress -A
```

```
NAMESPACE    NAME         CLASS   HOSTS                ADDRESS      PORTS   AGE
auth         auth         nginx   togglemaster.local   172.18.0.5   80      30s
evaluation   evaluation   nginx   togglemaster.local   172.18.0.5   80      30s
flag         flag         nginx   togglemaster.local   172.18.0.5   80      30s
targeting    targeting    nginx   togglemaster.local   172.18.0.5   80      30s
```

A coluna `ADDRESS` leva alguns segundos para ser preenchida. Esse IP é interno do Docker, então **não use ele**. Acesse sempre por `togglemaster.local`.

### Rotas expostas

| Caminho | Vai para | Observação |
|---|---|---|
| `/validate` | auth :8001 | Valida uma chave de API |
| `/admin/...` | auth :8001 | Cria chaves (exige a MASTER_KEY) |
| `/flags/...` | flag :8002 | CRUD de flags (exige chave de API) |
| `/rules/...` | targeting :8003 | CRUD de regras (exige chave de API) |
| `/evaluate` | evaluation :8004 | Avalia uma flag para um usuário (público) |
| qualquer outro | — | 404 do próprio nginx |

> **Por que um Ingress por namespace?** Um Ingress só pode apontar para Services do **mesmo namespace** que ele. Como cada serviço tem seu namespace, criamos um Ingress em cada um, todos com o mesmo host. O controller junta todas as regras numa configuração só.

Teste rápido:

```bash
curl -i http://togglemaster.local/flags
```

Um `401 Authorization header obrigatório` significa que **está funcionando**. A requisição atravessou o Ingress e chegou no flag-service, que recusou porque faltou a chave.

---

## Passo 7 — Testar o fluxo completo

Este é o caminho real da aplicação: criar uma chave, criar uma flag, criar uma regra de segmentação e avaliar a flag para usuários diferentes.

### 7.1 Criar uma chave de API (no auth, usando a MASTER_KEY)

```bash
curl -s -X POST http://togglemaster.local/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer admin-secreto-123" \
  -d '{"name": "minha-chave"}'
```

Resposta (a sua chave será diferente):

```json
{"name":"minha-chave","key":"tm_key_c993db4d...","message":"Guarde esta chave com segurança! Você não poderá vê-la novamente."}
```

Guarde a chave numa variável para usar nos próximos comandos:

```bash
export KEY=tm_key_e353769235511cb6c2bdbecf22ec8fa408eea2d0b91d2ca5173631a2dcd2ed84
```

> Atalho que cria a chave e já guarda na variável:
> ```bash
> export KEY=$(curl -s -X POST http://togglemaster.local/admin/keys \
>   -H "Content-Type: application/json" -H "Authorization: Bearer admin-secreto-123" \
>   -d '{"name":"minha-chave"}' | sed -E 's/.*"key":"([^"]+)".*/\1/')
> echo $KEY
> ```

### 7.2 Validar a chave

```bash
curl -s http://togglemaster.local/validate -H "Authorization: Bearer $KEY"
```

```json
{"message":"Chave válida"}
```

### 7.3 Criar uma flag (flag-service)

```bash
curl -s -X POST http://togglemaster.local/flags \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"name": "enable-new-dashboard", "description": "Novo dashboard", "is_enabled": true}'
```

Listar e consultar:

```bash
curl -s http://togglemaster.local/flags -H "Authorization: Bearer $KEY"
curl -s http://togglemaster.local/flags/enable-new-dashboard -H "Authorization: Bearer $KEY"
```

### 7.4 Criar uma regra de segmentação (targeting-service)

A regra abaixo libera a flag para 50% dos usuários:

```bash
curl -s -X POST http://togglemaster.local/rules \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"flag_name": "enable-new-dashboard", "is_enabled": true, "rules": {"type": "PERCENTAGE", "value": 50}}'
```

```bash
curl -s http://togglemaster.local/rules/enable-new-dashboard -H "Authorization: Bearer $KEY"
```

### 7.5 Avaliar a flag (evaluation-service)

Esse endpoint é público e não precisa de chave. O evaluation usa uma chave de serviço própria, já cadastrada pelo `init.sql` do auth.

```bash
for u in user-1 user-2 user-3 user-4; do
  curl -s "http://togglemaster.local/evaluate?user_id=$u&flag_name=enable-new-dashboard"
  echo
done
```

```json
{"flag_name":"enable-new-dashboard","user_id":"user-1","result":false}
{"flag_name":"enable-new-dashboard","user_id":"user-2","result":true}
...
```

O mesmo `user_id` sempre recebe o mesmo resultado, porque a decisão vem de um hash do usuário.

### 7.6 Ver o cache funcionando

Rode a avaliação mais de uma vez e procure `Cache HIT` nos logs:

```bash
kubectl logs -n evaluation -l app=evaluation --prefix --tail=20 | grep -i cache
```

### 7.7 Mudar a regra e ver o efeito

```bash
curl -s -X PUT http://togglemaster.local/rules/enable-new-dashboard \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"rules": {"type": "PERCENTAGE", "value": 100}}'
```

Depois que o cache expirar, todos os usuários passam a receber `true`.

### ⚠️ Limitação atual: eventos para o SQS / analytics

Hoje o evaluation-service **não usa** a variável `SQS_ENDPOINT`. O cliente SQS em `evaluation-service/main.go` não configura endpoint, então o evento vai para a AWS real e não para o `sqs-local`. Com as credenciais fictícias (`local`), aparece este erro nos logs:

```
Erro ao enviar mensagem para SQS: InvalidClientTokenId: The security token included in the request is invalid.
```

**A avaliação continua funcionando**, porque o envio é assíncrono. O que acontece é que nenhum evento chega na fila, e por isso o analytics não grava nada no DynamoDB. O mesmo acontece rodando pelo Docker Compose. Para corrigir, é preciso passar `Endpoint: os.Getenv("SQS_ENDPOINT")` no `aws.Config` da sessão do SQS.

Para conferir o DynamoDB local: http://localhost:9002 (dynamodb-admin).

---

## Passo 8 — Testar a escalabilidade (KEDA)

Aqui você gera carga de propósito e observa o KEDA subir e descer réplicas. Faça o Passo 7 antes, porque os testes usam a flag `enable-new-dashboard` e a variável `$KEY`.

### Como o escalonamento decide

| Serviço | Gatilho | Mín–Máx |
|---|---|---|
| auth | CPU média > 70% do `requests.cpu` (100m → 70m por pod) | 2–8 |
| flag | CPU > 70% | 2–5 |
| targeting | CPU > 70% | 2–5 |
| evaluation | CPU > 70% | 2–10 |
| analytics | mensagens na fila `sua-fila` (1 pod a cada 5) | 1–5 |

Para os gatilhos de CPU, o KEDA cria um **HPA** (`keda-hpa-<nome>`), que calcula `réplicas = atual × (CPU atual / 70%)`, arredondando para cima. Ele **sobe rápido** (cerca de 15 a 30 s) e **desce devagar**: espera 5 minutos de CPU baixa antes de remover pods, para não ficar oscilando.

### 8.1 Conferir se está tudo pronto

```bash
kubectl top pods -A | grep -E 'auth|flag|targeting|evaluation|analytics'   # metrics-server respondendo
kubectl get scaledobject -A
kubectl get hpa -A
```

Todos os ScaledObjects precisam estar com `READY True`:

```
NAMESPACE    NAME         SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY   ACTIVE ...
auth         auth         apps/v1.Deployment   auth              2     8     True    True
evaluation   evaluation   apps/v1.Deployment   evaluation        2     10    True    True
...
```

E os HPAs precisam mostrar um número no lugar de `<unknown>`:

```
NAMESPACE    NAME                  REFERENCE               TARGETS       MINPODS   MAXPODS   REPLICAS
evaluation   keda-hpa-evaluation   Deployment/evaluation   cpu: 3%/70%   2         10        2
```

> `<unknown>/70%` nos primeiros 1 a 2 minutos é normal. Se não mudar, veja "Problemas comuns".

### 8.2 Escalar o evaluation por CPU

Abra **dois terminais extras** para acompanhar:

```bash
# terminal 2: o HPA (CPU e número de réplicas)
kubectl get hpa -n evaluation -w
```

```bash
# terminal 3: os pods nascendo
kubectl get pods -n evaluation -w
```

No terminal principal, gere carga **de dentro do cluster** com o [hey](https://github.com/rakyll/hey) por 3 minutos, com 50 conexões simultâneas:

```bash
kubectl run hey -n evaluation --rm -it --restart=Never --image=williamyeh/hey -- \
  -z 3m -c 50 \
  "http://evaluation.evaluation.svc.cluster.local:8004/evaluate?user_id=user-1&flag_name=enable-new-dashboard"
```

> A carga vai direto no Service, sem passar pelo Ingress, porque o objetivo é estressar o evaluation e não o nginx. Rodar `curl` em loop na sua máquina gera pouca carga, já que é uma requisição por vez.

O que você deve ver no terminal 2:

```
NAME                  REFERENCE               TARGETS         MINPODS   MAXPODS   REPLICAS
keda-hpa-evaluation   Deployment/evaluation   cpu: 2%/70%     2         10        2
keda-hpa-evaluation   Deployment/evaluation   cpu: 245%/70%   2         10        2
keda-hpa-evaluation   Deployment/evaluation   cpu: 245%/70%   2         10        7
keda-hpa-evaluation   Deployment/evaluation   cpu: 98%/70%    2         10        10
```

Os números exatos variam conforme a máquina. Ao final, o hey imprime um resumo com requisições por segundo e latência.

**Depois da carga:** a CPU cai para perto de 0%, mas as réplicas só voltam para 2 depois de cerca de 5 minutos. Acompanhe pelo terminal 2.

Para ver o motivo de cada decisão do HPA:

```bash
kubectl describe hpa keda-hpa-evaluation -n evaluation | tail -15
```

```
Events:
  Normal  SuccessfulRescale  ...  New size: 7; reason: cpu resource utilization (percentage of request) above target
  Normal  SuccessfulRescale  ...  New size: 2; reason: All metrics below target
```

> **Não escalou?** Aumente as conexões (`-c 100`). Confira também se a CPU passou de 70% com `kubectl top pods -n evaluation`. Se as réplicas novas ficarem em `Pending`, o nó ficou sem CPU livre: `kubectl describe pod <pod>` vai mostrar `Insufficient cpu`. Nesse caso, aumente a CPU do Docker Desktop (Settings → Resources).

### 8.3 Escalar o auth por CPU

O auth recebe a validação de chave de todos os outros serviços. O teste é o mesmo, só muda o alvo e entra o header com a chave:

```bash
kubectl get hpa -n auth -w      # em outro terminal
```

```bash
kubectl run hey -n auth --rm -it --restart=Never --image=williamyeh/hey -- \
  -z 3m -c 50 -H "Authorization: Bearer $KEY" \
  "http://auth.auth.svc.cluster.local:8001/validate"
```

O `$KEY` é expandido pelo seu shell antes de o comando ir para o cluster, por isso funciona. O flag e o targeting são testados do mesmo jeito: troque o namespace e a URL (`http://flag.flag.svc.cluster.local:8002/flags` ou `http://targeting.targeting.svc.cluster.local:8003/rules/enable-new-dashboard`).

### 8.4 Escalar o analytics pela fila SQS

O analytics não escala por CPU. O KEDA consulta o tamanho da fila `sua-fila` a cada 30 segundos e pede `mensagens ÷ 5` réplicas, limitado entre 1 e 5.

Como o evaluation ainda não publica no `sqs-local` (veja a limitação no Passo 7), as mensagens vão ser publicadas à mão. O analytics consome rápido demais para a fila acumular, então o teste segue esta ordem: **pausar → encher a fila → despausar**.

**1. Pausar o analytics.** A anotação abaixo faz o KEDA manter o Deployment em 0 réplicas, e assim ninguém consome a fila:

```bash
kubectl annotate scaledobject analytics -n analytics autoscaling.keda.sh/paused-replicas="0" --overwrite
kubectl get pods -n analytics      # aguarde até não sobrar nenhum pod
```

**2. Publicar 100 mensagens** no ElasticMQ, que está exposto em `localhost:9324` pelo compose. O corpo segue o formato que o analytics espera:

```bash
for i in $(seq 1 100); do
  curl -s -o /dev/null "http://localhost:9324/000000000000/sua-fila" \
    --data-urlencode "Action=SendMessage" \
    --data-urlencode "MessageBody={\"user_id\":\"user-$i\",\"flag_name\":\"enable-new-dashboard\",\"result\":true,\"timestamp\":\"$(date -u +%FT%TZ)\"}"
done
```

Confira o tamanho da fila:

```bash
curl -s "http://localhost:9324/000000000000/sua-fila?Action=GetQueueAttributes&AttributeName.1=ApproximateNumberOfMessages" \
  | grep -A1 ApproximateNumberOfMessages
```

```
<Name>ApproximateNumberOfMessages</Name>
<Value>100</Value>
```

**3. Despausar e observar:**

```bash
kubectl get pods -n analytics -w     # em outro terminal
```

```bash
kubectl annotate scaledobject analytics -n analytics autoscaling.keda.sh/paused-replicas-
```

Com 100 mensagens, a conta dá 100 ÷ 5 = 20 réplicas, mas o máximo é 5, então sobem **5 pods**. Eles esvaziam a fila em poucos segundos, e o KEDA volta para **1 réplica** depois da janela de 5 minutos. Para conferir o processamento:

```bash
kubectl logs -n analytics -l app=analytics --prefix --tail=200 | grep -c "salvo no DynamoDB"
```

Os 100 eventos também aparecem na tabela `ToggleMasterAnalytics` em http://localhost:9002 (dynamodb-admin).

> Se a fila não esvaziar, confira se o `analytics_service` do Docker Compose está parado (Passo 2). Ele disputa as mensagens com os pods.

### 8.5 Resetar depois dos testes

```bash
kubectl delete pod hey -n evaluation --ignore-not-found     # caso o hey tenha ficado para trás
kubectl delete pod hey -n auth --ignore-not-found
kubectl annotate scaledobject analytics -n analytics autoscaling.keda.sh/paused-replicas- 2>/dev/null
kubectl get hpa -A                                           # em ~5 min tudo volta ao mínimo
```

---

## Dia a dia: atualizar, ver logs, escalar

### Alterei o código de um serviço. Como subo a nova versão?

```bash
./kubernets/load-images.sh auth                    # rebuilda e reimporta só o auth
kubectl rollout restart deployment/auth -n auth    # recria os pods com a imagem nova
kubectl rollout status deployment/auth -n auth
```

Troque `auth` por `flag`, `targeting`, `evaluation` ou `analytics`. A imagem usa sempre a tag `latest`, por isso o `rollout restart` é necessário: sem ele, o Kubernetes não percebe que a imagem mudou.

### Alterei um ConfigMap ou Secret

Os pods só leem as variáveis de ambiente quando nascem. Aplique e reinicie:

```bash
kubectl apply -f kubernets/02-configMap.yaml   # ou 03-secrets.yaml
kubectl rollout restart deployment/flag -n flag
```

### Ver logs

```bash
kubectl logs -n auth -l app=auth --prefix --tail=50     # todos os pods do auth
kubectl logs -n auth -l app=auth --prefix -f            # acompanhar em tempo real
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=50   # acessos no Ingress
```

### Inspecionar

```bash
kubectl get all -n flag                      # deployment, replicaset, pods e service
kubectl describe pod -n flag <nome-do-pod>   # eventos: por que não subiu?
kubectl describe ingress -n flag flag        # para qual Service/porta o Ingress aponta
kubectl get endpoints -n flag flag           # IPs dos pods atrás do Service
kubectl exec -it -n flag <nome-do-pod> -- sh # entrar no container
```

### Escalar (KEDA)

A quantidade de réplicas é automática. Cada serviço tem um `ScaledObject`, e o KEDA cria um HPA a partir dele:

| Serviço | Gatilho | Mín–Máx |
|---|---|---|
| auth | CPU > 70% do `requests.cpu` | 2–8 |
| flag | CPU > 70% | 2–5 |
| targeting | CPU > 70% | 2–5 |
| evaluation | CPU > 70% | 2–10 |
| analytics | mensagens na fila `sua-fila` (1 pod a cada 5) | 1–5 |

O mínimo de 2 nos serviços HTTP mantém a aplicação no ar se um pod cair. O evaluation tem o maior teto porque é o endpoint público e o mais chamado. O auth vem logo depois, porque todos os outros serviços validam chaves nele.

```bash
kubectl get scaledobject -A          # READY e ACTIVE de cada ScaledObject
kubectl get hpa -A                   # HPAs criados pelo KEDA (keda-hpa-<nome>)
kubectl top pods -n evaluation       # consumo de CPU que o gatilho enxerga
```

Para gerar carga e ver o escalonamento acontecer, siga o [Passo 8](#passo-8--testar-a-escalabilidade-keda).

Para mudar os limites, edite `minReplicaCount` e `maxReplicaCount` no `ScaledObject` do serviço e rode `kubectl apply` no arquivo. Não é preciso reiniciar nada.

> Não use `kubectl scale` nesses Deployments: o HPA desfaz a mudança em segundos. Para "congelar" um serviço num número fixo, use a anotação `autoscaling.keda.sh/paused-replicas`, como no Passo 8.4.

### Alternativa sem Ingress: port-forward

```bash
./kubernets/port-forward.sh
```

Esse script expõe cada Service direto em `localhost:18001` … `localhost:18005`. A porta muda para 1800X porque as 800X podem estar ocupadas pelo compose. Encerre com Ctrl+C.

---

## Problemas comuns

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| Pod em `ErrImageNeverPull` | A imagem não foi importada no nó | `./kubernets/load-images.sh <servico>` e depois `kubectl rollout restart` |
| Pod em `CrashLoopBackOff` | O serviço não conecta no banco/Redis | `kubectl logs -n <ns> <pod>`; confira se o compose está de pé (`docker compose ps`) |
| Pod em `CreateContainerConfigError` | Falta o ConfigMap/Secret no namespace | `kubectl apply -f kubernets/02-configMap.yaml -f kubernets/03-secrets.yaml` |
| `curl: Could not resolve host: togglemaster.local` | Falta a linha no `/etc/hosts` | Passo 6.1 |
| `Connection refused` na porta 80 | Ingress Controller não instalado ou não pronto | `kubectl get pods -n ingress-nginx` (Passo 5) |
| `404 Not Found` do nginx | Caminho sem regra, ou Ingress não aplicado | `kubectl get ingress -A`; confira a tabela de rotas |
| `503 Service Temporarily Unavailable` | O Service não tem pods prontos | `kubectl get endpoints -n <ns> <svc>` e `kubectl get pods -n <ns>` |
| `401` em `/flags` mesmo com chave | Chave errada, ou o flag não alcança o auth | Teste `/validate` com a mesma chave; veja os logs do flag |
| `no matches for kind "ScaledObject"` | KEDA não instalado | Passo 4.0 |
| ScaledObject com `READY False` e HPA com `<unknown>/70%` | metrics-server ausente ou sem `--kubelet-insecure-tls` | Passo 4.0; `kubectl top pods -A` precisa funcionar |
| `kubectl apply` do Ingress com erro `Invalid value: "togglemaster.local."` | Ponto no final do host | O host não pode terminar com `.` |
| `ingressclass "nginx" not found` / Ingress sem ADDRESS | Controller não instalado | Passo 5 |

---

## Derrubar tudo

Remover a aplicação do cluster (apagar os namespaces apaga tudo que está dentro deles):

```bash
kubectl delete -f kubernets/09-ingress.yaml
kubectl delete -f kubernets/01-namespaces.yaml
```

Remover o Ingress Controller (opcional; se for usar de novo, pode deixar):

```bash
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
```

Parar os bancos e a fila:

```bash
docker compose down        # mantém os dados (volumes)
docker compose down -v     # apaga também os dados dos bancos
```

---

## Glossário rápido

- **Pod**: a menor unidade do Kubernetes; um ou mais containers rodando juntos.
- **Deployment**: garante que N réplicas de um pod estejam sempre rodando e recria as que morrem.
- **Service (ClusterIP)**: um IP e um nome DNS fixos (`auth.auth.svc.cluster.local`) que distribuem as requisições entre os pods. Os pods mudam de IP, o Service não.
- **Namespace**: uma "pasta" lógica que separa recursos. Nomes só precisam ser únicos dentro do mesmo namespace.
- **ConfigMap / Secret**: variáveis de ambiente injetadas nos pods via `envFrom`. Secret é para dados sensíveis, mas está só em base64, **não criptografado**.
- **Ingress**: regras de roteamento HTTP (host + caminho → Service).
- **Ingress Controller**: o programa (aqui, nginx) que lê os Ingresses e roteia de verdade.
- **`host.docker.internal`**: nome que, de dentro de um container ou pod do Docker Desktop, aponta para a sua máquina.
