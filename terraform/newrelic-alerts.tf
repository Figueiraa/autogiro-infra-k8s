# ─── Alertas do New Relic ────────────────────────────────────────────────────
# Espelha as regras já definidas em Prometheus
# (autogiro-app/monitoring/prometheus/rules/alerts.yml) para que a operação
# tenha o mesmo conjunto de sinais no ambiente gerenciado.
#
# Correspondência PromQL -> NRQL nas condições NRQL:
#   * `for: 5m` do Prometheus vira `threshold_duration` (em segundos) na
#     `critical`/`warning` block.
#   * `rate(counter[5m])` vira `rate(sum(metrica), 1 second)`, com a janela de
#     avaliação controlada por `aggregation_window`.
#   * O regex `status_code=~"5.."` vira `status_code LIKE '5%'`.
#
# Tudo é condicional à User API key: sem ela, count = 0 e o CI roda sem
# credenciais (mesmo padrão do helm_release.new_relic em main.tf).

resource "newrelic_alert_policy" "autogiro" {
  count = var.new_relic_api_key == "" ? 0 : 1

  name       = "AutoGiro — Oficina"
  account_id = var.new_relic_account_id

  # Um incidente por condição: evita que uma degradação de latência esconda
  # uma indisponibilidade que abriu logo em seguida.
  incident_preference = "PER_CONDITION"
}

# ─── 1. API indisponível / sem healthcheck ───────────────────────────────────
# O equivalente do `up{job="autogiro-api"} == 0` do Prometheus. No New Relic
# não existe a série `up`: a ausência do sinal é detectada pela própria falta
# de dados, então usamos uma condição de perda de sinal (`expiration`) sobre o
# contador de requisições HTTP, que só existe enquanto a API responde.
resource "newrelic_nrql_alert_condition" "api_indisponivel" {
  count = var.new_relic_api_key == "" ? 0 : 1

  account_id = var.new_relic_account_id
  policy_id  = newrelic_alert_policy.autogiro[0].id
  name       = "API indisponível (sem healthcheck)"
  description = join(" ", [
    "A API da oficina parou de reportar métricas.",
    "Equivale ao alerta ApiIndisponivel (up == 0) do Prometheus."
  ])
  type    = "static"
  enabled = true

  # O endpoint /health é raspado pelo probe a cada poucos segundos; se a
  # aplicação está viva, esta contagem nunca é zero por um minuto inteiro.
  nrql {
    query = <<-EOT
      SELECT count(autogiro_app_info)
      FROM Metric
      WHERE metricName = 'autogiro_app_info'
    EOT
  }

  critical {
    operator              = "below"
    threshold             = 1
    threshold_duration    = 300 # 5 min: acima do intervalo de scrape do agente.
    threshold_occurrences = "ALL"
  }

  aggregation_window             = 60
  aggregation_method             = "event_flow"
  aggregation_delay              = 120
  fill_option                    = "static"
  fill_value                     = 0 # Sem dado = zero, não "ignorar".
  violation_time_limit_seconds   = 259200
  expiration_duration            = 300
  open_violation_on_expiration   = true
  close_violations_on_expiration = true
}

# ─── 2. Taxa de erro 5xx acima de 5% ─────────────────────────────────────────
# Espelha TaxaDeErro5xxAlta. `filter(...)` isola os 5xx dentro da mesma
# agregação, reproduzindo o numerador/denominador do PromQL sem precisar de
# duas séries separadas.
resource "newrelic_nrql_alert_condition" "taxa_erro_5xx" {
  count = var.new_relic_api_key == "" ? 0 : 1

  account_id  = var.new_relic_account_id
  policy_id   = newrelic_alert_policy.autogiro[0].id
  name        = "Taxa de erro 5xx acima de 5%"
  description = "Mais de 5% das requisições retornando erro do servidor por 5 minutos."
  type        = "static"
  enabled     = true

  nrql {
    query = <<-EOT
      SELECT filter(sum(autogiro_http_requests_total), WHERE status_code LIKE '5%')
           / sum(autogiro_http_requests_total) * 100
      FROM Metric
      WHERE metricName = 'autogiro_http_requests_total'
    EOT
  }

  critical {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 300 # `for: 5m` do Prometheus.
    threshold_occurrences = "ALL"
  }

  # Aviso antecipado em 2%: dá tempo de investigar antes de furar o SLO.
  warning {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }

  aggregation_window           = 60
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  violation_time_limit_seconds = 259200
}

# ─── 3. Latência p95 acima do SLO de 300 ms ──────────────────────────────────
# Espelha LatenciaP95Degradada. O New Relic reconhece o tipo Histogram da
# métrica Prometheus, então percentile() opera direto sobre o nome base, sem
# reconstruir o histogram_quantile a partir das séries `_bucket`.
resource "newrelic_nrql_alert_condition" "latencia_p95" {
  count = var.new_relic_api_key == "" ? 0 : 1

  account_id  = var.new_relic_account_id
  policy_id   = newrelic_alert_policy.autogiro[0].id
  name        = "Latência p95 acima do SLO (300 ms)"
  description = "p95 da duração das requisições HTTP acima de 0,3 s por 10 minutos."
  type        = "static"
  enabled     = true

  nrql {
    query = <<-EOT
      SELECT percentile(autogiro_http_request_duration_seconds, 95)
      FROM Metric
      WHERE metricName = 'autogiro_http_request_duration_seconds'
    EOT
  }

  # SLO do projeto: p95 < 300 ms. Como o valor da métrica está em segundos,
  # o limiar é 0.3.
  critical {
    operator              = "above"
    threshold             = 0.3
    threshold_duration    = 600 # `for: 10m` do Prometheus.
    threshold_occurrences = "ALL"
  }

  warning {
    operator              = "above"
    threshold             = 0.2
    threshold_duration    = 600
    threshold_occurrences = "ALL"
  }

  aggregation_window           = 60
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  violation_time_limit_seconds = 259200
}

