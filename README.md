# autogiro-infra-k8s

> **AutoGiro** · Repositório 2 de 4 — Tech Challenge Fase 3 (13SOAT)

Infraestrutura **Kubernetes** do AutoGiro, provisionada com Terraform: cluster, API Gateway e
observabilidade.

## Propósito

- Provisiona o cluster Kubernetes com escalabilidade via **HPA**.
- Instala o **Kong Gateway** como Ingress Controller e API Gateway, com o plugin `jwt`.
- Instala o **metrics-server**, pré-requisito do HPA.
- Instala o **agente New Relic** (infraestrutura, logs e eventos do cluster).
- Cria **dashboards e alertas do New Relic como código**.

## Tecnologias

| Item | Tecnologia |
|---|---|
| IaC | Terraform ≥ 1.5 · state no HCP Terraform |
| Cluster | Amazon EKS gerenciado (Kubernetes 1.31) |
| Nós | Node group gerenciado · 2× `t4g.small` (Graviton/ARM) |
| Provider de nuvem | `hashicorp/aws` ~> 5.70 |
| API Gateway | Kong Gateway OSS 3.x (DB-less), chart 2.46.0 |
| Autoscaling | metrics-server 3.12.2 + HPA |
| Observabilidade | New Relic (nri-bundle 5.0.100) · provider `newrelic/newrelic` ~> 3.30 |
| Qualidade | tflint · checkov |
| CI/CD | GitHub Actions |

## Arquitetura

```
                          internet
                              │
                              │ http://<ip-publico-do-no>:30080
                              ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │ AWS · us-east-1                                                      │
   │                                                                      │
   │   ┌────────────────────────────────────────────────────────────────┐ │
   │   │ VPC 10.0.0.0/16  (DNS support + hostnames)                     │ │
   │   │                                                                │ │
   │   │   Internet Gateway ──► route table pública (0.0.0.0/0)         │ │
   │   │                                                                │ │
   │   │   ┌──────────────────────┐    ┌──────────────────────┐         │ │
   │   │   │ subnet 10.0.0.0/24   │    │ subnet 10.0.1.0/24   │         │ │
   │   │   │ AZ us-east-1a        │    │ AZ us-east-1b        │         │ │
   │   │   │ pública (map IP)     │    │ pública (map IP)     │         │ │
   │   │   │ SG: 30080 aberta     │    │ SG: 30080 aberta     │         │ │
   │   │   │ nós com IP público   │    │ nós com IP público   │         │ │
   │   │   └──────────┬───────────┘    └──────────┬───────────┘         │ │
   │   │              │                           │                     │ │
   │   │              │   (sem Load Balancer:     │                     │ │
   │   │              │    a conta não permite)   │                     │ │
   │   │   ┌──────────▼───────────────────────────▼───────────┐         │ │
   │   │   │ EKS control plane "autogiro" (endpoint público)  │         │ │
   │   │   │ logs do cluster desabilitados                   │         │ │
   │   │   └──────────┬──────────────────────────────────────-┘         │ │
   │   │              │                                                │ │
   │   │   ┌──────────▼─────────────────────────────────────────────┐   │ │
   │   │   │ node group "autogiro-nodes"                            │   │ │
   │   │   │ 2× t4g.small · AL2023_ARM_64_STANDARD · EBS 20 GB      │   │ │
   │   │   │ ON_DEMAND · min 2 / desired 2 / max 4                  │   │ │
   │   │   │                                                        │   │ │
   │   │   │  ┌──────────────────────────────────────────┐          │   │ │
   │   │   │  │ ns: kong                                 │          │   │ │
   │   │   │  │  kong-kong-proxy  Service NodePort 30080 │◄─ tráfego│   │ │
   │   │   │  │  kong-kong-admin  Service ClusterIP      │          │   │ │
   │   │   │  │  plugin jwt + KongConsumer               │          │   │ │
   │   │   │  └──────────────┬───────────────────────────┘          │   │ │
   │   │   │                 │ Ingress                              │   │ │
   │   │   │  ┌──────────────▼───────────────────────────┐          │   │ │
   │   │   │  │ ns: autogiro                             │          │   │ │
   │   │   │  │  Deployment autogiro-api                 │◄─ HPA    │   │ │
   │   │   │  └──────────────────────────────────────────┘  2..10   │   │ │
   │   │   │                                             (CPU 70%,  │   │ │
   │   │   │                                              mem 80%)  │   │ │
   │   │   │  ┌──────────────────────────────────────────┐          │   │ │
   │   │   │  │ ns: newrelic                             │          │   │ │
   │   │   │  │  nri-bundle (DaemonSet + logs + eventos) │──────────┼───┼─┼──► New Relic
   │   │   │  │  newrelic-prometheus-agent               │          │   │ │
   │   │   │  └──────────────────────────────────────────┘          │   │ │
   │   │   │  ┌──────────────────────────────────────────┐          │   │ │
   │   │   │  │ kube-system: metrics-server              │          │   │ │
   │   │   │  └──────────────────────────────────────────┘          │   │ │
   │   │   └────────────────────────────────────────────────────────┘   │ │
   │   └────────────────────────────────────────────────────────────────┘ │
   └──────────────────────────────────────────────────────────────────────┘
```

