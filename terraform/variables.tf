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

