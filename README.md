# autogiro-infra-k8s

> **AutoGiro** · Repositório 2 de 4 — Tech Challenge Fase 3 (13SOAT)

Infraestrutura **Kubernetes** do AutoGiro, provisionada com Terraform: cluster, API Gateway e
observabilidade.

## Propósito

- Provisiona o cluster Kubernetes com escalabilidade via **HPA**.
- Instala o **Kong Gateway** como Ingress Controller e API Gateway, com o plugin `jwt`.
- Instala o **metrics-server**, pré-requisito do HPA.
- Instala o **agente New Relic** (infraestrutura, logs e eventos do cluster).

## Tecnologias

| Item | Tecnologia |
|---|---|
| IaC | Terraform ≥ 1.5 |
| Cluster | kind (Kubernetes 1.31) |
| API Gateway | Kong Gateway OSS 3.x (DB-less) |
| Autoscaling | metrics-server + HPA |
| Observabilidade | New Relic (nri-bundle) |
| Qualidade | tflint · checkov |
| CI/CD | GitHub Actions |

## Arquitetura

```
                        host (localhost)
                    :8000            :8001
                      │                │
   ┌──────────────────┼────────────────┼───────────────────────┐
   │ kind cluster "autogiro"                                   │
   │                  ▼                ▼                       │
   │        ┌──────────────────────────────┐                   │
   │        │  Kong Gateway (ns: kong)     │                   │
   │        │  proxy :30000  admin :30001  │                   │
   │        │  plugin jwt + KongConsumer   │                   │
   │        └───────────┬──────────────────┘                   │
   │                    │ Ingress                              │
   │        ┌───────────▼──────────────────┐                   │
   │        │  ns: autogiro                │                   │
   │        │   Deployment autogiro-api    │◄── HPA 2..10      │
   │        └──────────────────────────────┘    (CPU 70%,      │
   │                                             mem 80%)      │
   │        ┌──────────────────────────────┐                   │
   │        │  ns: newrelic                │                   │
   │        │   agente (DaemonSet + logs)  │──────────────────►│──► New Relic
   │        └──────────────────────────────┘                   │
   │        ┌──────────────────────────────┐                   │
   │        │  kube-system: metrics-server │                   │
   │        └──────────────────────────────┘                   │
   └───────────────────────────────────────────────────────────┘
```

## Por que kind e não EKS/AKS

Kubernetes gerenciado gratuito de forma confiável não existe hoje:

| Opção | Custo |
|---|---|
| AWS EKS | ~US$ 73/mês só de control plane |
| Azure AKS | control plane grátis, mas ~US$ 31/mês por nó |
| Oracle OKE | grátis, porém cortou o free tier ARM pela metade em jun/2026 e termina instâncias |

O kind é provisionado **pelo mesmo Terraform** que provisionaria um cluster gerenciado — os
manifests, o HPA, as probes e o gateway são idênticos. A decisão está registrada na RFC-001.

## Pré-requisitos

```bash
docker --version      # Docker Desktop rodando
terraform version     # >= 1.5
kubectl version --client
kind version
```

## Uso

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# preencha jwt_secret e, opcionalmente, new_relic_license_key

make init      # inicializa o Terraform
make plan      # revisa o que será criado
make apply     # cria o cluster, o Kong e o agente do New Relic
make status    # nós, pods e HPA
make destroy   # remove tudo
```

Depois do `apply`:

| Recurso | URL |
|---|---|
| Gateway (proxy) | http://localhost:8000 |
| Admin API do Kong | http://localhost:8001 |

```bash
# Rotas e plugins registrados
make kong-routes
curl -s http://localhost:8001/plugins | python -m json.tool
```

## Validação do JWT

O arquivo [`terraform/kong-jwt.tf`](terraform/kong-jwt.tf) cria três recursos que trabalham juntos:

| Recurso | Papel |
|---|---|
| `KongConsumer` | Representa a Lambda como emissora de tokens |
| `Secret` (credencial `jwt`) | Guarda o segredo HS256; o campo `key` casa com a claim `iss` |
| `KongPlugin` | Ativa a validação, referenciado pelo Ingress da aplicação |

O Ingress do [autogiro-app](../autogiro-app/) ativa o plugin com a annotation
`konghq.com/plugins: autogiro-jwt`. Rotas públicas (`/health`, `/docs`) ficam em um Ingress
separado, sem o plugin.

> Corresponde às **aulas 4, 5 e 6** de API Gateway — em especial a de **Consumers**, que é o
> mecanismo por trás dessa validação.

## Observabilidade

O agente do New Relic é instalado apenas quando `new_relic_license_key` é informada, com
`lowDataMode` ativo para preservar a cota de 100 GB/mês do free tier.

Coleta: métricas de infraestrutura (CPU, memória, estado dos pods), logs do cluster e eventos do
Kubernetes (OOMKill, falhas de scheduling, restarts).

## CI/CD

| Gatilho | O que roda |
|---|---|
| Pull request | `fmt`, `validate`, `tflint`, `checkov` |
| Push | O acima + sobe um cluster real no runner e valida Kong e metrics-server |
| Push com `DEPLOY_ENABLED=true` | `apply` no cluster real via self-hosted runner |

> O cluster roda na máquina do desenvolvedor, então o `apply` final não cabe em runner hospedado.
> A alternativa documentada é `make apply` local.
