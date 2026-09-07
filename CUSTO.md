# Controle de custo do cluster

> O EKS cobra **por hora de existência do cluster**, não por uso. Subir só quando for
> trabalhar e destruir ao terminar reduz o custo a alguns dólares.

## Quanto custa

| Recurso | US$/h |
|---|---|
| Control plane EKS | 0,100 |
| 2× t4g.small (Graviton) | 0,034 |
| NLB do Kong | 0,031 |
| EBS 2×20 GB gp3 | 0,004 |
| IPs públicos dos nós | 0,010 |
| **Total** | **~0,178** |

**US$ 4,28 por dia** se ficar ligado 24h.

## Cenários reais

| Uso | Custo |
|---|---|
| 4h/dia por 2 dias | US$ 1,43 |
| 6h/dia por 2 dias | US$ 2,14 |
| Uma sessão de 3h para gravar o vídeo | US$ 0,54 |
| Ligado 8 dias ininterruptos | US$ 34,27 |

## Fluxo recomendado

```powershell
# Começar a sessão — o cluster leva 15-20 min para ficar pronto
terraform -chdir=terraform apply -auto-approve

# ... trabalhar, testar, gravar ...

# Terminar a sessão — zera o custo
terraform -chdir=terraform destroy -auto-approve
```

Como o state vive no HCP Terraform, o `apply` reproduz o mesmo cluster a cada vez.

## Depois de cada destroy, confira

O `destroy` remove o que o Terraform criou. Mas **o Load Balancer é criado pelo Kubernetes**,
não pelo Terraform — quando o Helm instala o Kong com `proxy.type: LoadBalancer`, é o
cloud-controller da AWS que provisiona o NLB.

Se o Service for removido junto com o cluster, a AWS costuma limpar o NLB. Mas nem sempre:
um NLB órfão continua cobrando **US$ 0,03/h** — US$ 21/mês — silenciosamente.

**Verifique após o destroy:**

1. Load Balancers → https://console.aws.amazon.com/ec2/home#LoadBalancers
2. Volumes EBS não anexados → https://console.aws.amazon.com/ec2/home#Volumes
3. Elastic IPs não associados → https://console.aws.amazon.com/ec2/home#Elastic-IPs

Uma forma mais segura de destruir, que remove o NLB antes:

```powershell
# 1. Remove o Kong primeiro (e com ele o Service que criou o NLB)
kubectl -n kong delete svc --all
# 2. Espera a AWS remover o balanceador (~1 min)
# 3. Aí sim destrói o resto
terraform -chdir=terraform destroy -auto-approve
```

## Alarme de orçamento

Além do budget de US$ 1 já configurado, vale um alarme de faturamento:
`CloudWatch` → `Alarms` → `Billing` → limiar de **US$ 5** e **US$ 15**.
