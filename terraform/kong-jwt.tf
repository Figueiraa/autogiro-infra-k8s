# ═══════════════════════════════════════════════════════════════════════════
# Validação de JWT no Kong
#
# A Lambda (autogiro-auth) assina o token; o Kong valida a assinatura antes de
# encaminhar a requisição para a API. Nenhum dos dois conhece o outro — o
# contrato é apenas o segredo HS256 e a claim `iss`.
#
# No Kong, a credencial JWT pertence a um Consumer. A claim `iss` do token
# ("autogiro-auth") precisa casar com o campo `key` da credencial: é assim que
# o Kong descobre qual segredo usar para verificar a assinatura.
# ═══════════════════════════════════════════════════════════════════════════

variable "jwt_secret" {
  description = "Segredo HS256 compartilhado com a Lambda de autenticação."
  type        = string
  sensitive   = true
}

variable "jwt_issuer" {
  description = "Valor da claim `iss` emitida pela Lambda."
  type        = string
  default     = "autogiro-auth"
}

# ─── Consumer ────────────────────────────────────────────────────────────────
# Representa a Lambda como emissora de tokens.
resource "kubernetes_manifest" "kong_consumer" {
  manifest = {
    apiVersion = "configuration.konghq.com/v1"
    kind       = "KongConsumer"

    metadata = {
      name      = "autogiro-auth"
      namespace = var.namespace

      annotations = {
        "kubernetes.io/ingress.class" = "kong"
      }
    }

    username    = "autogiro-auth"
    credentials = [kubernetes_secret.kong_jwt.metadata[0].name]
  }

  depends_on = [helm_release.kong, kubernetes_namespace.autogiro]
}

# ─── Credencial JWT do Consumer ──────────────────────────────────────────────
resource "kubernetes_secret" "kong_jwt" {
  metadata {
    name      = "autogiro-jwt-credential"
    namespace = var.namespace

    labels = {
      "konghq.com/credential" = "jwt"
    }
  }

  data = {
    # `key` casa com a claim `iss` do token.
    key = var.jwt_issuer
    # `secret` é a chave HS256 usada para verificar a assinatura.
    secret    = var.jwt_secret
    algorithm = "HS256"
  }

  depends_on = [kubernetes_namespace.autogiro]
}

# ─── Plugin ──────────────────────────────────────────────────────────────────
# Referenciado pelo Ingress da aplicação através da annotation
# `konghq.com/plugins: autogiro-jwt` (ver k8s/ingress.yaml no autogiro-app).
resource "kubernetes_manifest" "kong_jwt_plugin" {
  manifest = {
    apiVersion = "configuration.konghq.com/v1"
    kind       = "KongPlugin"

    metadata = {
      name      = "autogiro-jwt"
      namespace = var.namespace
    }

    plugin = "jwt"

    config = {
      # Onde procurar o token na requisição.
      header_names     = ["Authorization"]
      claims_to_verify = ["exp"]
      key_claim_name   = "iss"
      # Rejeita requisição sem token em vez de deixar passar como anônima.
      anonymous = ""
    }
  }

  depends_on = [helm_release.kong, kubernetes_namespace.autogiro]
}