Sem NAT Gateway: os nós ficam em subnet pública com IP público automático e saem para a
internet (registry de imagens, endpoint do EKS, ingestão do New Relic) pelo Internet Gateway.
Duas AZs porque o EKS recusa criar o control plane com menos que isso.

## Por que EKS

O enunciado lista "Cluster Kubernetes com escalabilidade" dentro de **Infraestrutura
obrigatória (livre escolha de nuvem)**. O parêntese responde *qual* nuvem, não *se* nuvem — um
cluster local não atenderia ao requisito.

O projeto começou com um cluster **local** por restrição de custo, e migrou para o EKS quando
ficou claro que essa escolha feria o requisito. Os manifests, o HPA, as probes e o gateway
continuaram os mesmos; mudou o substrato.

O custo é controlado pela rotina de **subir e destruir**: o EKS cobra por hora de existência do
cluster, não por uso, e o total fica em **~US$ 0,15/h** — poucos dólares ao longo da entrega.
A tabela completa, os cenários de uso e o checklist pós-`destroy` estão em [CUSTO.md](CUSTO.md).

Decisões de economia, todas registradas no ponto onde são feitas:

| Decisão | Motivo | Onde |
|---|---|---|
| **Sem NAT Gateway** — nós em subnet pública | O NAT custa ~US$ 0,045/h mais tráfego processado; o Internet Gateway não tem custo por hora | `terraform/eks.tf` |
| **Logs do control plane desabilitados** (`enabled_cluster_log_types = []`) | Cada tipo vira um log group no CloudWatch, cobrado por GB ingerido e armazenado; a observabilidade vem do New Relic, de dentro do cluster | `terraform/eks.tf` |
| **`t4g.small` (Graviton/ARM)** | ~US$ 0,0168/h contra ~US$ 0,0208/h da `t3.small` x86 — perto de 20% a menos. Exigiu build **multi-arch** (arm64) da imagem da aplicação e AMI `AL2023_ARM_64_STANDARD` nos nós | `terraform/eks.tf` |
| **NodePort em vez de Load Balancer** | Não foi escolha: a conta responde `OperationNotPermitted` a qualquer Load Balancer. Perde-se o DNS estável e o balanceamento entre nós; o roteamento, os plugins e a validação de JWT são idênticos. De quebra, economiza os US$ 0,031/h do NLB | `terraform/main.tf` |
| **Recursos nativos `aws_eks_*`** em vez do módulo `terraform-aws-modules/eks` | O módulo cria por padrão subnets privadas com NAT Gateway, KMS próprio e log groups no CloudWatch — tudo cobrado à parte | `terraform/eks.tf` |
| **Pixie desabilitado** no nri-bundle | Exige mais recursos do que os nós `t4g.small` comportam e o eBPF elevaria o volume ingerido acima da cota gratuita | `terraform/main.tf` |

**Honestamente: em produção isso seria diferente.** Os nós ficariam em subnets privadas, com NAT
Gateway (ou VPC endpoints) para a saída, e apenas o Load Balancer viveria na subnet pública. Os
logs do control plane estariam habilitados. Aqui a exposição é mitigada pelo security group do
node group, gerenciado pelo próprio EKS, que não abre portas para `0.0.0.0/0`.

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
workspace escolhido em tempo de execução via `TF_WORKSPACE`
(`autogiro-infra-k8s-homolog` ou `-prod`). Autenticação por `terraform login` na máquina ou
`TF_TOKEN_app_terraform_io` no ambiente.

## Uso

Os scripts `subir-cluster.ps1` e `destruir-cluster.ps1` automatizam a rotina, mas **estão no
`.gitignore`** porque carregam as credenciais preenchidas. Crie-os localmente a partir do
exemplo, ou rode os comandos equivalentes exportando as variáveis de ambiente:

