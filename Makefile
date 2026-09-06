# Atalhos para operar o cluster local do AutoGiro.
#
# O cluster roda na máquina do desenvolvedor, então o `apply` não acontece em
# runner hospedado — a pipeline valida, e o deploy é feito por aqui (ou por um
# self-hosted runner).

TF := terraform -chdir=terraform

.PHONY: help init plan apply destroy status kong-routes

help:
	@echo "make init     - inicializa o Terraform"
	@echo "make plan     - mostra o plano de mudanças"
	@echo "make apply    - cria o cluster, o Kong e o agente do New Relic"
	@echo "make destroy  - remove o cluster inteiro"
	@echo "make status   - estado dos pods e do HPA"
	@echo "make kong-routes - rotas e plugins registrados no Kong"

init:
	$(TF) init

plan:
	$(TF) plan

apply:
	$(TF) apply

destroy:
	$(TF) destroy

status:
	@echo "── Nós ──"
	@kubectl get nodes
	@echo "\n── Pods (autogiro) ──"
	@kubectl -n autogiro get pods
	@echo "\n── Pods (kong) ──"
	@kubectl -n kong get pods
	@echo "\n── HPA ──"
	@kubectl -n autogiro get hpa

kong-routes:
	@curl -s http://localhost:8001/routes | python -m json.tool
