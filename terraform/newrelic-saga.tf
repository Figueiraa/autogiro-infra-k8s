# ─── Saga e rastreamento distribuído ─────────────────────────────────────────
# Os três microsserviços (OS, Billing e Execution) exportam traces com
# OpenTelemetry direto para o New Relic (OTLP). No New Relic cada span cai na
# tabela `Span`, com os atributos que os serviços gravam:
#
#   autogiro.order_id / autogiro.saga_id   OS e Saga a que o span pertence
#   autogiro.message.type                  comando ou evento (ReservarPecas, ...)
#   autogiro.message.outcome               done | retry | dead_letter
#   autogiro.saga.state                    estado da Saga depois de cada evento
#   autogiro.saga.failure_reason           motivo da compensação
#
# Spans de mensagem têm `span.kind` producer (envio) ou consumer (processamento).
# Mesmo padrão condicional dos outros recursos do New Relic: sem a User API key
# nada é criado.

resource "newrelic_one_dashboard" "saga" {
  count = var.new_relic_api_key == "" ? 0 : 1

  name        = "AutoGiro — Saga e rastreamento"
  description = "Andamento da Saga da OS entre os três microsserviços, mensageria e traces."
  permissions = "public_read_write"

  # ═══ Página 1: Saga ═══════════════════════════════════════════════════════
  page {
    name        = "Saga"
    description = "Quantas Sagas começam, terminam e são compensadas, e por quê."

    # Abertas: requisições de abertura de OS. Concluídas e compensadas: o
    # orquestrador grava o estado da Saga no span de cada evento processado.
    widget_billboard {
      title  = "Sagas no período"
      row    = 1
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT filter(uniqueCount(autogiro.order_id), WHERE name = 'POST /api/v1/service-orders') AS 'Iniciadas',
                 filter(uniqueCount(autogiro.saga_id), WHERE autogiro.saga.state = 'CONCLUIDA') AS 'Concluídas',
                 filter(uniqueCount(autogiro.saga_id), WHERE autogiro.saga.state = 'COMPENSADA') AS 'Compensadas'
          FROM Span
          WHERE service.name = 'os-service'
          SINCE 1 day ago
        EOT
      }
    }

    widget_pie {
      title  = "Compensações por motivo"
      row    = 1
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT uniqueCount(autogiro.saga_id) AS 'Sagas'
          FROM Span
          WHERE autogiro.saga.state = 'COMPENSADA'
          FACET autogiro.saga.failure_reason
          SINCE 1 day ago
        EOT
      }
    }

    # Cada comando e evento processado, por tipo: mostra em que etapa as Sagas
    # estão andando (ou parando).
    widget_line {
      title  = "Mensagens processadas por tipo"
      row    = 4
      column = 1
      width  = 8
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT count(*)
          FROM Span
          WHERE span.kind = 'consumer'
          FACET autogiro.message.type
          SINCE 1 day ago
          TIMESERIES AUTO
        EOT
      }
    }

    # Retentativas são falhas técnicas que o retry absorveu; DLQ é o que
    # esgotou as tentativas e precisa de alguém olhando (há alerta para isso).
    widget_billboard {
      title  = "Falhas na mensageria"
      row    = 4
      column = 9
      width  = 4
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT filter(count(*), WHERE autogiro.message.outcome = 'retry') AS 'Retentativas',
                 filter(count(*), WHERE autogiro.message.outcome = 'dead_letter') AS 'Na DLQ'
          FROM Span
          WHERE span.kind = 'consumer'
          SINCE 1 day ago
        EOT
      }

      critical = 1
    }

    # `duration.ms` é atributo de cada span (não um histograma), então o
    # percentile() direto dá o valor real.
    widget_bar {
      title  = "Tempo de processamento por mensagem (p95, ms)"
      row    = 7
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT percentile(duration.ms, 95) AS 'p95 (ms)'
          FROM Span
          WHERE span.kind = 'consumer'
          FACET autogiro.message.type
          SINCE 1 day ago
        EOT
      }
    }

    widget_table {
      title  = "Mensagens que foram para a DLQ"
      row    = 7
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT latest(timestamp) AS 'Quando', latest(autogiro.order_id) AS 'OS',
                 latest(otel.status_description) AS 'Erro'
          FROM Span
          WHERE autogiro.message.outcome = 'dead_letter'
          FACET service.name, messaging.destination.name, autogiro.message.type
          SINCE 7 days ago
          LIMIT 20
        EOT
      }
    }
  }

  # ═══ Página 2: Rastreamento ═══════════════════════════════════════════════
  page {
    name        = "Rastreamento"
    description = "Traces que atravessam os serviços e a saúde de cada um."

    # Cada linha é um trace com uma OS: quantos serviços ele atravessou. A
    # abertura de uma OS passa pelos três (OS → Execution → OS → Billing → OS).
    # Só abertura e mensagens: consultas avulsas da OS seriam traces de um span.
    widget_table {
      title  = "Traces das ordens de serviço"
      row    = 1
      column = 1
      width  = 12
      height = 4

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT uniqueCount(service.name) AS 'Serviços', count(*) AS 'Mensagens',
                 latest(autogiro.message.type) AS 'Última mensagem', max(timestamp) AS 'Quando'
          FROM Span
          WHERE autogiro.order_id IS NOT NULL
          AND (span.kind IN ('producer', 'consumer') OR name = 'POST /api/v1/service-orders')
          FACET autogiro.order_id AS 'OS', trace.id
          SINCE 1 day ago
          LIMIT 30
        EOT
      }
    }

    widget_line {
      title  = "Requisições HTTP por serviço (por minuto)"
      row    = 5
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT rate(count(*), 1 minute)
          FROM Span
          WHERE span.kind = 'server'
          FACET service.name
          SINCE 1 day ago
          TIMESERIES AUTO
        EOT
      }
    }

    widget_line {
      title  = "Latência HTTP p95 por serviço (ms)"
      row    = 5
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT percentile(duration.ms, 95)
          FROM Span
          WHERE span.kind = 'server'
          FACET service.name
          SINCE 1 day ago
          TIMESERIES AUTO
        EOT
      }
    }

    widget_bar {
      title  = "Spans com erro por serviço"
      row    = 8
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT count(*) AS 'Spans com erro'
          FROM Span
          WHERE otel.status_code = 'ERROR'
          FACET service.name
          SINCE 1 day ago
        EOT
      }
    }

    # Chamadas que saem de cada serviço: banco, Mercado Pago e o catálogo de
    # peças do Execution consultado pelo OS na abertura.
    widget_bar {
      title  = "Dependências: tempo médio por destino (ms)"
      row    = 8
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT average(duration.ms) AS 'Média (ms)'
          FROM Span
          WHERE span.kind = 'client'
          FACET service.name, cases(
            WHERE db.system IS NOT NULL AS 'Banco',
            WHERE http.url LIKE '%mercadopago%' AS 'Mercado Pago',
            WHERE http.url LIKE '%/parts/%' AS 'Catálogo de peças'
          )
          SINCE 1 day ago
        EOT
      }
    }
  }
}