```powershell
# ─── Credenciais (nunca em arquivo versionado) ───────────────────────────────
$env:TF_WORKSPACE                 = "autogiro-infra-k8s-homolog"
$env:TF_VAR_jwt_secret            = "<segredo HS256, o mesmo de autogiro-auth e autogiro-app>"
$env:TF_VAR_new_relic_license_key = "<opcional: instala o agente>"
$env:TF_VAR_new_relic_account_id  = "<opcional: dashboards e alertas>"
$env:TF_VAR_new_relic_api_key     = "<opcional: User API key, prefixo NRAK>"

# ─── Subir ──────────────────────────────────────────────────────────────────
aws sts get-caller-identity                      # confere as credenciais antes de gastar 20 min
terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve   # 15 a 20 min (o control plane demora)

# ─── Acesso ao cluster ──────────────────────────────────────────────────────
aws eks update-kubeconfig --name autogiro --region us-east-1
kubectl get nodes

# ─── Endereço do gateway ────────────────────────────────────────────────────
# Não há Load Balancer nesta conta, então o EXTERNAL-IP do Service fica <none>
# permanentemente — não espere por ele. A entrada é o IP público de qualquer nó
# na porta 30080, e os dois nós atendem.
kubectl -n kong get svc -w

# ─── Destruir ao terminar ───────────────────────────────────────────────────
kubectl -n kong delete svc --all --timeout=120s  # remove os Services antes do cluster
kubectl -n autogiro delete svc --all --timeout=120s
# aguarde ~60s a AWS apagar o balanceador
terraform -chdir=terraform destroy -auto-approve
```

O `Makefile` também serve para as operações do dia a dia:

```bash
make init      # inicializa o Terraform
make plan      # revisa o que será criado
make apply     # cria o cluster, o Kong e o agente do New Relic
make status    # nós, pods e HPA
make destroy   # remove tudo
```

Depois do `apply`:

```bash
terraform -chdir=terraform output kong_proxy_url        # http://<ip-do-no>:30080
terraform -chdir=terraform output kubeconfig_command    # comando do update-kubeconfig
terraform -chdir=terraform output cluster_endpoint      # endpoint da API do cluster
```

| Recurso | Endereço |
|---|---|
| Gateway (proxy) | `http://<ip-publico-do-no>:30080` — output `kong_proxy_url` |
| Swagger da API | `http://<ip-publico-do-no>:30080/docs` — servido pela aplicação, através do gateway |
| OpenAPI JSON | `http://<ip-publico-do-no>:30080/openapi.json` |
| Admin API do Kong | `ClusterIP`; acesse por `kubectl port-forward -n kong svc/kong-kong-admin 8001:8001` |

