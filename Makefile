# Atalhos para operar o cluster EKS do AutoGiro.
#
# O cluster e gerenciado na AWS, entao tanto a pipeline quanto estes comandos
# alcancam a API do cluster de fora. A pipeline valida com `plan` e provisiona
# com `apply` quando DEPLOY_ENABLED=true.
#
# ATENCAO: o cluster cobra ~US$0,18/h enquanto existe. Use `make destroy` ao
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
	@echo "make destroy    - remove o cluster inteiro e para a cobranca"
	@echo "make kubeconfig - aponta o kubectl para o cluster"
	@echo "make status     - estado dos nos, pods e do HPA"
	@echo "make gateway    - hostname publico do Kong"
	@echo "make kong-routes- rotas e plugins registrados no Kong"

init:
	$(TF) init

plan:
	$(TF) plan

apply:
	$(TF) apply

destroy:
	@echo "Removendo os Services primeiro, para a AWS apagar o Load Balancer..."
	-@kubectl -n kong delete svc --all --timeout=120s
	-@kubectl -n autogiro delete svc --all --timeout=120s
	@echo "Aguardando a AWS remover o balanceador (60s)..."
	@sleep 60
	$(TF) destroy

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
# vazio. Os dois nos atendem; este alvo devolve o primeiro.
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
