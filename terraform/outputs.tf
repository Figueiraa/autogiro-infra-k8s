output "cluster_name" {
  description = "Nome do cluster kind provisionado."
  value       = kind_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint da API do cluster Kubernetes."
  value       = kind_cluster.this.endpoint
}

output "kubeconfig_path" {
  description = "Caminho do kubeconfig gerado pelo kind."
  value       = kind_cluster.this.kubeconfig_path
}

output "namespace" {
  description = "Namespace da aplicação."
  value       = kubernetes_namespace.autogiro.metadata[0].name
}

output "kong_proxy_url" {
  description = "URL do gateway. Todas as chamadas à API passam por aqui."
  value       = "http://localhost:${var.kong_http_port}"
}

output "kong_admin_url" {
  description = "URL da Admin API do Kong (inspeção de rotas e plugins)."
  value       = "http://localhost:${var.kong_admin_port}"
}

output "new_relic_enabled" {
  description = "Indica se o agente do New Relic foi instalado."
  # Deriva da contagem do recurso, e não da variável sensível: assim o valor
  # é um booleano comum, sem herdar a marcação de sensibilidade da license key.
  value = length(helm_release.new_relic) > 0
}
