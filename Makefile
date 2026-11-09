# Atalhos para operar o cluster EKS do AutoGiro.
#
# O cluster e gerenciado na AWS, entao tanto a pipeline quanto estes comandos
# alcancam a API do cluster de fora. A pipeline valida com `plan` e provisiona
# com `apply` quando DEPLOY_ENABLED=true.
#
# ATENCAO: o cluster cobra ~US$0,17/h enquanto existe. Use `make destroy` ao
# terminar — ver CUSTO.md.
#
# Pre-requisitos: `aws configure` feito, `terraform login` executado e a
# variavel TF_WORKSPACE apontando para o ambiente desejado:
#
#   $env:TF_WORKSPACE = "autogiro-infra-k8s-homolog"

TF := terraform -chdir=terraform

.PHONY: help init plan apply destroy status kubeconfig kong-routes gateway

help:
	@echo "make init       - inicializa o Terraform"
	@echo "make plan       - mostra o plano de mudancas"
	@echo "make apply      - cria o cluster, o Kong e o agente do New Relic"
	@echo "make destroy    - remove o cluster e para a cobranca (mantem o New Relic)"
	@echo "make kubeconfig - aponta o kubectl para o cluster"
	@echo "make status     - estado dos nos, pods e do HPA"
	@echo "make gateway    - endereco publico do Kong (IP do no, porta 30080)"
	@echo "make kong-routes- rotas e plugins registrados no Kong"

init:
	$(TF) init

plan:
	$(TF) plan

apply:
	$(TF) apply

# Destroy direcionado: a VPC e as roles levam junto tudo que depende delas
# (cluster, nos, Kong, RabbitMQ, agentes). Ficam os dashboards e alertas do New
# Relic, que estao no mesmo state e nao dependem do cluster. Antes, os pods sao
# forcados para fora: pod preso em Terminating trava o namespace, e o destroy
# desiste dele e tenta soltar o Internet Gateway com os nos ainda de pe.
destroy:
	-@kubectl -n autogiro delete deploy,statefulset --all --timeout=60s
	-@kubectl -n kong delete deploy,statefulset --all --timeout=60s
	-@kubectl delete pods --all -n autogiro --force --grace-period=0
	-@kubectl delete pods --all -n kong --force --grace-period=0
	$(TF) destroy -target=aws_vpc.this -target=aws_iam_role.cluster -target=aws_iam_role.node

kubeconfig:
	aws eks update-kubeconfig --name autogiro --region us-east-1

status:
	@echo "-- Nos --"
	@kubectl get nodes
	@echo ""
	@echo "-- Pods (autogiro) --"
	@kubectl -n autogiro get pods
	@echo ""
	@echo "-- Pods (kong) --"
	@kubectl -n kong get pods
	@echo ""
	@echo "-- HPA --"
	@kubectl -n autogiro get hpa

# Com o Kong em NodePort o endereco publico e o IP do no na 30080: nao existe
# hostname de balanceador para ler, entao `loadBalancer.ingress` fica sempre
# vazio. Todos os nos atendem; este alvo devolve o primeiro.
gateway:
	@echo "http://$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'):30080"

# A Admin API do Kong e ClusterIP de proposito: expo-la na internet daria
# controle total do gateway a qualquer um. O acesso e por port-forward.
kong-routes:
	@echo "Abrindo port-forward para a Admin API do Kong..."
	@kubectl -n kong port-forward svc/kong-kong-admin 8001:8001 & \
		sleep 4; \
		curl -s http://localhost:8001/routes | python -m json.tool; \
		kill %1