# ─── Alerta: mensagem na DLQ ─────────────────────────────────────────────────
# Uma mensagem só chega à DLQ depois de esgotar as tentativas: é um comando ou
# evento da Saga que não foi processado e deixou uma OS parada. Qualquer
# ocorrência abre incidente.
resource "newrelic_nrql_alert_condition" "mensagem_na_dlq" {
  count = var.new_relic_api_key == "" ? 0 : 1

  account_id = var.new_relic_account_id
  policy_id  = newrelic_alert_policy.autogiro[0].id
  name       = "Mensagem da Saga na DLQ"
  description = join(" ", [
    "Uma mensagem esgotou as tentativas e foi para a DLQ; a OS dela pode estar parada.",
    "Veja a fila e o erro na tabela 'Mensagens que foram para a DLQ' do painel da Saga."
  ])
  type    = "static"
  enabled = true

  # FACET: o incidente aponta o serviço e a fila em que a mensagem ficou.
  nrql {
    query = <<-EOT
      SELECT count(*)
      FROM Span
      WHERE autogiro.message.outcome = 'dead_letter'
      FACET service.name, messaging.destination.name
    EOT
  }

  critical {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 60
    threshold_occurrences = "AT_LEAST_ONCE"
  }

  # DLQ é dado esparso: com `event_flow` a janela só fecharia quando chegasse a
  # próxima mensagem na DLQ. O `event_timer` fecha a janela 60 s depois do último
  # dado, então uma mensagem isolada já abre o incidente.
  aggregation_window           = 60
  aggregation_method           = "event_timer"
  aggregation_timer            = 60
  violation_time_limit_seconds = 86400
}
