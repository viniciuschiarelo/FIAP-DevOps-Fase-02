<p align="center">
  <a href="https://www.fiap.com.br/"><img src="assets/fiap-logo.svg" alt="FIAP" width="240"></a>
</p>

<h3 align="center">POSTECH DevOps e Arquitetura Cloud · Tech Challenge · Fase 2</h3>

<p align="center">
  <b>ToggleMaster</b>: 5 microsserviços conteinerizados e orquestrados no Kubernetes da AWS (EKS)
</p>

<p align="center">
  📄 <a href="docs/tech-challenge-fase-2.pdf"><b>Clique aqui para ver o enunciado do desafio (PDF)</b></a>
</p>

---

## Sumário

1. [O desafio](#1-o-desafio)
2. [Arquitetura](#2-arquitetura)
3. [Estrutura do repositório](#3-estrutura-do-repositório)
4. [Pré-requisitos](#4-pré-requisitos)
5. [Parte 1: rodar localmente (Docker Compose)](#5-parte-1-rodar-localmente-docker-compose)
6. [Parte 2: provisionar a infraestrutura na AWS](#6-parte-2-provisionar-a-infraestrutura-na-aws)
7. [Parte 3: configurar o cluster](#7-parte-3-configurar-o-cluster)
8. [Parte 4: implantar a aplicação](#8-parte-4-implantar-a-aplicação)
9. [Parte 5: testar pelo Load Balancer](#9-parte-5-testar-pelo-load-balancer)
10. [Parte 6: demonstrar a escalabilidade](#10-parte-6-demonstrar-a-escalabilidade)
11. [Checklist dos entregáveis](#11-checklist-dos-entregáveis)
12. [Dia a dia e problemas comuns](#12-dia-a-dia-e-problemas-comuns)
13. [Derrubar tudo (evitar cobrança)](#13-derrubar-tudo-evitar-cobrança)

---

## 1. O desafio

O MVP monolítico do ToggleMaster (Fase 1) foi reescrito como 5 microsserviços. A tarefa é conteinerizar cada um, provisionar a infraestrutura de nuvem e implantá-los num Kubernetes escalável e resiliente na AWS. O enunciado completo está em [`docs/tech-challenge-fase-2.pdf`](docs/tech-challenge-fase-2.pdf).

| Serviço | Linguagem | Porta | Responsabilidade | Dados |
|---|---|---|---|---|
| `auth-service` | Go | 8001 | Cria e valida chaves de API | RDS PostgreSQL |
| `flag-service` | Python | 8002 | CRUD das feature flags | RDS PostgreSQL |
| `targeting-service` | Python | 8003 | Regras de segmentação | RDS PostgreSQL |
| `evaluation-service` | Go | 8004 | Hot path: decide `true`/`false` | ElastiCache (Redis) + publica no SQS |
| `analytics-service` | Python | 8005 | Consome a fila e grava eventos | SQS + DynamoDB |

Este repositório segue a **Opção B (conta AWS pessoal)** do enunciado: cluster criado com `eksctl`, permissões via **IRSA** e autoscaling com **KEDA**. As diferenças para o AWS Academy (Opção A) estão no [quadro da seção 6](#opção-a-aws-academy).

---

## 2. Arquitetura

```
                         Internet
                            │
                            ▼
          Network Load Balancer (criado pelo ingress-nginx)
                            │
┌───────────────────────────┼──────────────────── Amazon EKS ─────────────────────┐
│                           ▼                                                      │
│               Ingress Controller (ingress-nginx)                                 │
│     /validate, /admin    /flags         /rules          /evaluate                │
│            ▼               ▼               ▼                ▼                    │
│      ns auth          ns flag        ns targeting     ns evaluation    ns analytics
│      2–8 pods         2–5 pods       2–5 pods         2–10 pods        1–5 pods  │
│      KEDA (CPU)       KEDA (CPU)     KEDA (CPU)       KEDA (CPU)       KEDA (SQS)│
└──────┬───────────────────┬───────────────┬──────────────┬──────────┬──────┬─────┘
       ▼                   ▼               ▼              ▼          │      ▼
  RDS auth-service-db  RDS flag-…-db  RDS targeting-…  ElastiCache   │   DynamoDB
                                                       (Redis)       ▼   ToggleMasterAnalytics
                                                                SQS evaluation-service-sqs
                                                                (evaluation publica,
                                                                 analytics consome)
```

- Cada microsserviço tem o próprio **namespace**, com **Deployment**, **Service ClusterIP**, **ConfigMap**, **Secret** e **ScaledObject** do KEDA.
- Todos os Deployments têm `requests`/`limits` e `readinessProbe`/`livenessProbe` em `/health`.
- O `evaluation` e o `analytics` acessam SQS e DynamoDB via **IRSA** (ServiceAccount ligada a uma IAM Role), sem chave de acesso no Secret.
- O **Ingress** é a única porta HTTP de entrada. O `analytics` não é exposto porque só consome a fila.

### Por que três data stores diferentes?

| Store | Tipo | Usado por | Por quê |
|---|---|---|---|
| **RDS PostgreSQL** | Relacional | auth, flag, targeting | Dados de configuração com esquema fixo, consistência forte e transações. Um banco por serviço para manter o isolamento entre eles. |
| **ElastiCache (Redis)** | Chave-valor em memória | evaluation | Cache de latência baixíssima no hot path, com TTL curto, para não consultar flag e targeting a cada requisição. |
| **DynamoDB** | NoSQL serverless | analytics | Alto volume de escrita de eventos, sem esquema rígido, escala sozinho e cobra por requisição. |

---

## 3. Estrutura do repositório

```
.
├── assets/                  # logo e imagens do README
├── docs/
│   ├── tech-challenge-fase-2.pdf     # enunciado do desafio
│   └── aulas/                         # material das aulas de Kubernetes Básico
├── services/                # código-fonte + Dockerfile multi-stage de cada microsserviço
│   ├── auth-service/        #   Go     · db/init.sql cria a tabela e a chave do evaluation
│   ├── flag-service/        #   Python · db/init.sql
│   ├── targeting-service/   #   Python · db/init.sql
│   ├── evaluation-service/  #   Go
│   └── analytics-service/   #   Python
├── k8s/                     # manifests do Kubernetes (aplicar em ordem)
│   ├── 01-namespaces.yaml
│   ├── 02-configMap.yaml
│   ├── 03-secrets.yaml
│   ├── 04-authService.yaml … 08-analytics-service.yaml   # Deployment + Service + ScaledObject
│   └── 09-ingress.yaml
├── local/
│   └── elasticmq.conf       # fila SQS local (ElasticMQ) usada pelo Docker Compose
├── scripts/
│   ├── push-ecr.sh          # build + push das 5 imagens no ECR
│   ├── deploy.sh            # aplica k8s/ em ordem e espera os pods
│   └── port-forward.sh      # acessa os Services sem Ingress (debug)
└── docker-compose.yaml      # ambiente local completo
```

| Manifest | O que cria |
|---|---|
| `01-namespaces.yaml` | Namespaces `auth`, `flag`, `targeting`, `evaluation`, `analytics` |
| `02-configMap.yaml` | Dados não sensíveis: porta, URLs internas (`http://<svc>.<ns>.svc.cluster.local`), região, URL da fila, tabela |
| `03-secrets.yaml` | Dados sensíveis em base64: `DATABASE_URL`, `REDIS_URL`, `MASTER_KEY`, `SERVICE_API_KEY` |
| `04` a `08` | Deployment (imagem do ECR, probes, requests/limits) + Service ClusterIP + ScaledObject KEDA |
| `09-ingress.yaml` | Um Ingress por namespace (Ingress só aponta para Services do próprio namespace) |

---

## 4. Pré-requisitos

| Ferramenta | Para quê | Conferir |
|---|---|---|
| [Docker](https://docs.docker.com/get-docker/) + Compose v2 | Build das imagens e ambiente local | `docker compose version` |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | Criar os recursos na AWS | `aws sts get-caller-identity` |
| [eksctl](https://eksctl.io/installation/) | Criar o cluster EKS e as roles IRSA | `eksctl version` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Aplicar os manifests | `kubectl version --client` |
| [Helm 3](https://helm.sh/docs/intro/install/) | Instalar o KEDA | `helm version` |
| `curl` | Testes | |

Configure a AWS CLI com um usuário que tenha permissão de administrador (`aws configure`) e exporte as variáveis usadas no resto do guia:

```bash
export AWS_REGION=us-east-1
export CLUSTER=togglemaster
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

> Todos os comandos são executados a partir da **raiz do repositório**.

---

## 5. Parte 1: rodar localmente (Docker Compose)

O `docker-compose.yaml` sobe os 5 microsserviços, os 4 bancos (3 PostgreSQL + 1 Redis) e os emuladores da AWS (DynamoDB Local + ElasticMQ no lugar do SQS).

```bash
docker compose up -d --build
docker compose ps
```

Os bancos devem aparecer como `Up (healthy)`. O `dynamodb-init` roda uma vez, cria a tabela `ToggleMasterAnalytics` e termina com `Exited (0)`, o que é normal.

| Serviço | URL local |
|---|---|
| auth | http://localhost:8001 |
| flag | http://localhost:8002 |
| targeting | http://localhost:8003 |
| evaluation | http://localhost:8004 |
| analytics | http://localhost:8005/health |
| DynamoDB Admin | http://localhost:9002 |
| ElasticMQ (SQS) | http://localhost:9324 |

Teste rápido do fluxo local:

```bash
for p in 8001 8002 8003 8004 8005; do curl -s localhost:$p/health; echo; done

KEY=$(curl -s -X POST localhost:8001/admin/keys \
  -H "Content-Type: application/json" -H "Authorization: Bearer admin-secreto-123" \
  -d '{"name":"local"}' | sed -E 's/.*"key":"([^"]+)".*/\1/')

curl -s -X POST localhost:8002/flags -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"enable-new-dashboard","description":"Novo dashboard","is_enabled":true}'
curl -s -X POST localhost:8003/rules -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"flag_name":"enable-new-dashboard","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}'
curl -s "localhost:8004/evaluate?user_id=user-1&flag_name=enable-new-dashboard"
```

> **Limitação conhecida (só no ambiente local):** o `evaluation-service` não lê a variável `SQS_ENDPOINT`, então no compose ele tenta publicar na AWS real e loga `InvalidClientTokenId`. A avaliação funciona normalmente, só o evento não chega no ElasticMQ. No EKS isso não acontece, porque lá a fila é o SQS de verdade.

Para parar: `docker compose down` (mantém os dados) ou `docker compose down -v` (apaga os volumes).

---

## 6. Parte 2: provisionar a infraestrutura na AWS

Checklist da etapa 2 do enunciado:

- [ ] Cluster EKS + Managed Node Group
- [ ] 5 repositórios ECR com as imagens publicadas
- [ ] 3 instâncias RDS PostgreSQL (auth, flag, targeting)
- [ ] 1 ElastiCache Redis (evaluation)
- [ ] 1 tabela DynamoDB (analytics)
- [ ] 1 fila SQS Standard (evaluation → analytics)

### 6.1 Cluster EKS

```bash
eksctl create cluster \
  --name $CLUSTER --region $AWS_REGION \
  --managed --nodegroup-name togglemaster-ng \
  --node-type t3.medium --nodes 3 --nodes-min 1 --nodes-max 4 \
  --with-oidc
```

Leva de 15 a 20 minutos. O `--with-oidc` já associa o provedor OIDC ao cluster, que o IRSA exige. No fim, o `eksctl` configura o `kubectl` sozinho:

```bash
kubectl get nodes
```

### 6.2 ECR: repositórios e imagens

```bash
for s in auth flag targeting evaluation analytics; do
  aws ecr create-repository --repository-name $s-image --region $AWS_REGION
done

./scripts/push-ecr.sh            # builda e publica as 5 imagens (tag latest)
```

> Os manifests apontam para a conta `217140917440`. Se a sua conta for outra, troque o ID em todos eles:
> ```bash
> sed -i "s/217140917440/$ACCOUNT_ID/g" k8s/*.yaml
> ```

### 6.3 Rede dos bancos

Os bancos ficam nas **subnets privadas da VPC do cluster**, protegidos pelo **security group do cluster**. Esse SG já libera todo o tráfego entre os seus membros, e os nós do Managed Node Group fazem parte dele. Assim, só os pods alcançam os bancos.

```bash
VPC_ID=$(aws eks describe-cluster --name $CLUSTER --query cluster.resourcesVpcConfig.vpcId --output text)
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID Name=tag:kubernetes.io/role/internal-elb,Values=1 \
  --query 'Subnets[].SubnetId' --output text)
echo $VPC_ID $CLUSTER_SG $PRIVATE_SUBNETS
```

### 6.4 RDS PostgreSQL (3 instâncias)

```bash
aws rds create-db-subnet-group --db-subnet-group-name togglemaster-db \
  --db-subnet-group-description "ToggleMaster" --subnet-ids $PRIVATE_SUBNETS

for s in auth flag targeting; do
  aws rds create-db-instance \
    --db-instance-identifier $s-service-db \
    --engine postgres --db-instance-class db.t3.micro --allocated-storage 20 \
    --master-username postgres --master-user-password 12345678 \
    --db-subnet-group-name togglemaster-db --vpc-security-group-ids $CLUSTER_SG \
    --no-publicly-accessible --backup-retention-period 0
done

for s in auth flag targeting; do aws rds wait db-instance-available --db-instance-identifier $s-service-db; done

for s in auth flag targeting; do
  aws rds describe-db-instances --db-instance-identifier $s-service-db \
    --query 'DBInstances[0].Endpoint.Address' --output text
done
```

> Use uma senha sua no lugar de `12345678` e lembre de refleti-la no `03-secrets.yaml`.

### 6.5 ElastiCache Redis (Serverless)

```bash
aws elasticache create-serverless-cache \
  --serverless-cache-name evaluation-service-db --engine redis \
  --subnet-ids $PRIVATE_SUBNETS --security-group-ids $CLUSTER_SG

aws elasticache describe-serverless-caches --serverless-cache-name evaluation-service-db \
  --query 'ServerlessCaches[0].[Status,Endpoint.Address]' --output text   # espere "available"
```

O ElastiCache Serverless exige criptografia em trânsito, por isso a URL usa **`rediss://`** (com dois "s").

### 6.6 DynamoDB

O `analytics-service` espera a tabela `ToggleMasterAnalytics` com a chave `event_id` (String):

```bash
aws dynamodb create-table --table-name ToggleMasterAnalytics \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 6.7 SQS

```bash
aws sqs create-queue --queue-name evaluation-service-sqs
aws sqs get-queue-url --queue-name evaluation-service-sqs
```

### 6.8 Anote as strings de conexão

| Recurso | Onde vai | Formato |
|---|---|---|
| RDS auth / flag / targeting | `03-secrets.yaml` → `DATABASE_URL` | `postgres://postgres:<senha>@<endpoint>:5432/postgres?sslmode=require` |
| ElastiCache | `03-secrets.yaml` → `REDIS_URL` | `rediss://<endpoint>:6379` |
| SQS | `02-configMap.yaml` → `AWS_SQS_URL` e `08-analytics-service.yaml` → `queueURL` | `https://sqs.<regiao>.amazonaws.com/<conta>/evaluation-service-sqs` |
| DynamoDB | `02-configMap.yaml` → `AWS_DYNAMODB_TABLE` | `ToggleMasterAnalytics` |

Os valores do Secret ficam em **base64** (codificação, não criptografia):

```bash
echo -n 'postgres://postgres:12345678@auth-service-db.xxxx.us-east-1.rds.amazonaws.com:5432/postgres?sslmode=require' | base64 -w0
echo 'valor-em-base64' | base64 -d     # conferir
```

O RDS precisa de `sslmode=require` porque o PostgreSQL do RDS recusa conexão sem SSL.

### Opção A: AWS Academy

Se for usar o AWS Academy, os passos mudam assim:

| Etapa | Opção B (este repo) | Opção A (Academy) |
|---|---|---|
| Cluster | `eksctl create cluster` | Console do EKS, com **LabRole** como Cluster Role |
| Node group | Criado pelo `eksctl` | Managed Node Group pelo console, com **LabRole** como Node Role (mín 1, desejado 2, máx 4) |
| Permissão AWS dos pods | IRSA (`evaluation-sa`, `analytics-sa`) | Herdada da LabRole do nó: remova `serviceAccountName` dos manifests 07 e 08 |
| Escala do analytics | KEDA pela fila SQS | HPA por CPU (KEDA não funciona sem IRSA) |
| Escala dos serviços HTTP | KEDA (CPU) | HPA por CPU (`targetCPUUtilizationPercentage: 70`) |

---

## 7. Parte 3: configurar o cluster

### 7.1 Namespaces

As ServiceAccounts do IRSA moram nos namespaces da aplicação, então eles precisam existir antes:

```bash
kubectl apply -f k8s/01-namespaces.yaml
```

### 7.2 IRSA: permissões AWS dos pods

O `eksctl` cria a IAM Role, a relação de confiança com o OIDC do cluster e a ServiceAccount anotada com o ARN da role:

```bash
eksctl create iamserviceaccount --cluster $CLUSTER --region $AWS_REGION \
  --namespace evaluation --name evaluation-sa \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess \
  --approve

eksctl create iamserviceaccount --cluster $CLUSTER --region $AWS_REGION \
  --namespace analytics --name analytics-sa \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess \
  --approve

kubectl get sa evaluation-sa -n evaluation -o yaml | grep role-arn
```

### 7.3 Metrics Server

Necessário para os gatilhos de CPU (HPA/KEDA):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl top nodes        # depois de ~1 min mostra CPU/memória
```

### 7.4 KEDA (com IRSA para ler o tamanho da fila)

O `ScaledObject` do analytics consulta o SQS com a identidade do **próprio operador do KEDA** (`TriggerAuthentication` com `podIdentity.provider: aws`). Por isso o operador recebe uma role só de leitura no SQS:

```bash
eksctl create iamserviceaccount --cluster $CLUSTER --region $AWS_REGION \
  --namespace keda --name keda-operator --role-name keda-operator-irsa --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonSQSReadOnlyAccess \
  --approve

helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda -n keda --create-namespace \
  --set podIdentity.aws.irsa.enabled=true \
  --set podIdentity.aws.irsa.roleArn=arn:aws:iam::$ACCOUNT_ID:role/keda-operator-irsa

kubectl get pods -n keda       # 3 pods Running
```

### 7.5 Nginx Ingress Controller

O manifest do provider AWS cria um **Network Load Balancer** público:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/aws/deploy.yaml

kubectl wait -n ingress-nginx --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=300s

kubectl get ingressclass       # deve listar "nginx"
```

---

## 8. Parte 4: implantar a aplicação

### 8.1 Criar as tabelas nos RDS

Os bancos são privados, então os scripts `init.sql` rodam a partir de um pod temporário dentro do cluster. O `init.sql` do auth também cadastra a chave de serviço que o `evaluation` usa (`SERVICE_API_KEY`).

```bash
for s in auth flag targeting; do
  HOST=$(aws rds describe-db-instances --db-instance-identifier $s-service-db \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  kubectl run psql-$s --rm -i --restart=Never --image=postgres:16-alpine -- \
    psql "postgres://postgres:12345678@$HOST:5432/postgres?sslmode=require" \
    < services/$s-service/db/init.sql
done
```

### 8.2 Aplicar os manifests

Depois de revisar `02-configMap.yaml` e `03-secrets.yaml` com os seus endpoints:

```bash
./scripts/deploy.sh
```

O script aplica `k8s/01` a `k8s/09` em ordem (namespace → ConfigMap/Secret → Deployments → Ingress) e espera cada rollout. O esperado é no mínimo **9 pods** `1/1 Running` (2 de auth, flag, targeting e evaluation, mais 1 de analytics).

```bash
kubectl get pods -A | grep -E 'auth|flag|targeting|evaluation|analytics'
kubectl get scaledobject -A    # todos com READY True
kubectl get ingress -A
```

---

## 9. Parte 5: testar pelo Load Balancer

```bash
export LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo http://$LB
```

> O DNS do NLB pode levar 2 a 3 minutos para começar a responder.

### Rotas expostas

| Caminho | Serviço | Autenticação |
|---|---|---|
| `/validate` | auth :8001 | Chave de API |
| `/admin/keys` | auth :8001 | `MASTER_KEY` |
| `/flags[/<nome>]` | flag :8002 | Chave de API |
| `/rules[/<flag>]` | targeting :8003 | Chave de API |
| `/evaluate` | evaluation :8004 | Pública |

### Fluxo completo

```bash
# 1. Criar uma chave de API com a MASTER_KEY
export KEY=$(curl -s -X POST http://$LB/admin/keys \
  -H "Content-Type: application/json" -H "Authorization: Bearer admin-secreto-123" \
  -d '{"name":"minha-chave"}' | sed -E 's/.*"key":"([^"]+)".*/\1/')
echo $KEY

# 2. Validar
curl -s http://$LB/validate -H "Authorization: Bearer $KEY"

# 3. Criar uma flag
curl -s -X POST http://$LB/flags -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"enable-new-dashboard","description":"Novo dashboard","is_enabled":true}'

# 4. Criar uma regra: liberar para 50% dos usuários
curl -s -X POST http://$LB/rules -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"flag_name":"enable-new-dashboard","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}'

# 5. Avaliar para vários usuários (endpoint público)
for u in user-1 user-2 user-3 user-4; do
  curl -s "http://$LB/evaluate?user_id=$u&flag_name=enable-new-dashboard"; echo
done
```

O mesmo `user_id` sempre recebe o mesmo resultado, porque a decisão vem de um hash do usuário. Cada avaliação vira uma mensagem no SQS, que o analytics grava no DynamoDB:

```bash
kubectl logs -n evaluation -l app=evaluation --prefix --tail=20 | grep -iE 'cache|sqs'
kubectl logs -n analytics -l app=analytics --prefix --tail=20
aws dynamodb scan --table-name ToggleMasterAnalytics --select COUNT
```

---

## 10. Parte 6: demonstrar a escalabilidade

| Serviço | Gatilho | Mín–Máx |
|---|---|---|
| auth | CPU > 70% do `requests.cpu` (100m) | 2–8 |
| flag | CPU > 70% | 2–5 |
| targeting | CPU > 70% | 2–5 |
| evaluation | CPU > 70% | 2–10 |
| analytics | Mensagens na fila (1 pod a cada 5) | 1–5 |

O KEDA cria um HPA (`keda-hpa-<nome>`) para cada `ScaledObject`. Ele sobe réplicas em 15 a 30 s e só desce depois de 5 minutos de carga baixa.

**Por que KEDA no analytics?** O analytics é um worker de fila. A CPU dele só sobe *depois* que as mensagens já se acumularam, então um HPA por CPU reage atrasado. O KEDA lê direto o `ApproximateNumberOfMessages` do SQS e escala pela causa (fila cheia), não pelo sintoma (CPU).

### 10.1 evaluation por CPU

Em dois terminais extras:

```bash
kubectl get hpa -n evaluation -w
kubectl get pods -n evaluation -w
```

Gere 3 minutos de carga com o [hey](https://github.com/rakyll/hey), de dentro do cluster:

```bash
kubectl run hey -n evaluation --rm -it --restart=Never --image=williamyeh/hey -- \
  -z 3m -c 50 \
  "http://evaluation.evaluation.svc.cluster.local:8004/evaluate?user_id=user-1&flag_name=enable-new-dashboard"
```

```
NAME                  REFERENCE               TARGETS         MINPODS   MAXPODS   REPLICAS
keda-hpa-evaluation   Deployment/evaluation   cpu: 3%/70%     2         10        2
keda-hpa-evaluation   Deployment/evaluation   cpu: 245%/70%   2         10        7
keda-hpa-evaluation   Deployment/evaluation   cpu: 98%/70%    2         10        10
```

Para ver o motivo de cada decisão: `kubectl describe hpa keda-hpa-evaluation -n evaluation | tail -15`.

### 10.2 analytics pela fila SQS

O analytics consome rápido demais para a fila acumular. Por isso o teste segue a ordem **pausar → encher a fila → despausar**:

```bash
# 1. Pausar: o KEDA mantém o Deployment em 0 réplicas
kubectl annotate scaledobject analytics -n analytics autoscaling.keda.sh/paused-replicas="0" --overwrite

# 2. Enviar 100 mensagens
QUEUE_URL=$(aws sqs get-queue-url --queue-name evaluation-service-sqs --query QueueUrl --output text)
for i in $(seq 1 100); do
  aws sqs send-message --queue-url $QUEUE_URL --message-body \
    "{\"user_id\":\"user-$i\",\"flag_name\":\"enable-new-dashboard\",\"result\":true,\"timestamp\":\"$(date -u +%FT%TZ)\"}" >/dev/null
done
aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names ApproximateNumberOfMessages

# 3. Despausar e observar (em outro terminal: kubectl get pods -n analytics -w)
kubectl annotate scaledobject analytics -n analytics autoscaling.keda.sh/paused-replicas-
```

Com 100 mensagens a conta dá 100 ÷ 5 = 20 réplicas, limitado ao máximo de **5 pods**. A fila esvazia e os eventos aparecem no DynamoDB:

```bash
aws dynamodb scan --table-name ToggleMasterAnalytics --select COUNT
```

---

## 11. Checklist dos entregáveis

Roteiro para o vídeo de demonstração (até 20 min):

- [ ] `docker compose up` com os 5 apps + 4 bancos rodando (`docker compose ps`), [seção 5](#5-parte-1-rodar-localmente-docker-compose)
- [ ] Cluster EKS no console da AWS e `kubectl get nodes`
- [ ] Os 5 microsserviços como pods: `kubectl get pods -A`
- [ ] Ingress funcionando: `curl` na URL do Load Balancer, [seção 9](#9-parte-5-testar-pelo-load-balancer)
- [ ] Carga no evaluation e o HPA subindo réplicas, [seção 10.1](#101-evaluation-por-cpu)
- [ ] Mensagens enviadas ao SQS e o KEDA escalando o analytics, [seção 10.2](#102-analytics-pela-fila-sqs)
- [ ] Dados aparecendo na tabela do DynamoDB
- [ ] Explicação da arquitetura e dos desafios encontrados, [seção 2](#2-arquitetura)
- [ ] Justificativa do KEDA no analytics, [seção 10](#10-parte-6-demonstrar-a-escalabilidade)
- [ ] Diferença entre RDS, ElastiCache e DynamoDB, [seção 2](#por-que-três-data-stores-diferentes)

Relatório de entrega (PDF ou txt): nomes, RM e usuários do Discord dos participantes, link deste repositório e link do vídeo.

---

## 12. Dia a dia e problemas comuns

### Publicar uma nova versão de um serviço

```bash
./scripts/push-ecr.sh evaluation
kubectl rollout restart deployment/evaluation -n evaluation
```

### Alterar ConfigMap ou Secret

Os pods só leem variáveis de ambiente quando nascem:

```bash
kubectl apply -f k8s/02-configMap.yaml -f k8s/03-secrets.yaml
kubectl rollout restart deployment/flag -n flag
```

### Acessar sem Ingress

```bash
./scripts/port-forward.sh      # expõe cada Service em localhost:1800X
```

### Problemas comuns

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| Pod em `ImagePullBackOff` | Imagem não está no ECR ou o ID da conta está errado | `aws ecr list-images --repository-name auth-image`; confira o `image:` do manifest |
| Pod em `CrashLoopBackOff` | Não conecta no RDS/Redis | `kubectl logs -n <ns> <pod>`; confira endpoint, `sslmode=require`, `rediss://` e o security group |
| `relation "api_keys" does not exist` | `init.sql` não foi executado | [Seção 8.1](#81-criar-as-tabelas-nos-rds) |
| `CreateContainerConfigError` | Falta ConfigMap/Secret no namespace | `kubectl apply -f k8s/02-configMap.yaml -f k8s/03-secrets.yaml` |
| `AccessDenied` no SQS/DynamoDB | ServiceAccount IRSA ausente ou sem policy | [Seção 7.2](#72-irsa-permissões-aws-dos-pods); `kubectl describe sa -n analytics analytics-sa` |
| `no matches for kind "ScaledObject"` | KEDA não instalado | [Seção 7.4](#74-keda-com-irsa-para-ler-o-tamanho-da-fila) |
| HPA com `<unknown>/70%` | metrics-server ausente | [Seção 7.3](#73-metrics-server); `kubectl top pods -A` precisa funcionar |
| ScaledObject do analytics com `READY False` | KEDA sem permissão de ler a fila | Reinstale o KEDA com a role IRSA da seção 7.4 |
| Pods novos em `Pending` | Nós sem CPU livre | `kubectl describe pod`; aumente `--nodes` do node group |
| `404` do nginx | Caminho sem regra | Confira a tabela de rotas e `kubectl get ingress -A` |
| `503` do nginx | Service sem pods prontos | `kubectl get endpoints -n <ns> <svc>` |

---

## 13. Derrubar tudo (evitar cobrança)

A ordem importa: o Load Balancer e os bancos precisam sair **antes** do cluster, senão a VPC criada pelo `eksctl` não consegue ser apagada.

```bash
# Aplicação e Load Balancer
kubectl delete -f k8s/09-ingress.yaml -f k8s/01-namespaces.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/aws/deploy.yaml
helm uninstall keda -n keda

# Bancos, cache, fila e tabela
for s in auth flag targeting; do
  aws rds delete-db-instance --db-instance-identifier $s-service-db --skip-final-snapshot
done
aws elasticache delete-serverless-cache --serverless-cache-name evaluation-service-db
aws dynamodb delete-table --table-name ToggleMasterAnalytics
aws sqs delete-queue --queue-url $(aws sqs get-queue-url --queue-name evaluation-service-sqs --query QueueUrl --output text)
for s in auth flag targeting; do aws rds wait db-instance-deleted --db-instance-identifier $s-service-db; done
aws rds delete-db-subnet-group --db-subnet-group-name togglemaster-db

# Imagens
for s in auth flag targeting evaluation analytics; do
  aws ecr delete-repository --repository-name $s-image --force
done

# Cluster (remove também as roles IRSA criadas pelo eksctl e a VPC)
eksctl delete cluster --name $CLUSTER --region $AWS_REGION
```

> Se a exclusão da VPC falhar, espere o ElastiCache terminar de ser removido (`aws elasticache describe-serverless-caches`) e rode o `eksctl delete cluster` de novo.

---

<p align="center">
  Material de apoio: <a href="docs/aulas/">aulas de Kubernetes Básico</a> · <a href="docs/tech-challenge-fase-2.pdf">enunciado do Tech Challenge</a>
</p>
