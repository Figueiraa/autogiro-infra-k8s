variable "cluster_name" {
  description = "Nome do cluster EKS. Também prefixa VPC, subnets e roles IAM."
  type        = string
  default     = "autogiro"
}

variable "namespace" {
  description = "Namespace da aplicação."
  type        = string
  default     = "autogiro"
}

# ─── AWS / EKS ───────────────────────────────────────────────────────

variable "aws_region" {
  description = "Região da AWS onde o cluster é criado."
  type        = string
  default     = "us-east-1"
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes no control plane do EKS."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Tipo de instância dos nós. Graviton (ARM) por ser mais barato."
  type        = string
  default     = "t4g.small"
}

variable "node_min_size" {
  description = "Número mínimo de nós do node group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Número máximo de nós. Teto de custo do cluster."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Número de nós na criação do cluster."
  type        = number
  default     = 2
}

variable "new_relic_license_key" {
  description = "License key do New Relic. Vazio desabilita a instalação do agente."
  type        = string
  default     = ""
  sensitive   = true
}

variable "new_relic_cluster_name" {
  description = "Nome do cluster exibido no New Relic."
  type        = string
  default     = "autogiro"
}

# ─── New Relic: dashboards e alertas (API NerdGraph) ─────────────────────────
# Diferente da license key (ingestao de dados), estas credenciais servem para
# CRIAR recursos na conta. Sem a User API key nada e provisionado.

variable "new_relic_account_id" {
  description = "ID numerico da conta New Relic onde dashboards e alertas sao criados."
  type        = number
  default     = 0
}

variable "new_relic_api_key" {
  description = "User API key (prefixo NRAK) do New Relic. Vazio desabilita dashboards e alertas."
  type        = string
  default     = ""
  sensitive   = true
}

variable "alert_email" {
  description = "E-mail que recebe as notificacoes das condicoes de alerta do New Relic."
  type        = string
  default     = ""
}
