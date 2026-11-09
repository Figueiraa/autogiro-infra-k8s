# APIs e API Gateway

O **Kong** é a porta de entrada única dos três microsserviços. O cliente usa uma URL base só,
o endereço do Kong, e não precisa saber qual serviço atende cada rota: os prefixos não se
sobrepõem, e o gateway encaminha pelo recurso.

Este documento descreve o que está publicado no gateway, como o token é validado e como
obtê-lo. As rotas foram conferidas nos `k8s/ingress.yaml` e nos controllers de cada serviço.

## Ponto de entrada

```
http://<ip-publico-de-qualquer-no>:30080
```

**Não há Load Balancer.** A conta AWS responde `OperationNotPermitted: This AWS account
currently does not support creating load balancers` a qualquer tentativa, então o proxy do
Kong é um Service `NodePort` na porta fixa **30080** (`proxy.type: NodePort` em
[`terraform/main.tf`](../terraform/main.tf)). Os nós ficam em subnet pública, com IP próprio,
e o security group libera a 30080 para a internet ([`terraform/eks.tf`](../terraform/eks.tf)).

O que se perde em relação a um NLB é o DNS estável e o balanceamento entre nós; o roteamento,
os plugins e a validação do JWT são os mesmos. O IP muda a cada vez que o cluster sobe:

```bash
terraform -chdir=terraform output -raw kong_proxy_url   # http://<ip-do-primeiro-no>:30080
terraform -chdir=terraform output kong_node_ips         # qualquer um atende
make gateway                                            # o mesmo, lido do kubectl
```

## Rotas no Kong

Cada serviço publica as próprias rotas com um `Ingress` no seu repositório
(`k8s/ingress.yaml`), aplicado pela pipeline dele. Este repositório cria só os plugins que
esses Ingresses referenciam.

