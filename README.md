# autogiro-infra-k8s

> **AutoGiro** · plataforma dos microsserviços — Tech Challenge Fase 4 (13SOAT)

Infraestrutura **Kubernetes** do AutoGiro, provisionada com Terraform: cluster, API Gateway,
broker de mensagens, configuração compartilhada e observabilidade. Os microsserviços (OS,
Billing e Execution) trazem os próprios manifestos e são publicados pelas próprias pipelines
sobre esta plataforma.

## Propósito

- Provisiona o cluster **Amazon EKS** (rede, IAM, control plane e node group), com
  escalabilidade de pods via **HPA**. O node group tem 3 nós e teto de 4, mas não há Cluster
  Autoscaler: um quarto nó entra ajustando `desired_size`, não sozinho.
- Instala o **Kong Gateway** como Ingress Controller e API Gateway, e cria os plugins
  `autogiro-jwt` (validação do token) e `autogiro-prometheus` (métricas do gateway), além do
  Consumer e da credencial JWT.
- Sobe o **RabbitMQ**, o broker da Saga entre os microsserviços.
- Cria a configuração compartilhada **`autogiro-plataforma`** (Secret e ConfigMap): segredo do
  JWT, URL do broker, license key e endpoint OTLP do New Relic, lidos pelos três serviços.
- Instala o **metrics-server**, pré-requisito do HPA.
- Instala o **agente New Relic** (infraestrutura, logs, eventos do cluster e métricas
  Prometheus).
- Cria **dashboards e alertas do New Relic como código**.

