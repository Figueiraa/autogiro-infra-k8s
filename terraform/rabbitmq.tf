# ═════════════════════════════════════════════════════════════════════════════
# RabbitMQ: o broker da Saga
#
# Leva comandos (exchange `autogiro.commands`) e eventos (`autogiro.events`) entre
# os microsserviços de OS, Billing e Execution. Exchanges e filas são declarados
# pelos próprios serviços ao subir; aqui só o broker.
#
# Uma réplica, sem volume persistente. O EKS não traz o driver de EBS instalado,
# e o desenho da Saga já tolera a perda do que estava na fila:
#   - mensagem ainda não publicada fica no outbox do serviço que a criou;
#   - comando publicado e perdido é reenviado pelo orquestrador depois de 120 s
#     sem resposta, e os participantes são idempotentes, então só republicam o
#     evento.
# ═════════════════════════════════════════════════════════════════════════════

resource "random_password" "rabbitmq" {
  length  = 32
  special = false # vai dentro da URL amqp://; sem caracteres que exijam escape
}

# Credenciais como arquivo de configuração (montado em conf.d), não como
# variável de ambiente: não aparecem no `env` do processo nem no describe do pod.
# Substituem o usuário `guest`, que deixa de existir.
resource "kubernetes_secret" "rabbitmq" {
  metadata {
    name      = "rabbitmq-credentials"
    namespace = kubernetes_namespace.autogiro.metadata[0].name
  }

  data = {
    "20-credenciais.conf" = <<-EOT
      default_user = autogiro
      default_pass = ${random_password.rabbitmq.result}
    EOT
  }
}

resource "kubernetes_deployment_v1" "rabbitmq" {
  metadata {
    name      = "rabbitmq"
    namespace = kubernetes_namespace.autogiro.metadata[0].name
    labels = {
      app = "rabbitmq"
    }
  }

  spec {
    replicas = 1

    # Recreate: duas instâncias ao mesmo tempo dividiriam as filas entre si.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "rabbitmq"
      }
    }

    template {
      metadata {
        labels = {
          app = "rabbitmq"
        }
        # Plugin rabbitmq_prometheus (já ativo na imagem). `per-object` traz a
        # profundidade de cada fila, inclusive das DLQs.
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "15692"
          "prometheus.io/path"   = "/metrics/per-object"
        }
      }

      spec {
        # O token da API do Kubernetes não serve ao broker.
        automount_service_account_token = false

        # A imagem já roda como o usuário rabbitmq (999); fs_group dá a ele o
        # volume de dados.
        security_context {
          run_as_non_root = true
          run_as_user     = 999
          run_as_group    = 999
          fs_group        = 999
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name = "rabbitmq"
          # Fixada por digest: a tag 4.0-management muda a cada patch.
          image             = "rabbitmq:4.0-management@sha256:9a89f8c721b75af21c6e13df21cf4d284c26d0ca6f5e4e61178f963c776241bd"
          image_pull_policy = "Always"

          security_context {
            allow_privilege_escalation = false
            # Só o diretório de dados e o /tmp são graváveis.
            read_only_root_filesystem = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "credenciais"
            mount_path = "/etc/rabbitmq/conf.d/20-credenciais.conf"
            sub_path   = "20-credenciais.conf"
            read_only  = true
          }

          volume_mount {
            name       = "dados"
            mount_path = "/var/lib/rabbitmq"
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          port {
            name           = "amqp"
            container_port = 5672
          }
          port {
            name           = "management"
            container_port = 15672
          }
          port {
            name           = "metrics"
            container_port = 15692
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          # Sondas por TCP: `rabbitmq-diagnostics` dentro do container disputa o
          # .erlang.cookie com o próprio broker durante a subida.
          readiness_probe {
            tcp_socket {
              port = 5672
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }

          liveness_probe {
            tcp_socket {
              port = 5672
            }
            initial_delay_seconds = 60
            period_seconds        = 15
          }
        }

        volume {
          name = "credenciais"
          secret {
            secret_name = kubernetes_secret.rabbitmq.metadata[0].name
          }
        }

        # Sem persistência (ver o topo do arquivo).
        volume {
          name = "dados"
          empty_dir {}
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [aws_eks_node_group.this]
}

resource "kubernetes_service_v1" "rabbitmq" {
  metadata {
    name      = "rabbitmq"
    namespace = kubernetes_namespace.autogiro.metadata[0].name
  }

  spec {
    type = "ClusterIP"
    selector = {
      app = "rabbitmq"
    }
    port {
      name        = "amqp"
      port        = 5672
      target_port = 5672
    }
    port {
      name        = "management"
      port        = 15672
      target_port = 15672
    }
  }
}