| Serviço | Ingress | Rotas (`pathType: Prefix`) | Plugins |
|---|---|---|---|
| [OS Service](https://github.com/Figueiraa/autogiro-os-service/blob/main/k8s/ingress.yaml) | `os-service` | `/api/v1/clients` · `/api/v1/vehicles` · `/api/v1/service-types` · `/api/v1/service-orders` | `autogiro-jwt`, `autogiro-prometheus` |
| [OS Service](https://github.com/Figueiraa/autogiro-os-service/blob/main/k8s/ingress.yaml) | `os-service-publico` | `GET /api/v1/service-orders/{id}/status`, por regex | `autogiro-prometheus` (**sem JWT**) |
| [Execution Service](https://github.com/Figueiraa/autogiro-execution-service/blob/main/k8s/ingress.yaml) | `execution-service` | `/api/v1/parts` · `/api/v1/executions` | `autogiro-jwt`, `autogiro-prometheus` |
| [Billing Service](https://github.com/Figueiraa/autogiro-billing-service/blob/main/k8s/ingress.yaml) | `billing-service` | `/api/v1/budgets` · `/api/v1/payments` | `autogiro-jwt`, `autogiro-prometheus` |

Detalhes que valem para todos:

- **`konghq.com/strip-path: "false"`.** O caminho chega inteiro ao serviço, que serve as rotas
  sob `/api/v1`.
- **Plugins por annotation** (`konghq.com/plugins`). O label `global: "true"` foi depreciado
  nas versões recentes do ingress controller e é ignorado sem aviso: o plugin fica criado no
  Kubernetes e nunca chega ao Kong.
- **A rota pública é uma só.** O Ingress `os-service-publico` usa o caminho
  `/~/api/v1/service-orders/\d+/status$` (o prefixo `/~` marca regex no Kong) com
  `konghq.com/regex-priority: "100"`, para ser avaliado antes do prefixo protegido. Só o
  acompanhamento da OS fica aberto; o resto de `/api/v1/service-orders` continua exigindo token.

| Plugin | Arquivo | O que faz |
|---|---|---|
| `autogiro-jwt` | [`terraform/kong-jwt.tf`](../terraform/kong-jwt.tf) | Valida o JWT emitido pela Lambda antes de encaminhar |
| `autogiro-prometheus` | [`terraform/kong-metrics.tf`](../terraform/kong-metrics.tf) | Contadores por rota e código HTTP e latência separada entre Kong e upstream, coletados pelo agente do New Relic. Mede inclusive o que o gateway barrou, que nunca chega ao serviço |

## Validação do JWT

O token é validado **duas vezes**: no Kong, antes de rotear, e de novo em cada serviço.

### No Kong

[`terraform/kong-jwt.tf`](../terraform/kong-jwt.tf) cria três recursos no namespace
`autogiro`:

| Recurso | Papel |
|---|---|
| `KongConsumer` `autogiro-auth` | Representa a Lambda como emissora de tokens |
| `Secret` `autogiro-jwt-credential` (label `konghq.com/credential: jwt`) | Credencial do Consumer: `key = autogiro-auth`, `secret` = segredo HS256, `algorithm = HS256` |
| `KongPlugin` `autogiro-jwt` | Plugin `jwt` com `key_claim_name: iss`, `claims_to_verify: [exp]` e token lido do cabeçalho `Authorization` |

O Kong lê a claim `iss` do token e procura a credencial cujo `key` tenha o mesmo valor. É
assim que ele descobre qual segredo usar para conferir a assinatura: um token com outro
emissor não encontra credencial e é recusado. Depois confere a assinatura HS256 e a
expiração (`exp`).

Sem `anonymous` configurado, requisição sem token válido recebe **401 do próprio Kong**
(`{"message":"Unauthorized"}`) e não chega ao serviço.

A Lambda e o Kong não se conhecem: o contrato entre eles é o segredo HS256 e a claim `iss`
(decisão registrada no
[ADR-004](https://github.com/Figueiraa/autogiro-app/blob/main/docs/arquitetura/adrs/ADR-004-emissor-desacoplado-do-validador.md)).

### Nos serviços

Os três serviços recebem o mesmo segredo pela configuração compartilhada
`autogiro-plataforma` ([`terraform/plataforma.tf`](../terraform/plataforma.tf)), lida pelos
Deployments com `envFrom`. Cada um revalida assinatura, expiração e emissor, exigindo as
claims `sub`, `exp` e `iss` (`iss = autogiro-auth`). Token inválido ou ausente devolve
`401 Token inválido ou expirado`.

A revalidação existe porque nem toda chamada passa pelo Kong. Ao abrir uma OS, o OS Service
consulta `GET /api/v1/parts/{id}` no Execution Service direto pelo DNS do cluster
(`http://execution-service.autogiro.svc.cluster.local`), **repassando o token de quem abriu a
OS**; o Execution valida esse token como validaria qualquer outro. A consulta tem timeout de
2 s: peça inexistente devolve `422` na hora, e se o Execution não responder a OS é aberta
mesmo assim e a validação fica com a Saga.

### Conteúdo do token

```json
{
  "sub": "44232322191",
  "client_id": 1,
  "name": "Maria Oliveira",
  "iss": "autogiro-auth",
  "iat": 1757180000,
  "exp": 1757183600
}
```

`sub` carrega o CPF do cliente. A validade padrão é de 60 minutos.

## Como obter o token

O token é emitido pela Lambda
[`autogiro-auth`](https://github.com/Figueiraa/autogiro-auth/blob/main/README.md) a partir de
um CPF, consultando os clientes do OS Service.

**A Function URL não serve nesta conta.** Ela está configurada corretamente
(`authorization_type = NONE` e resource policy pública), mas responde **403** a `POST` e
`GET` antes de executar a função: a conta bloqueia invocação pública, a mesma família de
restrição que impede Load Balancers. Por isso o token é emitido pela **AWS CLI**, com
`aws lambda invoke`.

O handler espera o formato de evento do API Gateway: o JSON com o CPF vai **dentro de
`body`, como string**. Enviar `{"cpf": "..."}` na raiz devolve
`400 O campo 'cpf' é obrigatório`, porque o CPF fica fora de onde o handler procura.

Bash:

```bash
echo -n '{"body":"{\"cpf\":\"44232322191\"}"}' > payload.json

aws lambda invoke --function-name autogiro-auth-prod --region us-east-1 \
  --payload fileb://payload.json resposta.json

# A resposta é o evento HTTP da Lambda; o token está dentro de `body`, também como string
TOKEN=$(python -c "import json; print(json.loads(json.load(open('resposta.json'))['body'])['access_token'])")
```

PowerShell (aspas simples são literais, então o JSON vai como é, sem escapar as barras):

```powershell
$payload = '{"body":"{\"cpf\":\"44232322191\"}"}'

aws lambda invoke --function-name autogiro-auth-prod --region us-east-1 `
  --cli-binary-format raw-in-base64-out --payload $payload resposta.json

$token = ((Get-Content resposta.json -Raw | ConvertFrom-Json).body | ConvertFrom-Json).access_token
```

Respostas da Lambda (o código HTTP fica em `statusCode`, dentro de `resposta.json`):

| Situação | `statusCode` | Corpo |
|---|---|---|
| Token emitido | `200` | `access_token`, `token_type: bearer`, `expires_in: 3600` |
| Campo `cpf` ausente | `400` | `O campo 'cpf' é obrigatório` |
| CPF inválido **ou** não cadastrado | `401` | `CPF inválido ou não cadastrado` |
| Cliente inativo | `403` | `Cadastro inativo. Procure a oficina.` |
| Banco indisponível | `503` | `Serviço temporariamente indisponível` |

Os dados de demonstração do OS Service trazem clientes prontos para testar: `44232322191`
(Maria Oliveira, ativa) e `94789277879` (Transportes Lima ME, inativo, para o `403`).

## Testando pelo gateway

```bash
GATEWAY=$(terraform -chdir=terraform output -raw kong_proxy_url)

# Sem token: 401 respondido pelo Kong
curl -s -w ' HTTP %{http_code}\n' "$GATEWAY/api/v1/service-orders"

# Rota pública: acompanhamento da OS, sem token
curl -s "$GATEWAY/api/v1/service-orders/1/status"

# Com token
curl -s -H "Authorization: Bearer $TOKEN" "$GATEWAY/api/v1/service-orders"
```

No PowerShell, chame `curl.exe` (e não o alias `curl`) e use `-o NUL` em vez de
`-o /dev/null`.

A coleção Postman
[`autogiro-fluxo-completo`](https://github.com/Figueiraa/autogiro-os-service/blob/main/docs/postman/autogiro-fluxo-completo.postman_collection.json)
percorre a OS pelos três serviços. Na nuvem, as variáveis `os_url`, `execution_url` e
`billing_url` recebem o mesmo endereço do Kong, e `token` recebe o JWT emitido acima.

## Endpoints por serviço

Todos sob `/api/v1`. Exceto o acompanhamento público da OS, todos exigem
`Authorization: Bearer <token>`, no Kong e no serviço.

### OS Service

| Método | Rota | Descrição |
|---|---|---|
| `GET` `POST` | `/clients` | Listar e criar clientes |
| `GET` `PATCH` `DELETE` | `/clients/{client_id}` | Detalhar, alterar, remover |
| `GET` `POST` | `/vehicles` | Listar e criar veículos |
| `GET` | `/vehicles/client/{client_id}` | Veículos de um cliente |
| `GET` `PATCH` `DELETE` | `/vehicles/{vehicle_id}` | Detalhar, alterar, remover |
| `GET` `POST` | `/service-types` | Catálogo de serviços |
| `GET` `PATCH` `DELETE` | `/service-types/{service_type_id}` | Detalhar, alterar, remover |
| `POST` | `/service-orders` | Abre a OS e inicia a Saga (`201`) |
| `GET` | `/service-orders` | OS ativas, ordenadas pelo que exige ação da oficina primeiro |
| `GET` | `/service-orders/metrics/average-execution-time` | Tempo médio de execução |
| `GET` | `/service-orders/{order_id}` | Detalhe da OS |
| `GET` | `/service-orders/{order_id}/history` | Histórico de mudanças de status |
| `GET` | `/service-orders/{order_id}/saga` | Estado da Saga da OS |
| `POST` | `/service-orders/{order_id}/deliver` | Registra a entrega do veículo |
| `GET` | `/service-orders/{order_id}/status` | **Pública.** Número e status da OS, para o cliente acompanhar |

### Execution Service

| Método | Rota | Descrição |
|---|---|---|
| `GET` `POST` | `/parts` | Listar e criar peças (`201` na criação) |
| `GET` `PATCH` `DELETE` | `/parts/{part_id}` | Detalhar, alterar, remover |
| `POST` | `/parts/{part_id}/stock` | Entrada ou ajuste de estoque |
| `GET` | `/executions` | Fila de execução |
| `GET` | `/executions/{order_id}` | Execução de uma OS |
| `POST` | `/executions/{order_id}/diagnosis` | Inicia o diagnóstico |
| `POST` | `/executions/{order_id}/repair` | Inicia o reparo |
| `POST` | `/executions/{order_id}/finish` | Finaliza o serviço |
| `POST` | `/executions/{order_id}/cancel` | Cancela a execução |

### Billing Service

| Método | Rota | Descrição |
|---|---|---|
| `GET` | `/budgets/{order_id}` | Orçamento da OS |
| `POST` | `/budgets/{order_id}/approve` | Aprova o orçamento e devolve o link de pagamento do Mercado Pago |
| `POST` | `/budgets/{order_id}/reject` | Recusa o orçamento |
| `GET` | `/payments/{order_id}` | Situação do pagamento |
| `POST` | `/payments/{order_id}/sync` | Consulta o Mercado Pago na hora, sem esperar o ciclo de 15 s |

O pagamento é confirmado por **consulta** ao Mercado Pago, e não por webhook: como o
endereço do Kong muda a cada vez que o cluster sobe, não há URL estável para receber
notificações.

O contrato completo de cada serviço (corpos, códigos de resposta, exemplos) está no Swagger
dele.

### Rotas que não passam pelo Kong

Nenhum Ingress publica estas rotas; elas existem em todos os serviços e servem ao cluster:

| Rota | Uso |
|---|---|
| `/health`, `/health/live`, `/health/ready` | Sondas do Kubernetes. A `ready` confere banco e broker |
| `/metrics` | Scrape Prometheus pelo agente do New Relic, direto no pod (porta 8000) |
| `/docs`, `/openapi.json` | Swagger do serviço |

Para abrir o Swagger de um serviço no cluster:

```bash
kubectl -n autogiro port-forward svc/os-service 8000:80
# http://localhost:8000/docs
```

Troque `os-service` por `billing-service` ou `execution-service` para os outros dois.
