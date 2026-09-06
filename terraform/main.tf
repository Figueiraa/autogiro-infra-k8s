# ─── Cluster Kubernetes ──────────────────────────────────────────────────────
# O control plane expõe as portas do Kong no host, para que o gateway seja
# alcançável de fora do cluster sem LoadBalancer (que o kind não provisiona).
resource "kind_cluster" "this" {
  name           = var.cluster_name
  node_image     = var.node_image
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # Rótulo exigido pelo Ingress do Kong para o node selector.
      kubeadm_config_patches = [
        "kind: InitConfiguration\nnodeRegistration:\n  kubeletExtraArgs:\n    node-labels: \"ingress-ready=true\"\n"
      ]

      extra_port_mappings {
        container_port = 30000
        host_port      = var.kong_http_port
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 30001
        host_port      = var.kong_admin_port
        protocol       = "TCP"
      }
    }

    # Nó worker adicional: dá ao HPA espaço real para distribuir réplicas.
    node {
      role = "worker"
    }
  }
}

# ─── Namespaces ──────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "autogiro" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/part-of" = "autogiro"
    }
  }

  depends_on = [kind_cluster.this]
}

resource "kubernetes_namespace" "kong" {
  metadata {
    name = "kong"
  }

  depends_on = [kind_cluster.this]
}

# ─── metrics-server ──────────────────────────────────────────────────────────
# Pré-requisito do HPA: sem ele o autoscaler não lê CPU nem memória.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.2"

  # Em kind os kubelets usam certificados self-signed.
  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [kind_cluster.this]
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

  # NodePort fixo casando com o extra_port_mapping do kind.
  set {
    name  = "proxy.type"
    value = "NodePort"
  }

  set {
    name  = "proxy.http.nodePort"
    value = "30000"
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

  set {
    name  = "admin.type"
    value = "NodePort"
  }

  set {
    name  = "admin.http.nodePort"
    value = "30001"
  }

  depends_on = [kind_cluster.this]
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

  # O Pixie exige mais recursos do que um cluster kind local comporta.
  set {
    name  = "newrelic-pixie.enabled"
    value = "false"
  }

  depends_on = [kind_cluster.this]
}
