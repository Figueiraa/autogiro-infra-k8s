# Backend do Terraform state — HCP Terraform (Terraform Cloud).
#
# O cluster passou a ser um EKS gerenciado na AWS, então o state precisa
# sobreviver entre execuções: sem ele, um novo `apply` tentaria criar uma
# segunda VPC e um segundo cluster em vez de reconhecer os existentes — e o
# cluster antigo continuaria cobrando, órfão.
#
# `tags` em vez de `name`: o workspace é escolhido em tempo de execução
# (`TF_WORKSPACE=autogiro-infra-k8s-homolog` ou `-prod`), dando a cada
# ambiente um state independente.
#
# Autenticação: `TF_TOKEN_app_terraform_io` no ambiente (a pipeline injeta a
# partir do secret `TF_API_TOKEN`) ou `terraform login` na máquina.
terraform {
  cloud {
    organization = "autogiro"

    workspaces {
      tags = ["autogiro-infra-k8s"]
    }
  }
}
