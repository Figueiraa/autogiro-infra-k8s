# Controle de custo do cluster

> O EKS cobra **por hora de existência do cluster**, não por uso. Subir só quando for
> trabalhar e destruir ao terminar reduz o custo a alguns dólares.

## Quanto custa

| Recurso | US$/h |
|---|---|
| Control plane EKS | 0,100 |
| 2× t4g.small (Graviton) | 0,034 |
| EBS 2×20 GB gp3 | 0,004 |
| IPs públicos dos nós | 0,010 |
| **Total** | **~0,148** |

**US$ 3,55 por dia** se ficar ligado 24h.

Não há custo de Load Balancer: esta conta não permite criá-los, então o Kong entra como
NodePort na porta 30080 e o ponto de entrada é o IP público de qualquer nó. A restrição
economiza US$ 0,031/h — o único efeito colateral bom dela.

## Cenários reais

| Uso | Custo |
|---|---|
| 4h/dia por 2 dias | US$ 1,18 |
| 6h/dia por 2 dias | US$ 1,78 |
| Uma sessão de 3h para gravar o vídeo | US$ 0,44 |
| Ligado 8 dias ininterruptos | US$ 28,42 |

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

O `destroy` remove o que o Terraform criou, mas alguns recursos são criados *pelo
Kubernetes* e não pelo Terraform — o cloud-controller da AWS provisiona volumes e
balanceadores em resposta a objetos do cluster. Se o cluster morre antes deles, sobram
órfãos cobrando em silêncio.

Como esta conta não permite Load Balancer, o risco aqui é menor do que o normal: sobra
verificar volumes e IPs. Ainda assim, vale o hábito — em uma conta sem essa restrição um
NLB órfão custa US$ 21/mês sem aparecer em lugar nenhum.

**Verifique após o destroy:**

1. Volumes EBS não anexados → https://console.aws.amazon.com/ec2/home#Volumes
2. Elastic IPs não associados → https://console.aws.amazon.com/ec2/home#Elastic-IPs
3. Load Balancers → https://console.aws.amazon.com/ec2/home#LoadBalancers (deve estar vazio)

O `make destroy` já remove os Services antes do `terraform destroy`, justamente para dar à
AWS a chance de limpar o que ela criou:

```powershell
kubectl -n kong delete svc --all      # 1. remove os Services
# 2. aguarda a AWS reagir (~1 min)
terraform -chdir=terraform destroy -auto-approve   # 3. destrói o resto
```

## Alarme de orçamento

Além do budget de US$ 1 já configurado, vale um alarme de faturamento:
`CloudWatch` → `Alarms` → `Billing` → limiar de **US$ 5** e **US$ 15**.
