# ═════════════════════════════════════════════════════════════════════════════
# Métricas do API Gateway
#
# A aplicação já expõe as próprias métricas em /metrics, mas elas só enxergam o
# que chegou até ela. O que o gateway barrou na borda — um 401 por token
# ausente, por exemplo — nunca aparece ali, porque a requisição não chegou ao
# upstream.
#
# O plugin `prometheus` do Kong fecha essa lacuna: passa a publicar contadores
# por rota, por serviço e por código HTTP, além da latência gasta *dentro* do
# gateway, separada da latência do upstream. É a diferença entre "a API está
# lenta" e "o gateway está lento".
#
# O plugin é anexado pelos Ingresses da aplicação, através da annotation
# `konghq.com/plugins` (ver k8s/ingress.yaml no autogiro-app) — o mesmo
# mecanismo do plugin de JWT. O label `global: "true"`, que dispensaria as
# annotations, foi depreciado nas versões recentes do ingress controller e é
# silenciosamente ignorado: o plugin simplesmente não chega ao Kong.
# ═════════════════════════════════════════════════════════════════════════════

resource "kubectl_manifest" "kong_prometheus_plugin" {
  yaml_body = yamlencode({
    apiVersion = "configuration.konghq.com/v1"
    kind       = "KongPlugin"

    metadata = {
      name      = "autogiro-prometheus"
      namespace = var.namespace
    }

    plugin = "prometheus"

    config = {
      # Latência separada em três medidas: total, tempo no Kong e tempo no
      # upstream. É o que permite atribuir a lentidão a um lado ou ao outro.
      latency_metrics = true

      # Contadores por código HTTP e por consumer. Como só existe um consumer
      # (autogiro-auth), o corte por consumer é barato em cardinalidade.
      status_code_metrics     = true
      bandwidth_metrics       = true
      upstream_health_metrics = true
    }
  })

  depends_on = [helm_release.kong, kubernetes_namespace.autogiro]
}

# ─── Coleta pelo agente do New Relic ─────────────────────────────────────────
# O agente Prometheus do New Relic descobre alvos pelas annotations e coleta
# direto do pod, não através do Service. Por isso a porta anunciada tem de ser a
# do CONTAINER: o Kong publica as métricas na `status_listen`, que é a 8100.
#
# A porta 10254 do Service `kong-kong-metrics` é só o mapeamento externo dela
# (10254 -> cstatus -> 8100); anunciar 10254 faz o scrape bater numa porta que
# não existe dentro do pod. Foi o mesmo erro cometido no Service da aplicação,
# onde anunciar 80 em vez de 8000 deixava o alvo `down`.
resource "kubernetes_annotations" "kong_metrics_scrape" {
  api_version = "v1"
  kind        = "Service"

  metadata {
    name      = "kong-kong-metrics"
    namespace = kubernetes_namespace.kong.metadata[0].name
  }

  annotations = {
    "prometheus.io/scrape" = "true"
    "prometheus.io/port"   = "8100"
    "prometheus.io/path"   = "/metrics"
  }

  # O chart gerencia o Service; aqui só somamos as annotations a ele.
  force = true

  depends_on = [helm_release.kong]
}
