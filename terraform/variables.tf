variable "cluster_name" {
  description = "Nome do cluster kind."
  type        = string
  default     = "autogiro"
}

variable "node_image" {
  description = "Imagem do nó do kind (fixa a versão do Kubernetes)."
  type        = string
  default     = "kindest/node:v1.31.0"
}

variable "namespace" {
  description = "Namespace da aplicação."
  type        = string
  default     = "autogiro"
}

variable "kong_http_port" {
  description = "Porta do host mapeada para o proxy HTTP do Kong."
  type        = number
  default     = 8000
}

variable "kong_admin_port" {
  description = "Porta do host mapeada para a Admin API do Kong."
  type        = number
  default     = 8001
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
