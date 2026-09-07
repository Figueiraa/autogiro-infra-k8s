output "cluster_name" {
  description = "Nome do cluster EKS provisionado."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint da API do cluster Kubernetes."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Versão do Kubernetes rodando no control plane."
  value       = aws_eks_cluster.this.version
}

output "aws_region" {
  description = "Região da AWS onde o cluster foi criado."
  value       = var.aws_region
}

output "kubeconfig_command" {
  description = "Comando que grava as credenciais do cluster no kubeconfig local."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}

output "namespace" {
  description = "Namespace da aplicação."
  value       = kubernetes_namespace.autogiro.metadata[0].name
}

# ─── Kong ────────────────────────────────────────────────────────────────────
# O hostname do NLB é atribuído pela AWS depois que o Service é criado, então
# é lido do Service e não de um recurso do Terraform. É o endereço usado no
# host do Ingress da aplicação e na demonstração da entrega.
data "kubernetes_service" "kong_proxy" {
  metadata {
    name      = "kong-kong-proxy"
    namespace = kubernetes_namespace.kong.metadata[0].name
  }

  depends_on = [helm_release.kong]
}

output "kong_proxy_hostname" {
  description = "Hostname do LoadBalancer (NLB) do proxy do Kong."
  value       = try(data.kubernetes_service.kong_proxy.status[0].load_balancer[0].ingress[0].hostname, "")
}

output "kong_proxy_url" {
  description = "URL do gateway. Todas as chamadas à API passam por aqui."
  value       = try("http://${data.kubernetes_service.kong_proxy.status[0].load_balancer[0].ingress[0].hostname}", "")
}

output "kong_admin_port_forward" {
  description = "A Admin API é ClusterIP por segurança; use este comando para acessá-la."
  value       = "kubectl port-forward -n kong svc/kong-kong-admin 8001:8001"
}

output "new_relic_enabled" {
  description = "Indica se o agente do New Relic foi instalado."
  # Deriva da contagem do recurso, e não da variável sensível: assim o valor
  # é um booleano comum, sem herdar a marcação de sensibilidade da license key.
  value = length(helm_release.new_relic) > 0
}
