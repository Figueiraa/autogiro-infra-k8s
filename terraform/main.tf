# ─── Namespaces ──────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "autogiro" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/part-of" = "autogiro"
    }
  }

  depends_on = [aws_eks_node_group.this]
}

resource "kubernetes_namespace" "kong" {
  metadata {
    name = "kong"
  }

  depends_on = [aws_eks_node_group.this]
}

# ─── metrics-server ──────────────────────────────────────────────────────────
# Pré-requisito do HPA: sem ele o autoscaler não lê CPU nem memória.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.2"

  # Os kubelets do EKS apresentam certificados assinados pela CA interna do
  # cluster, que o metrics-server nao valida por padrao.
  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [aws_eks_node_group.this]
}

# ─── Kong Gateway (API Gateway do projeto) ───────────────────────────────────
# Atua como Ingress Controller e API Gateway: roteia as chamadas para a API e
# valida, via plugin `jwt`, os tokens emitidos pela Lambda (autogiro-auth).
resource "helm_release" "kong" {
  name       = "kong"
  repository = "https://charts.konghq.com"
  chart      = "kong"
  namespace  = kubernetes_namespace.kong.metadata[0].name
  version    = "2.46.0"

  # Modo DB-less: a configuração vem dos recursos do Kubernetes (Ingress e
  # KongPlugin), versionados junto com a aplicação.
  set {
    name  = "env.database"
    value = "off"
  }

  set {
    name  = "ingressController.installCRDs"
    value = "false"
  }

  # No EKS o proxy vira um Service do tipo LoadBalancer: a AWS provisiona um
  # NodePort com porta fixa, e nao LoadBalancer.
  #
  # A intencao original era um Network Load Balancer, mas esta conta AWS responde
  # `OperationNotPermitted: This AWS account currently does not support creating
  # load balancers` — a mesma restricao de plataforma de conta nova que impede a
  # invocacao publica da Function URL da Lambda.
  #
  # A alternativa mantem o gateway publicamente acessivel: os nos do EKS estao em
  # subnet publica e tem IP proprio, entao o Kong responde em
  # http://<ip-publico-do-no>:30080. Perde-se o balanceamento e o DNS estavel do
  # NLB; o roteamento, os plugins e a validacao de JWT sao identicos.
  set {
    name  = "proxy.type"
    value = "NodePort"
  }

  set {
    name  = "proxy.http.nodePort"
    value = var.kong_node_port
  }

  set {
    name  = "proxy.tls.enabled"
    value = "false"
  }

  set {
    name  = "admin.enabled"
    value = "true"
  }

  set {
    name  = "admin.http.enabled"
    value = "true"
  }

  # SEGURANCA: a Admin API do Kong permite reconfigurar rotas e plugins sem
  # autenticacao. Fica em ClusterIP, alcancavel apenas de dentro do cluster
  # (via `kubectl port-forward` para inspecao). Expo-la em LoadBalancer
  # entregaria o controle do gateway para a internet.
  set {
    name  = "admin.type"
    value = "ClusterIP"
  }

  depends_on = [aws_eks_node_group.this]
}

# ─── New Relic ───────────────────────────────────────────────────────────────
# Agente de infraestrutura, coleta de logs e métricas do cluster (requisito R9).
# Só é instalado quando a license key é informada.
resource "helm_release" "new_relic" {
  count = var.new_relic_license_key == "" ? 0 : 1

  name             = "newrelic-bundle"
  repository       = "https://helm-charts.newrelic.com"
  chart            = "nri-bundle"
  namespace        = "newrelic"
  create_namespace = true
  version          = "5.0.100"

  set {
    name  = "global.cluster"
    value = var.new_relic_cluster_name
  }

  set_sensitive {
    name  = "global.licenseKey"
    value = var.new_relic_license_key
  }

  set {
    name  = "global.lowDataMode"
    value = "true" # Reduz o volume ingerido, preservando a cota de 100GB/mês.
  }

  # Infraestrutura: CPU, memória e estado dos pods.
  set {
    name  = "infrastructure.enabled"
    value = "true"
  }

  # Logs estruturados com correlação de trace (requisito R9).
  set {
    name  = "logging.enabled"
    value = "true"
  }

  # Eventos do Kubernetes (falhas de scheduling, OOMKill, restart de pods).
  set {
    name  = "kubeEvents.enabled"
    value = "true"
  }

  set {
    name  = "newrelic-prometheus-agent.enabled"
    value = "true"
  }

  # O Pixie exige mais recursos do que os nos t4g.small comportam, e o eBPF
  # dele elevaria o volume ingerido bem acima da cota gratuita.
  set {
    name  = "newrelic-pixie.enabled"
    value = "false"
  }

  depends_on = [aws_eks_node_group.this]
}