O que **não** está aqui: os Deployments, Services, HPAs e Ingresses de cada microsserviço,
nem os bancos. Cada serviço versiona os seus manifestos em `k8s/` e os aplica no cluster pela
própria pipeline (ver [Deploy dos microsserviços](#deploy-dos-microsserviços)).

## Repositórios da plataforma

| Repositório | Papel |
|---|---|
| [autogiro-os-service](https://github.com/Figueiraa/autogiro-os-service) | Atendimento: clientes, veículos, catálogo de serviços e ordens de serviço; orquestra a Saga |
| [autogiro-billing-service](https://github.com/Figueiraa/autogiro-billing-service) | Orçamentos e pagamento pelo Mercado Pago |
| [autogiro-execution-service](https://github.com/Figueiraa/autogiro-execution-service) | Peças, estoque e fila de execução da oficina |
| **autogiro-infra-k8s** (este) | Cluster EKS, Kong, RabbitMQ, configuração compartilhada e New Relic |
| [autogiro-auth](https://github.com/Figueiraa/autogiro-auth) | Lambda que autentica o cliente pelo CPF e emite o JWT |

## Documentação

| Documento | Conteúdo |
|---|---|
| [docs/apis-e-gateway.md](docs/apis-e-gateway.md) | Rotas publicadas no Kong, validação do JWT, como obter o token e endpoints de cada serviço |
| [docs/adr/ADR-012-kubernetes-no-eks.md](docs/adr/ADR-012-kubernetes-no-eks.md) | Por que EKS, versão do Kubernetes, tipo e número de nós, cluster ligado só quando necessário |
| [CUSTO.md](CUSTO.md) | Custo por hora, cenários de uso e checklist depois do destroy |
| [Documentação geral do AutoGiro](https://github.com/Figueiraa/autogiro-os-service/blob/main/docs/README.md) | Arquitetura dos microsserviços, Saga, mensageria e os demais ADRs |

## Tecnologias

| Item | Tecnologia |
|---|---|
| IaC | Terraform ≥ 1.5 · state no HCP Terraform |
| Cluster | Amazon EKS gerenciado (Kubernetes 1.35, só suporte padrão) |
| Nós | Node group gerenciado · 3× `t4g.small` (Graviton/ARM) |
| Provider de nuvem | `hashicorp/aws` ~> 5.70 |
| API Gateway | Kong Gateway OSS 3.x (DB-less), chart 2.46.0 |
| Autoscaling | metrics-server 3.12.2 + HPA |
| Mensageria | RabbitMQ 4.0 (imagem oficial, fixada por digest) |
| Observabilidade | New Relic (nri-bundle 5.0.100) · provider `newrelic/newrelic` ~> 3.30 |
| Qualidade | tflint · checkov |
| CI/CD | GitHub Actions |

## Arquitetura

```
                          internet
                              │
                              │ http://<ip-publico-de-um-no>:30080
                              ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │ AWS · us-east-1                                                      │
   │                                                                      │
   │   ┌──────────────────────────────────────────────────────────────┐   │
   │   │ VPC 10.0.0.0/16  (DNS support + hostnames)                   │   │
   │   │                                                              │   │
   │   │   Internet Gateway ──► route table pública (0.0.0.0/0)       │   │
   │   │                                                              │   │
   │   │   ┌──────────────────────┐    ┌──────────────────────┐       │   │
   │   │   │ subnet 10.0.0.0/24   │    │ subnet 10.0.1.0/24   │       │   │
   │   │   │ zona use1-az1        │    │ zona use1-az2        │       │   │
   │   │   │ pública (map IP)     │    │ pública (map IP)     │       │   │
   │   │   │ nós com IP público   │    │ nós com IP público   │       │   │
   │   │   └──────────┬───────────┘    └──────────┬───────────┘       │   │
   │   │              │  SG dos nós: 30080 aberta │                   │   │
   │   │              │  (sem Load Balancer:      │                   │   │
   │   │              │   a conta não permite)    │                   │   │
   │   │   ┌──────────▼───────────────────────────▼───────────┐       │   │
   │   │   │ EKS control plane "autogiro" · Kubernetes 1.35   │       │   │
   │   │   │ endpoint público · logs do cluster desabilitados │       │   │
   │   │   └──────────┬───────────────────────────────────────┘       │   │
   │   │              │                                               │   │
   │   │   ┌──────────▼───────────────────────────────────────────┐   │   │
   │   │   │ node group "autogiro-nodes"                          │   │   │
   │   │   │ 3× t4g.small · AL2023_ARM_64_STANDARD · EBS 20 GB    │   │   │
   │   │   │ ON_DEMAND · min 3 / desired 3 / max 4                │   │   │
   │   │   │                                                      │   │   │
   │   │   │  ┌────────────────────────────────────────────┐      │   │   │
   │   │   │  │ ns: kong                                   │      │   │   │
   │   │   │  │  kong-kong-proxy   NodePort 30080          │◄─────┼───┼───┼── tráfego
   │   │   │  │  kong-kong-admin   ClusterIP               │      │   │   │
   │   │   │  └─────────────────┬──────────────────────────┘      │   │   │
   │   │   │                    │ Ingress de cada serviço         │   │   │
   │   │   │  ┌─────────────────▼──────────────────────────┐      │   │   │
   │   │   │  │ ns: autogiro                               │      │   │   │
   │   │   │  │  os-service        ┐                       │ HPA  │   │   │
   │   │   │  │  billing-service   ├─ AMQP ─► rabbitmq     │ 2..6 │   │   │
   │   │   │  │  execution-service ┘                       │ cada │   │   │
   │   │   │  │  autogiro-plataforma  Secret + ConfigMap   │      │   │   │
   │   │   │  │  KongConsumer · KongPlugin jwt/prometheus  │      │   │   │
   │   │   │  └────────────────────────────────────────────┘      │   │   │
   │   │   │  ┌────────────────────────────────────────────┐      │   │   │
   │   │   │  │ ns: newrelic                               │      │   │   │
   │   │   │  │  nri-bundle (infra + logs + eventos)       │──────┼───┼───┼──► New Relic
   │   │   │  │  newrelic-prometheus-agent                 │      │   │   │
   │   │   │  └────────────────────────────────────────────┘      │   │   │
   │   │   │  ┌────────────────────────────────────────────┐      │   │   │
   │   │   │  │ kube-system: metrics-server                │      │   │   │
   │   │   │  └────────────────────────────────────────────┘      │   │   │
   │   │   └──────────────────────────────────────────────────────┘   │   │
   │   └──────────────────────────────────────────────────────────────┘   │
   └──────────────────────────────────────────────────────────────────────┘

         bancos fora do cluster: Neon (OS, Billing) · MongoDB Atlas (Execution)
```

O que é de cada parte:

| Componente | Criado por | Arquivo |
|---|---|---|
| VPC, subnets, IAM, control plane, node group, regra da porta 30080 | Este repositório | [`terraform/eks.tf`](terraform/eks.tf) |
| Namespaces `autogiro` e `kong`, metrics-server, Kong, New Relic | Este repositório | [`terraform/main.tf`](terraform/main.tf) |
| Consumer, credencial e plugin JWT | Este repositório | [`terraform/kong-jwt.tf`](terraform/kong-jwt.tf) |
| Plugin `autogiro-prometheus` e scrape do Kong | Este repositório | [`terraform/kong-metrics.tf`](terraform/kong-metrics.tf) |
| RabbitMQ (Deployment, Service, credenciais) | Este repositório | [`terraform/rabbitmq.tf`](terraform/rabbitmq.tf) |
| `autogiro-plataforma` (Secret e ConfigMap) | Este repositório | [`terraform/plataforma.tf`](terraform/plataforma.tf) |
| Deployment, Service, HPA, Ingress e Secret de cada serviço | Pipeline do serviço | `k8s/` de cada microsserviço |

Sem NAT Gateway: os nós ficam em subnet pública com IP público automático e saem para a
internet (registry de imagens, endpoint do EKS, ingestão do New Relic, bancos) pelo Internet
Gateway. Duas zonas porque o EKS recusa criar o control plane com menos que isso; as zonas são
fixadas pelo ID (`use1-az1` e `use1-az2`), para que uma zona nova da AWS não mude onde as
subnets são criadas.

### RabbitMQ

Uma réplica, sem volume persistente (o EKS não traz o driver de EBS instalado), com
estratégia `Recreate` para nunca haver duas instâncias dividindo as filas. O usuário `guest`
é substituído por `autogiro`, com senha gerada pelo Terraform (`random_password`) e montada
como arquivo de configuração, fora das variáveis de ambiente. O container roda sem root, com
sistema de arquivos somente leitura e sem capabilities. Só há Service `ClusterIP`: o broker
não é exposto fora do cluster.

As exchanges e filas são declaradas pelos próprios serviços ao subir. A perda do que estava
na fila é tolerada pelo desenho da Saga: mensagem não publicada continua no outbox do serviço
que a criou, e comando perdido é reenviado pelo orquestrador depois de 120 s sem resposta.

### Configuração compartilhada

[`terraform/plataforma.tf`](terraform/plataforma.tf) cria o Secret e o ConfigMap
`autogiro-plataforma` no namespace `autogiro`. Os Deployments dos três serviços leem os dois
com `envFrom`, junto com o Secret e o ConfigMap próprios de cada serviço (banco, Mercado
Pago), criados pela pipeline dele.

| Objeto | Chaves |
|---|---|
| Secret | `JWT_SECRET` (o mesmo que o Kong usa) · `RABBITMQ_URL` · `NEW_RELIC_LICENSE_KEY` |
| ConfigMap | `OTEL_EXPORTER_OTLP_ENDPOINT` (vazio sem license key) · `DEPLOYMENT_ENVIRONMENT` |

## Por que EKS

A decisão completa, com as alternativas, está no
[ADR-012](docs/adr/ADR-012-kubernetes-no-eks.md). Em resumo: o projeto já rodava no EKS na fase
anterior, e o custo é controlado pela rotina de **subir e destruir**. O EKS cobra por hora de
existência do cluster, não por uso, e o total fica em **~US$ 0,17/h** — poucos dólares ao
longo da entrega. A tabela completa, os cenários de uso e o checklist pós-destroy estão em
[CUSTO.md](CUSTO.md).

Decisões de economia, todas registradas no ponto onde são feitas:

| Decisão | Motivo | Onde |
|---|---|---|
| **Kubernetes 1.35 e `upgrade_policy = STANDARD`** | Uma versão fora do suporte padrão passa a cobrar US$ 0,60/h pelo control plane em vez de US$ 0,10/h. O 1.31 do projeto anterior já estava nessa faixa | `terraform/eks.tf`, `terraform/variables.tf` |
| **Sem NAT Gateway** — nós em subnet pública | O NAT custa ~US$ 0,045/h mais tráfego processado; o Internet Gateway não tem custo por hora | `terraform/eks.tf` |
| **Logs do control plane desabilitados** (`enabled_cluster_log_types = []`) | Cada tipo vira um log group no CloudWatch, cobrado por GB ingerido e armazenado; a observabilidade vem do New Relic, de dentro do cluster | `terraform/eks.tf` |
| **3× `t4g.small` (Graviton/ARM)** | A conta está no plano gratuito da AWS, que recusa a `t4g.medium`. A `t4g.small` é elegível, mas aceita só 11 pods por nó, por isso três nós. Exige imagens `arm64` dos serviços e AMI `AL2023_ARM_64_STANDARD` | `terraform/variables.tf` |
| **NodePort em vez de Load Balancer** | Não foi escolha: a conta responde `OperationNotPermitted` a qualquer Load Balancer. Perde-se o DNS estável e o balanceamento entre nós; o roteamento, os plugins e a validação de JWT são idênticos | `terraform/main.tf` |
| **Recursos nativos `aws_eks_*`** em vez do módulo `terraform-aws-modules/eks` | O módulo cria por padrão subnets privadas com NAT Gateway, KMS próprio e log groups no CloudWatch — tudo cobrado à parte | `terraform/eks.tf` |
| **Pixie desabilitado** no nri-bundle | Exige mais recursos do que os nós `t4g.small` comportam e o eBPF elevaria o volume ingerido acima da cota gratuita | `terraform/main.tf` |

**Honestamente: em produção isso seria diferente.** Os nós ficariam em subnets privadas, com NAT
Gateway (ou VPC endpoints) para a saída, e apenas o Load Balancer viveria na subnet pública. Os
logs do control plane estariam habilitados, e o RabbitMQ teria volume persistente e mais de
uma réplica. Aqui a exposição é mitigada pelo security group dos nós, gerenciado pelo próprio
EKS, que só abre para a internet a porta 30080 do Kong.

## Pré-requisitos

```bash
terraform version              # >= 1.5
aws --version                  # AWS CLI v2 no PATH
kubectl version --client

aws sts get-caller-identity    # credenciais válidas (aws configure ou variáveis de ambiente)
terraform login                # token do HCP Terraform, onde vive o state
```

O bloco `exec` dos providers `kubernetes`, `helm` e `kubectl` chama `aws eks get-token` a cada
operação, então a AWS CLI **precisa** estar no PATH e autenticada — o token nunca é gravado no
state.

Policies IAM necessárias no usuário que roda o Terraform:

| Policy | Para quê |
|---|---|
| `AmazonEKSClusterPolicy` · `AmazonEKSServicePolicy` | Criar e administrar o cluster |
| `AmazonEC2FullAccess` | VPC, subnets, Internet Gateway, route tables, node group, EBS |
| `IAMFullAccess` (ou permissão de `iam:CreateRole`, `AttachRolePolicy`, `PassRole`) | Criar as roles do control plane e dos nós |
| `ElasticLoadBalancingFullAccess` | Concedida antes de descobrir a restrição da conta; hoje não chega a ser usada |
| `eks:*` | `CreateCluster`, `CreateNodegroup`, `DescribeCluster`, `GetToken` |

O state fica no **HCP Terraform** (`terraform/backend.tf`, organização `autogiro`), com o
workspace escolhido em tempo de execução via `TF_WORKSPACE`. O cluster em uso vive no
workspace **`autogiro-infra-k8s-prod`**, o único usado pelos scripts e pela pipeline. Um
segundo workspace com cluster não funciona nesta conta: as roles IAM são globais, e um segundo
`apply` falharia com `EntityAlreadyExists` depois de já ter criado a rede. Autenticação por `terraform login` na máquina ou `TF_TOKEN_app_terraform_io`
no ambiente.

## Uso

Os scripts `subir-cluster.ps1` e `destruir-cluster.ps1` automatizam a rotina (inclusive ligar
e desligar o deploy dos serviços), mas **estão no `.gitignore`** porque carregam as credenciais
preenchidas. Os comandos equivalentes, exportando as variáveis de ambiente:

```powershell
# ─── Credenciais (nunca em arquivo versionado) ───────────────────────────────
$env:TF_WORKSPACE                 = "autogiro-infra-k8s-prod"
$env:TF_VAR_jwt_secret            = "<segredo HS256, o mesmo da Lambda autogiro-auth>"
$env:TF_VAR_new_relic_license_key = "<opcional: instala o agente e liga os traces>"
$env:TF_VAR_new_relic_account_id  = "<opcional: dashboards e alertas>"
$env:TF_VAR_new_relic_api_key     = "<opcional: User API key, prefixo NRAK>"
$env:TF_VAR_alert_email           = "<opcional: e-mail que recebe os alertas>"

# ─── Subir ──────────────────────────────────────────────────────────────────
aws sts get-caller-identity                      # confere as credenciais antes de gastar 20 min
terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve   # 15 a 20 min (o control plane demora)

# ─── Acesso ao cluster ──────────────────────────────────────────────────────
aws eks update-kubeconfig --name autogiro --region us-east-1
kubectl get nodes

# ─── Endereço do gateway ────────────────────────────────────────────────────
# Não há Load Balancer nesta conta: o EXTERNAL-IP do Service do Kong fica <none>
# para sempre. A entrada é o IP público de qualquer nó na porta 30080.
terraform -chdir=terraform output -raw kong_proxy_url
```

Para destruir, ver [Ao terminar de usar](#ao-terminar-de-usar).

O `Makefile` também serve para as operações do dia a dia:

```bash
make init        # inicializa o Terraform
make plan        # revisa o que será criado
make apply       # cria o cluster, o Kong, o RabbitMQ e o New Relic
make kubeconfig  # aponta o kubectl para o cluster
make status      # nós, pods e HPA
make gateway     # endereço público do Kong (IP do primeiro nó + 30080)
make kong-routes # rotas registradas no Kong, pela Admin API
make destroy     # remove TUDO, inclusive dashboards e alertas do New Relic
```

Depois do `apply`:

```bash
terraform -chdir=terraform output kong_proxy_url        # http://<ip-do-no>:30080
terraform -chdir=terraform output kong_node_ips         # IPs de todos os nós
terraform -chdir=terraform output kubeconfig_command    # comando do update-kubeconfig
terraform -chdir=terraform output cluster_endpoint      # endpoint da API do cluster
```

| Recurso | Endereço |
|---|---|
| Gateway (proxy) | `http://<ip-publico-de-um-no>:30080` — output `kong_proxy_url` |
| APIs dos serviços | `http://<ip-publico-de-um-no>:30080/api/v1/...` — ver [docs/apis-e-gateway.md](docs/apis-e-gateway.md) |
| Swagger de cada serviço | Não passa pelo Kong: `kubectl -n autogiro port-forward svc/os-service 8000:80` e `http://localhost:8000/docs` |
| Admin API do Kong | `ClusterIP`: `kubectl port-forward -n kong svc/kong-kong-admin 8001:8001` |
| Painel do RabbitMQ | `ClusterIP`: `kubectl -n autogiro port-forward svc/rabbitmq 15672:15672` |

A Admin API do Kong permite reconfigurar rotas e plugins **sem autenticação**, então fica em
`ClusterIP` de propósito: expô-la entregaria o controle do gateway para a internet.

```bash
# Rotas e plugins registrados (com o port-forward ativo)
curl -s http://localhost:8001/routes  | python -m json.tool
curl -s http://localhost:8001/plugins | python -m json.tool
```

## Deploy dos microsserviços

Este repositório entrega a plataforma vazia de aplicações. Cada microsserviço é publicado pela
própria pipeline, no job **`Deploy (EKS)`**, que roda na `main` só quando a variável
`DEPLOY_ENABLED` do repositório do serviço vale `true`:

1. `aws eks update-kubeconfig` no cluster `autogiro`.
2. Cria ou atualiza o Secret do serviço a partir dos secrets do GitHub.
3. Aponta o `kustomization.yaml` para a imagem do commit (GHCR, `amd64` e `arm64`) e roda
   `kubectl apply -k k8s/`.
4. Espera o rollout; se não terminar, desfaz com `rollout undo` e reprova a pipeline.
5. Smoke test: imagem e réplicas certas, `/health/ready` dentro do pod e `401` no Kong para
   uma rota protegida chamada sem token.

Os scripts locais ligam `DEPLOY_ENABLED` nos três repositórios ao subir o cluster (e disparam
as pipelines) e desligam ao destruir. Com o cluster desligado, o job aparece como *skipped* e
a pipeline continua verde, em vez de falhar tentando alcançar um cluster que não existe.

Os manifestos de cada serviço dependem do que este repositório cria: o namespace `autogiro`,
a `autogiro-plataforma`, o RabbitMQ e os plugins `autogiro-jwt` e `autogiro-prometheus`
referenciados nos Ingresses.

## Validação do JWT

O arquivo [`terraform/kong-jwt.tf`](terraform/kong-jwt.tf) cria três recursos que trabalham juntos:

| Recurso | Papel |
|---|---|
| `KongConsumer` | Representa a Lambda como emissora de tokens |
| `Secret` (credencial `jwt`) | Guarda o segredo HS256; o campo `key` casa com a claim `iss` (`autogiro-auth`) |
| `KongPlugin` `autogiro-jwt` | Ativa a validação de assinatura e expiração, referenciado pelos Ingresses dos serviços |

Cada microsserviço ativa o plugin no próprio `k8s/ingress.yaml`, com a annotation
`konghq.com/plugins: autogiro-jwt,autogiro-prometheus`. A única rota pública,
`GET /api/v1/service-orders/{id}/status`, fica num Ingress separado do OS Service, sem o
plugin de JWT. Sem `anonymous` configurado, requisição sem token válido recebe 401 do Kong.

Os três serviços revalidam o token com o mesmo `JWT_SECRET`, recebido pela
`autogiro-plataforma`. Rotas, emissão do token pela AWS CLI e endpoints de cada serviço estão
em [docs/apis-e-gateway.md](docs/apis-e-gateway.md).

> Corresponde às **aulas 4, 5 e 6** de API Gateway — em especial a de **Consumers**, que é o
> mecanismo por trás dessa validação.

## Observabilidade

O agente do New Relic é instalado apenas quando `new_relic_license_key` é informada, com
`lowDataMode` ativo para preservar a cota de 100 GB/mês do free tier.

Coleta: métricas de infraestrutura (CPU, memória, estado dos pods), logs do cluster, eventos do
Kubernetes (OOMKill, falhas de scheduling, restarts) e métricas Prometheus, pelo
`newrelic-prometheus-agent`, de três origens:

| Origem | Porta anunciada | O quê |
|---|---|---|
| Pods dos três serviços | `8000` · `/metrics` | Métricas `autogiro_*`: requisições, latência, exceções, transições de status, notificações, orçamentos |
| Kong | `8100` · `/metrics` | Requisições por rota e código, latência no gateway e no upstream |
| RabbitMQ | `15692` · `/metrics/per-object` | Profundidade de cada fila, inclusive das DLQs |

O agente coleta direto do pod, não pelo Service, então a porta anunciada em
`prometheus.io/port` tem de ser a do **container**. O `integrations_filter` do agente está
desligado: com ele ligado, só alvos de uma lista de integrações conhecidas são coletados, e as
métricas dos serviços seriam descartadas.

**Dashboards e alertas também são código.** Condicionados à variável `new_relic_api_key` (User
API key, prefixo `NRAK`): sem ela os recursos ficam com `count = 0`, o provider nunca é chamado
e o `terraform plan` do CI roda sem credenciais.

| Arquivo | O que cria |
|---|---|
| [`terraform/newrelic-dashboards.tf`](terraform/newrelic-dashboards.tf) | Dashboard "AutoGiro — Operação da Oficina": **4 páginas e 27 widgets** — Indicadores de negócio (8), Saúde da API (8), Infraestrutura (6) e API Gateway (Kong) (5) |
| [`terraform/newrelic-alerts.tf`](terraform/newrelic-alerts.tf) | Policy "AutoGiro — Oficina" com **5 condições de alerta** NRQL, mais destino, canal e workflow de e-mail (criados só com `alert_email` preenchido) |
| [`terraform/newrelic-saga.tf`](terraform/newrelic-saga.tf) | Dashboard "AutoGiro — Saga e rastreamento" (**2 páginas, 11 widgets**) e o alerta **Mensagem da Saga na DLQ**, na mesma policy |

As 5 condições da policy vêm das regras de Prometheus do projeto anterior e são avaliadas
sobre as métricas `autogiro_*` que os três serviços expõem:

| Condição | Métrica |
|---|---|
| API indisponível (sem healthcheck) | Perda de sinal de `autogiro_app_info` |
| Taxa de erro 5xx acima de 5% | `autogiro_http_requests_total` com `status_code` 5xx |
| Latência p95 acima do SLO (300 ms) | `autogiro_http_request_duration_seconds` |
| Falha no processamento de ordens de serviço | `autogiro_notifications_total` com falha, por canal |
| Exceções não tratadas na API | `autogiro_http_exceptions_total`, por exceção e endpoint |

### Saga e rastreamento distribuído

Os microsserviços de OS, Billing e Execution exportam traces com **OpenTelemetry** direto para o
New Relic (OTLP, `https://otlp.nr-data.net`, autenticado pela mesma license key do agente). O
endpoint chega aos serviços pelo ConfigMap `autogiro-plataforma`. O contexto do trace viaja
nas chamadas HTTP e nos cabeçalhos das mensagens do RabbitMQ, então a abertura de uma OS
aparece como **um trace só** atravessando os três serviços:
`POST /service-orders` (OS) → `ReservarPecas` (Execution) → `PecasReservadas` (OS) →
`GerarOrcamento` (Billing) → `OrcamentoGerado` (OS).

Os spans levam `autogiro.order_id`, `autogiro.saga_id`, `autogiro.message.type` e o desfecho de
cada entrega, o que permite consultar tudo de uma OS ou Saga:

```sql
SELECT * FROM Span WHERE autogiro.order_id = '42' SINCE 1 day ago
```

| Página | Widgets |
|---|---|
| Saga | Sagas iniciadas, concluídas e compensadas · compensações por motivo · mensagens processadas por tipo · retentativas e DLQ · tempo de processamento p95 por mensagem · mensagens que foram para a DLQ |
| Rastreamento | Traces das OS com quantos serviços cada um atravessou · requisições e latência p95 por serviço · spans com erro · tempo médio por dependência (banco, Mercado Pago, catálogo de peças) |

O alerta **Mensagem da Saga na DLQ** abre incidente a qualquer mensagem que esgote as tentativas,
indicando o serviço e a fila: é um comando ou evento que não foi processado e deixou uma OS parada.

Os recursos do New Relic não dependem do cluster. Para criá-los sem subir o EKS:

```powershell
terraform -chdir=terraform apply `
  -target=newrelic_one_dashboard.saga `
  -target=newrelic_nrql_alert_condition.mensagem_na_dlq
```

## CI/CD

| Gatilho | O que roda |
|---|---|
| Pull request para `main` ou `develop` | `Validate` (`fmt`, `validate`, `tflint`, `checkov`) + `Terraform Plan` |
| Push em `main` ou `develop` | O acima |
| Disparo manual (`workflow_dispatch`) com `DEPLOY_ENABLED=true` | O acima + `Deploy cluster` — `terraform apply` no workspace `-prod` |

O `plan` roda sempre contra o workspace `-prod`, onde está o state real do cluster e dos
painéis do New Relic.

O **checkov** reprova o build (`soft_fail: false`). As concessões aceitas desta arquitetura
(endpoint público do EKS, subnets com IP público, secrets sem KMS, VPC sem flow logs, SG
default) estão listadas uma a uma em `skip_check`, com o motivo registrado no workflow;
qualquer achado novo derruba a pipeline.

O job **`Terraform Plan`** substituiu o smoke test. Quando o cluster era local, o smoke test
subia um cluster inteiro a cada execução e era grátis. Com o EKS, subir e destruir a cada PR
custaria **~US$ 0,60 e 30 minutos** — então o `plan` valida a configuração contra a API real da
AWS sem provisionar recurso nenhum.

O `apply` pela pipeline existe, mas só por disparo manual e com `DEPLOY_ENABLED`, porque criar
um EKS custa dinheiro: subir o cluster é decisão explícita, nunca efeito colateral de um push.
Na rotina da entrega, o cluster é criado e destruído pelos scripts locais, no mesmo workspace
`-prod`. Um push nunca cancela uma execução em andamento fora de PR, para não cortar um
`apply` no meio.

## Ao terminar de usar

> **O cluster cobra por hora de existência, não por uso: ~US$ 0,17/h, US$ 4,13 por dia se ficar
> ligado 24h.** Destrua ao terminar a sessão.

O destroy é **direcionado**: mira a VPC e as roles IAM, e o Terraform leva junto tudo o que
depende delas (subnets, cluster, node group e todos os recursos do Kubernetes). Ficam no state
apenas os dashboards e alertas do New Relic e a senha do RabbitMQ, que não custam nada na AWS
e não precisam ser recriados a cada sessão.

```powershell
# Pods presos em Terminating travam os namespaces e, com eles, o destroy
kubectl -n autogiro delete pods --all --force --grace-period=0
kubectl -n kong delete pods --all --force --grace-period=0

terraform -chdir=terraform destroy -auto-approve `
  -target=aws_vpc.this -target=aws_iam_role.cluster -target=aws_iam_role.node

terraform -chdir=terraform state list   # deve sobrar só newrelic_* e random_password
```

O `make destroy` (ou um `terraform destroy` sem `-target`) remove **tudo**, inclusive os
dashboards e alertas do New Relic.

**Não confie só na mensagem final do destroy.** Se os namespaces travarem, ele desiste deles,
segue para a rede e falha ao apagar o Internet Gateway com os nós ainda de pé — deixando o
cluster no ar. Uma segunda passada costuma resolver, porque os nós já morreram na primeira.
Confira depois de cada destroy:

```bash
aws eks list-clusters --region us-east-1     # deve vir vazio
```

1. Instâncias EC2 — https://console.aws.amazon.com/ec2/home#Instances
2. Volumes EBS não anexados — https://console.aws.amazon.com/ec2/home#Volumes
3. Elastic IPs não associados — https://console.aws.amazon.com/ec2/home#Elastic-IPs
4. Load Balancers — https://console.aws.amazon.com/ec2/home#LoadBalancers (deve estar vazio)

Alguns recursos nascem de objetos do Kubernetes e são provisionados pelo cloud-controller da
AWS, não pelo Terraform. Nesta conta o risco é menor, porque ela não permite Load Balancer,
mas o hábito vale: numa conta sem essa restrição, um NLB esquecido custa **US$ 21/mês** sem
aparecer em lugar nenhum.

Detalhes, cenários de custo e o alarme de faturamento recomendado estão em [CUSTO.md](CUSTO.md).
