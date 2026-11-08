# ═════════════════════════════════════════════════════════════════════════════
# Configuração compartilhada pelos microsserviços
#
# O que é da plataforma fica aqui; o que é de cada serviço (banco, Mercado Pago)
# fica no Secret do próprio serviço, criado pela pipeline dele. Os Deployments
# leem os dois com `envFrom`:
#
#   autogiro-plataforma (Secret)     JWT_SECRET, RABBITMQ_URL, NEW_RELIC_LICENSE_KEY
#   autogiro-plataforma (ConfigMap)  OTEL_EXPORTER_OTLP_ENDPOINT, DEPLOYMENT_ENVIRONMENT
#
# JWT_SECRET é o mesmo segredo que o Kong usa para validar o token (kong-jwt.tf):
# os serviços revalidam a assinatura em vez de confiar só no gateway.
# ═════════════════════════════════════════════════════════════════════════════

resource "kubernetes_secret" "plataforma" {
  metadata {
    name      = "autogiro-plataforma"
    namespace = kubernetes_namespace.autogiro.metadata[0].name
  }

  data = {
    JWT_SECRET = var.jwt_secret
    RABBITMQ_URL = format(
      "amqp://autogiro:%s@%s.%s.svc.cluster.local:5672/",
      random_password.rabbitmq.result,
      kubernetes_service_v1.rabbitmq.metadata[0].name,
      kubernetes_namespace.autogiro.metadata[0].name,
    )
    NEW_RELIC_LICENSE_KEY = var.new_relic_license_key
  }
}

resource "kubernetes_config_map" "plataforma" {
  metadata {
    name      = "autogiro-plataforma"
    namespace = kubernetes_namespace.autogiro.metadata[0].name
  }

  data = {
    # Traces vão direto do serviço para o New Relic (OTLP). Sem license key, o
    # endpoint fica vazio e os serviços não exportam nada.
    OTEL_EXPORTER_OTLP_ENDPOINT = var.new_relic_license_key == "" ? "" : "https://otlp.nr-data.net"
    DEPLOYMENT_ENVIRONMENT      = "producao"
  }
}