# ─── 4. Falha no processamento de ordens de serviço ──────────────────────────
# Exigido nominalmente pelo enunciado. Espelha FalhaNoEnvioDeNotificacoes:
# quando a notificação de mudança de status falha, o cliente não é avisado do
# andamento da OS — é uma falha de processamento visível para o negócio.
resource "newrelic_nrql_alert_condition" "falha_processamento_os" {
  count = var.new_relic_api_key == "" ? 0 : 1

  account_id = var.new_relic_account_id
  policy_id  = newrelic_alert_policy.autogiro[0].id
  name       = "Falha no processamento de ordens de serviço"
  description = join(" ", [
    "Notificações de mudança de status da OS estão falhando;",
    "os clientes podem não estar sendo avisados do andamento do serviço."
  ])
  type    = "static"
  enabled = true

  # FACET channel: separa a falha do canal de e-mail da do canal de log, para
  # que o incidente aponte direto a integração quebrada.
  nrql {
    query = <<-EOT
      SELECT sum(autogiro_notifications_total)
      FROM Metric
      WHERE metricName = 'autogiro_notifications_total'
      AND result = 'failed'
      FACET channel
    EOT
  }

  # Mesmo limiar do Prometheus: mais de 3 falhas na janela de observação.
  critical {
    operator              = "above"
    threshold             = 3
    threshold_duration    = 300
    threshold_occurrences = "AT_LEAST_ONCE"
  }

  aggregation_window           = 300 # Janela de 5 min, como o increase[15m]/3.
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  fill_option                  = "static"
  fill_value                   = 0 # Sem falhas reportadas = zero falhas.
  violation_time_limit_seconds = 259200
}

# ─── 5. Exceções não tratadas ────────────────────────────────────────────────
# Espelha ExcecoesNaoTratadas: qualquer exceção que vaze até o middleware é um
# defeito, então o limiar é "acima de zero".
resource "newrelic_nrql_alert_condition" "excecoes_nao_tratadas" {
  count = var.new_relic_api_key == "" ? 0 : 1

  account_id  = var.new_relic_account_id
  policy_id   = newrelic_alert_policy.autogiro[0].id
  name        = "Exceções não tratadas na API"
  description = "Exceção propagada até o middleware — indica defeito não previsto no código."
  type        = "static"
  enabled     = true

  nrql {
    query = <<-EOT
      SELECT sum(autogiro_http_exceptions_total)
      FROM Metric
      WHERE metricName = 'autogiro_http_exceptions_total'
      FACET exception, endpoint
    EOT
  }

  warning {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 300
    threshold_occurrences = "AT_LEAST_ONCE"
  }

  aggregation_window           = 300
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  fill_option                  = "static"
  fill_value                   = 0
  violation_time_limit_seconds = 259200
}

# ─── Notificação por e-mail ──────────────────────────────────────────────────
# O destino guarda o endereço; o canal define o formato da mensagem; o workflow
# liga a policy ao canal. Os três precisam existir para que o alerta saia da
# plataforma e chegue a alguém.

resource "newrelic_notification_destination" "email" {
  count = var.new_relic_api_key == "" || var.alert_email == "" ? 0 : 1

  account_id = var.new_relic_account_id
  name       = "AutoGiro — E-mail de plantão"
  type       = "EMAIL"

  property {
    key   = "email"
    value = var.alert_email
  }
}

resource "newrelic_notification_channel" "email" {
  count = var.new_relic_api_key == "" || var.alert_email == "" ? 0 : 1

  account_id     = var.new_relic_account_id
  name           = "AutoGiro — Canal de e-mail"
  type           = "EMAIL"
  destination_id = newrelic_notification_destination.email[0].id
  product        = "IINT" # Workflows de alerta (Applied Intelligence).

  # Assunto com o nome do incidente: quem recebe entende o problema sem abrir
  # o e-mail. `subject` e `customDetailsEmail` são os campos do payload EMAIL.
  property {
    key   = "subject"
    value = "[AutoGiro] {{ issueTitle }}"
  }

  property {
    key   = "customDetailsEmail"
    value = "Prioridade: {{ priority }} — Estado: {{ state }} — Abertura: {{ createdAt }}"
  }
}

resource "newrelic_workflow" "autogiro" {
  count = var.new_relic_api_key == "" || var.alert_email == "" ? 0 : 1

  account_id            = var.new_relic_account_id
  name                  = "AutoGiro — Notificação de incidentes"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  # Filtra apenas os incidentes abertos pela policy do AutoGiro, para que o
  # workflow não capture alertas de outras aplicações da mesma conta.
  issues_filter {
    name = "Incidentes da policy AutoGiro"
    type = "FILTER"

    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.autogiro[0].id]
    }
  }

  destination {
    channel_id = newrelic_notification_channel.email[0].id
  }
}