O gateway é o caminho público das APIs, mas o contrato delas pertence à aplicação: a
especificação OpenAPI e a coleção Postman com as 21 requisições estão em
[autogiro-app](https://github.com/Figueiraa/autogiro-app#documentação-da-api). Trocando
`localhost:8000` pelo endereço acima na variável `gateway` da coleção, as mesmas requisições
passam a exercitar o cluster.

A Admin API do Kong permite reconfigurar rotas e plugins **sem autenticação**, então fica em
`ClusterIP` de propósito: expô-la em LoadBalancer entregaria o controle do gateway para a
internet.

```bash
# Rotas e plugins registrados (com o port-forward ativo)
curl -s http://localhost:8001/routes  | python -m json.tool
curl -s http://localhost:8001/plugins | python -m json.tool
```

## Validação do JWT

O arquivo [`terraform/kong-jwt.tf`](terraform/kong-jwt.tf) cria três recursos que trabalham juntos:

| Recurso | Papel |
|---|---|
| `KongConsumer` | Representa a Lambda como emissora de tokens |
| `Secret` (credencial `jwt`) | Guarda o segredo HS256; o campo `key` casa com a claim `iss` |
| `KongPlugin` | Ativa a validação, referenciado pelo Ingress da aplicação |

O Ingress do [autogiro-app](https://github.com/Figueiraa/autogiro-app) ativa o plugin com a annotation
`konghq.com/plugins: autogiro-jwt`. Rotas públicas (`/health`, `/docs`) ficam em um Ingress
separado, sem o plugin. Sem `anonymous` configurado, requisição sem token válido recebe 401.

> Corresponde às **aulas 4, 5 e 6** de API Gateway — em especial a de **Consumers**, que é o
> mecanismo por trás dessa validação.

## Observabilidade

O agente do New Relic é instalado apenas quando `new_relic_license_key` é informada, com
`lowDataMode` ativo para preservar a cota de 100 GB/mês do free tier.

Coleta: métricas de infraestrutura (CPU, memória, estado dos pods), logs do cluster, eventos do
Kubernetes (OOMKill, falhas de scheduling, restarts) e as métricas Prometheus expostas pela
aplicação em `/metrics`, via `newrelic-prometheus-agent`.

**Dashboards e alertas também são código.** Condicionados à variável `new_relic_api_key` (User
API key, prefixo `NRAK`): sem ela os recursos ficam com `count = 0`, o provider nunca é chamado
e o `terraform plan` do CI roda sem credenciais.

| Arquivo | O que cria |
|---|---|
| [`terraform/newrelic-dashboards.tf`](terraform/newrelic-dashboards.tf) | Dashboard "AutoGiro — Operação da Oficina": **4 páginas e 27 widgets** — Indicadores de negócio (8), Saúde da API (8) e Infraestrutura (6) |
| [`terraform/newrelic-alerts.tf`](terraform/newrelic-alerts.tf) | Policy "AutoGiro — Oficina" com **5 condições de alerta** NRQL, mais destino, canal e workflow de e-mail (`alert_email`) |

As 5 condições espelham as regras de Prometheus já definidas em
`autogiro-app/monitoring/prometheus/rules/alerts.yml`:

| Condição | Espelha |
|---|---|
| API indisponível (sem healthcheck) | `up{job="autogiro-api"} == 0`, por perda de sinal |
| Taxa de erro 5xx acima de 5% | `TaxaDeErro5xxAlta` |
| Latência p95 acima do SLO (300 ms) | `LatenciaP95Degradada` |
| Falha no processamento de ordens de serviço | `FalhaNoEnvioDeNotificacoes` |
| Exceções não tratadas na API | `ExcecoesNaoTratadas` |

## CI/CD

| Gatilho | O que roda |
|---|---|
| Pull request | `fmt`, `validate`, `tflint`, `checkov` + `Terraform Plan` |
| Push | O acima |
| Push com `DEPLOY_ENABLED=true` | `Deploy cluster` — `terraform apply` na AWS |

O job **`Terraform Plan`** substituiu o smoke test. Quando o cluster era local, o smoke test
subia um cluster inteiro a cada execução e era grátis. Com o EKS, subir e destruir a cada PR
custaria **~US$ 0,60 e 30 minutos** — então o `plan` valida a configuração contra a API real da
AWS sem provisionar recurso nenhum.

O deploy **deixou de exigir self-hosted runner**: com o cluster na nuvem, o runner hospedado do
GitHub alcança a AWS normalmente. O `apply` continua protegido pela variável `DEPLOY_ENABLED`,
porque criar um EKS custa dinheiro — subir o cluster é decisão explícita, não efeito colateral
de um push.

O workspace do HCP é escolhido pelo branch: `main` → `-prod`, qualquer outro → `-homolog`.

## Ao terminar de usar

> **O cluster cobra por hora de existência, não por uso: ~US$ 0,15/h, US$ 3,55 por dia se ficar
> ligado 24h.** Destrua ao terminar a sessão.

```powershell
kubectl -n kong delete svc --all --timeout=120s   # 1. remove os Services
# 2. aguarde ~60s a AWS reagir
terraform -chdir=terraform destroy -auto-approve  # 3. destrói o resto
```

A ordem importa: alguns recursos nascem de objetos do Kubernetes e são provisionados pelo
cloud-controller da AWS, não pelo Terraform. Se o cluster morre antes deles, sobram órfãos
cobrando em silêncio.

Nesta conta o risco é menor, porque ela não permite Load Balancer — o Kong roda com
`proxy.type: NodePort`. Mas o hábito vale: numa conta sem essa restrição, um NLB esquecido
custa **US$ 21/mês** sem aparecer em lugar nenhum.

Confira depois de cada `destroy`:

1. Volumes EBS não anexados — https://console.aws.amazon.com/ec2/home#Volumes
2. Load Balancers — https://console.aws.amazon.com/ec2/home#LoadBalancers (deve estar vazio)
3. Elastic IPs não associados — https://console.aws.amazon.com/ec2/home#Elastic-IPs

Detalhes, cenários de custo e o alarme de faturamento recomendado estão em [CUSTO.md](CUSTO.md).
