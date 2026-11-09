# ADR-012: Kubernetes no EKS, ligado só quando necessário

- **Status:** Aceita
- **Data:** 2026-11-08
- **Decisores:** Pedro Figueira

## Contexto

O enunciado pede deploy automatizado em **ambiente Kubernetes**, sem exigir nuvem. Na fase
anterior o projeto já rodava no EKS
([RFC-001](https://github.com/Figueiraa/autogiro-app/blob/main/docs/arquitetura/rfcs/RFC-001-escolha-da-nuvem.md)),
com o Terraform deste repositório validado. Agora o cluster precisa receber mais: RabbitMQ e
três microsserviços com duas réplicas cada, além de Kong e agentes do New Relic.

O EKS cobra **por hora de existência do cluster**, não por uso (~US$ 0,17/h com a
configuração abaixo, detalhada em [CUSTO.md](../../CUSTO.md)). A conta tem US$ 133,74 de
crédito válido até 07/03/2027.

A conta tem restrições que não se resolvem por Terraform:

- **Não permite Load Balancer** (`OperationNotPermitted`).
- **Bloqueia invocação pública** da Function URL da Lambda (responde 403).
- **Está no plano gratuito da AWS**, que só lança tipos de instância elegíveis ao Free Tier.

## Decisão

**EKS, o mesmo Terraform da fase anterior, ampliado** com o RabbitMQ
([`terraform/rabbitmq.tf`](../../terraform/rabbitmq.tf)) e a configuração compartilhada dos
serviços `autogiro-plataforma` ([`terraform/plataforma.tf`](../../terraform/plataforma.tf)).
Os bancos ficam fora do cluster (Neon para OS e Billing, MongoDB Atlas para Execution), para
sobreviverem à destruição dele.

**Kubernetes 1.35, com `upgrade_policy { support_type = "STANDARD" }`.** Uma versão que sai do
suporte padrão entra no suporte estendido, cobrado a **US$ 0,60/h** pelo control plane em vez
de US$ 0,10/h, sem aviso. O 1.31 usado na fase anterior já estava nessa situação. A 1.35 tem
suporte padrão até 27/03/2027, e com `STANDARD` a AWS atualiza a versão em vez de passar a
cobrar a mais.

**Três nós `t4g.small` (Graviton/ARM).** O plano gratuito recusa a `t4g.medium`: o node group
falha com `InvalidParameterCombination` depois de cerca de 40 minutos tentando. A `t4g.small`
é elegível, mas aceita só **11 pods por nó** (limite de IPs por interface da VPC CNI). Com
Kong, agentes do New Relic, metrics-server, RabbitMQ e três serviços com duas réplicas, dois
nós não comportam; o node group sobe com mínimo 3 e máximo 4, e o teto dá espaço para o HPA
agendar réplicas extras. As imagens dos serviços são publicadas para `amd64` e `arm64`.

**Kong em `NodePort` 30080**, exposto no IP público dos nós, porque não há Load Balancer.

**Ligado só quando necessário.** O desenvolvimento é local, com `docker-compose`; o cluster
sobe para validar a integração, para as demonstrações de deploy e para a gravação do vídeo, e
é destruído ao fim de cada sessão.

**State no HCP Terraform, workspace `autogiro-infra-k8s-prod`.** É nele que o cluster é
criado e destruído. Os scripts locais `subir-cluster.ps1` e `destruir-cluster.ps1` fazem a
rotina; ficam fora do git porque carregam credenciais.

**Deploy contínuo pelos runners hospedados do GitHub.** Cada microsserviço tem o job
`Deploy (EKS)` na própria pipeline, condicionado à variável `DEPLOY_ENABLED` do repositório.
Os scripts ligam a variável ao subir o cluster (e disparam as pipelines) e desligam ao
destruir. Sem isso a pipeline ficaria "verde sem deployar" quando o cluster não existe, ou
falharia tentando alcançá-lo.

**Destroy direcionado, que preserva o New Relic.** Dashboards e alertas também estão neste
Terraform, mas não dependem do cluster. Destruir tudo apagaria os painéis e o histórico de
configuração a cada sessão. O destroy mira a VPC e as roles IAM, e o Terraform leva junto tudo
o que depende delas (subnets, cluster, node group, recursos do Kubernetes):

```powershell
terraform -chdir=terraform destroy `
  -target=aws_vpc.this -target=aws_iam_role.cluster -target=aws_iam_role.node
```

Sobram no state só os recursos do New Relic e a senha do RabbitMQ (`random_password`), que
não custam nada na AWS.

## Consequências

**Positivas**

- Continuidade com a fase anterior: a mesma rede, o mesmo gateway e a mesma rotina.
- Nenhum runner self-hosted em repositório público.
- Custo coberto pelo crédito: algumas sessões de poucas horas somam poucos dólares.
- Painéis e alertas do New Relic sobrevivem entre sessões.

**Negativas**

- 15 a 20 minutos para subir o cluster a cada sessão.
- O IP público do Kong muda a cada sessão, e não há DNS estável. Por isso o Billing confirma
  o pagamento consultando o Mercado Pago, em vez de esperar um webhook.
- Sem Load Balancer não há balanceamento entre nós: o cliente aponta para um IP específico.
- O terceiro nó encarece o cluster em relação a dois nós maiores, que a conta não aceita.
- O `destroy` pode falhar em silêncio: pods presos em `Terminating` travam os namespaces, o
  destroy desiste deles e segue para a rede, que falha porque os nós ainda existem. Os scripts
  forçam a remoção dos pods antes, repetem o destroy e conferem o que sobrou na AWS; o state
  precisa ser conferido depois de cada destruição.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| kind local + runner self-hosted | Custo zero sem depender de crédito, mas com runner self-hosted em repositório público e o PC ligado para o deploy. Fica como plano B se o crédito acabar |
| Oracle OKE gratuito | Descartado na fase anterior: corte do plano ARM e terminação de instâncias sem aviso |
| EKS ligado o tempo todo | ~US$ 4/dia sem necessidade |
| Dois nós `t4g.medium` | Recusados pelo plano gratuito da conta |
| Manter o Kubernetes 1.31 | Suporte estendido: control plane seis vezes mais caro |
| Destroy completo (`terraform destroy`) | Apagaria dashboards e alertas do New Relic a cada sessão |
