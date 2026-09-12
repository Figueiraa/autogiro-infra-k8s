# ─── Dashboards do New Relic ─────────────────────────────────────────────────
# As métricas da aplicação são expostas em /metrics no formato Prometheus e
# coletadas pelo `newrelic-prometheus-agent` (habilitado no nri-bundle, main.tf).
#
# No New Relic toda métrica Prometheus cai na tabela `Metric`, com o nome da
# métrica como atributo e os labels do Prometheus como dimensões. Por isso as
# consultas seguem sempre a forma:
#
#     SELECT <agregacao> FROM Metric WHERE metricName = 'autogiro_...'
#
# Equivalências de PromQL usadas aqui:
#   rate(counter[5m])            -> rate(sum(metrica), 1 second)
#   increase(counter[24h])       -> sum(metrica) com janela de 24h
#   histogram_quantile(0.95, …)  -> percentile(metrica, 95) sobre o histograma
#
# O recurso é condicional: sem a User API key nada é criado, o que mantém o
# `terraform plan` do CI funcionando sem credenciais (mesmo padrão do
# helm_release.new_relic em main.tf).

resource "newrelic_one_dashboard" "autogiro" {
  count = var.new_relic_api_key == "" ? 0 : 1

  name        = "AutoGiro — Operação da Oficina"
  description = "Indicadores de negócio, saúde da API e infraestrutura da plataforma AutoGiro."
  permissions = "public_read_write"

  # ═══ Página 1: Indicadores de negócio ══════════════════════════════════════
  # Os três primeiros widgets são os exigidos nominalmente pelo enunciado.
  page {
    name        = "Indicadores de negócio"
    description = "Visão da operação da oficina: volume de OS, tempo por status e falhas de integração."

    # ── Widget 1: volume diário de ordens de serviço ────────────────────────
    # `autogiro_service_orders_opened_total` é um Counter sem labels. O agente
    # Prometheus o converte em métrica cumulativa, então usamos `sum` com
    # TIMESERIES de 1 dia para obter o volume por dia, como no painel
    # "OS abertas (24h)" do Grafana (increase[24h]).
    widget_area {
      title  = "Volume diário de ordens de serviço"
      row    = 1
      column = 1
      width  = 8
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_service_orders_opened_total)
          FROM Metric
          WHERE metricName = 'autogiro_service_orders_opened_total'
          SINCE 30 days ago
          TIMESERIES 1 day
        EOT
      }
    }

    # Contador acumulado do período, para leitura rápida do total.
    widget_billboard {
      title  = "OS abertas no período"
      row    = 1
      column = 9
      width  = 4
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_service_orders_opened_total) AS 'OS abertas'
          FROM Metric
          WHERE metricName = 'autogiro_service_orders_opened_total'
          SINCE 1 day ago
        EOT
      }
    }

    # ── Widget 2: tempo médio de execução por status ────────────────────────
    # Usa o histograma `autogiro_service_order_status_duration_seconds`, que
    # mede quanto tempo a OS permaneceu em cada status antes de sair dele.
    #
    # Média = soma das durações / número de observações. O agente Prometheus
    # expõe as séries `_sum` e `_count` do histograma como métricas próprias,
    # então a média por status é sum(_sum)/sum(_count).
    #
    # A unidade é **segundos**, e a janela é curta (3 horas) de propósito.
    #
    # Em produção o ciclo de uma OS leva horas, e faria sentido dividir por 3600.
    # Mas o painel também precisa ser legível com dados de demonstração, em que
    # as transições acontecem em segundos — e um widget que exibe "0" é
    # indistinguível de um sem dados, que foi o que aconteceu: 0,00012 h.
    #
    # A janela de 3 horas evita que a média seja diluída por lotes antigos de
    # massa gerada em sequência imediata. Medido em 12/09/2026, mesmo status:
    # 2,98 s em 30 min · 1,14 s em 2 h · 0,46 s em 7 dias.
    #
    # Em produção, com OS reais, trocar para `/ 3600 AS 'Horas em média'` e
    # `SINCE 7 days ago`.
    widget_bar {
      title  = "Tempo médio de execução por status (segundos)"
      row    = 4
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_service_order_status_duration_seconds_sum)
               / sum(autogiro_service_order_status_duration_seconds_count)
               AS 'Segundos em média'
          FROM Metric
          WHERE metricName IN (
            'autogiro_service_order_status_duration_seconds_sum',
            'autogiro_service_order_status_duration_seconds_count'
          )
          AND status IN ('EM_DIAGNOSTICO', 'EM_EXECUCAO', 'FINALIZADA')
          FACET status
          SINCE 3 hours ago
        EOT
      }
    }

    # Evolução do tempo médio por status ao longo do tempo: revela gargalos
    # que aparecem só em determinados dias (ex.: fila de diagnóstico crescendo).
    widget_line {
      title  = "Evolução do tempo por status (segundos)"
      row    = 4
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_service_order_status_duration_seconds_sum)
               / sum(autogiro_service_order_status_duration_seconds_count)
               AS 'Segundos em média'
          FROM Metric
          WHERE metricName IN (
            'autogiro_service_order_status_duration_seconds_sum',
            'autogiro_service_order_status_duration_seconds_count'
          )
          AND status IN ('EM_DIAGNOSTICO', 'EM_EXECUCAO', 'FINALIZADA')
          FACET status
          SINCE 3 hours ago
          TIMESERIES 1 hour
        EOT
      }
    }

    # ── Widget 3: erros e falhas nas integrações ───────────────────────────
    # Duas fontes de falha de integração:
    #   * `autogiro_notifications_total{result="failed"}` — o cliente não foi
    #     avisado da mudança de status da OS (integração de e-mail).
    #   * `autogiro_http_exceptions_total` — exceção não tratada que vazou até
    #     o middleware, tipicamente falha ao chamar um recurso externo.
    widget_billboard {
      title  = "Falhas de notificação (24h)"
      row    = 7
      column = 1
      width  = 4
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_notifications_total) AS 'Falhas'
          FROM Metric
          WHERE metricName = 'autogiro_notifications_total'
          AND result = 'failed'
          SINCE 1 day ago
        EOT
      }

      # Qualquer falha de notificação já merece atenção; 3 ou mais é o mesmo
      # limiar do alerta FalhaNoEnvioDeNotificacoes no Prometheus.
      warning  = 1
      critical = 3
    }

    widget_line {
      title  = "Erros e falhas nas integrações"
      row    = 7
      column = 5
      width  = 8
      height = 3

      # Série 1: notificações que falharam, por canal.
      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_notifications_total) AS 'Notificações falhadas'
          FROM Metric
          WHERE metricName = 'autogiro_notifications_total'
          AND result = 'failed'
          FACET channel
          SINCE 1 day ago
          TIMESERIES
        EOT
      }

      # Série 2: exceções não tratadas, por tipo de exceção.
      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_http_exceptions_total) AS 'Exceções não tratadas'
          FROM Metric
          WHERE metricName = 'autogiro_http_exceptions_total'
          FACET exception
          SINCE 1 day ago
          TIMESERIES
        EOT
      }
    }

    # ── Contexto de negócio adicional ───────────────────────────────────────
    # Transições de status: mostra por onde as OS estão passando.
    widget_stacked_bar {
      title  = "Transições de status das OS"
      row    = 10
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_service_order_status_transitions_total)
          FROM Metric
          WHERE metricName = 'autogiro_service_order_status_transitions_total'
          FACET status
          SINCE 7 days ago
          TIMESERIES 1 day
        EOT
      }
    }

    # Taxa de aprovação de orçamentos: label `result` = approved | refused.
    widget_pie {
      title  = "Orçamentos aprovados x recusados"
      row    = 10
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_budget_approvals_total)
          FROM Metric
          WHERE metricName = 'autogiro_budget_approvals_total'
          FACET result
          SINCE 7 days ago
        EOT
      }
    }
  }

  # ═══ Página 2: Saúde da API (método RED) ═══════════════════════════════════
  page {
    name        = "Saúde da API"
    description = "Rate, Errors e Duration da API, espelhando o dashboard Grafana autogiro-api."

    # ── Latência p95 / p99 ──────────────────────────────────────────────────
    # `autogiro_http_request_duration_seconds` é um Histogram do Prometheus, e o
    # agente o ingere decomposto em `_bucket`, `_sum` e `_count` — o nome base
    # NÃO existe como métrica no New Relic.
    #
    # Por isso o percentil se calcula com `histogramPercentile()` sobre a série
    # `_bucket`. Usar `percentile()` sobre o nome base não dá erro: devolve
    # **0.0**, que é pior que falhar — o painel mostra latência zero e parece
    # saudável. Verificado em 12/09/2026: `percentile(...)` = 0.0 enquanto
    # `histogramPercentile(..._bucket)` = 0.095 s no mesmo intervalo.
    #
    # SLO do projeto: p95 < 300 ms (0.3 s).
    widget_line {
      title  = "Latência p95 e p99 (SLO: p95 < 300 ms)"
      row    = 1
      column = 1
      width  = 8
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT histogramPercentile(autogiro_http_request_duration_seconds_bucket, 95, 99)
          FROM Metric
          WHERE metricName = 'autogiro_http_request_duration_seconds_bucket'
          SINCE 3 hours ago
          TIMESERIES
        EOT
      }
    }

    widget_billboard {
      title  = "p95 atual (segundos)"
      row    = 1
      column = 9
      width  = 4
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT histogramPercentile(autogiro_http_request_duration_seconds_bucket, 95) AS 'p95'
          FROM Metric
          WHERE metricName = 'autogiro_http_request_duration_seconds_bucket'
          SINCE 10 minutes ago
        EOT
      }

      # Alinhado ao SLO: alerta visual a partir de 300 ms, crítico em 500 ms.
      warning  = 0.3
      critical = 0.5
    }

    # ── Taxa de erro 5xx ────────────────────────────────────────────────────
    # `filter(...)` isola as requisições 5xx dentro da mesma agregação, o que
    # equivale ao numerador/denominador do PromQL. `status_code LIKE '5%'`
    # substitui o regex `5..` do Prometheus.
    widget_line {
      title  = "Taxa de erro 5xx (%)"
      row    = 4
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT filter(sum(autogiro_http_requests_total), WHERE status_code LIKE '5%')
               / sum(autogiro_http_requests_total) * 100 AS 'Erro 5xx (%)'
          FROM Metric
          WHERE metricName = 'autogiro_http_requests_total'
          SINCE 3 hours ago
          TIMESERIES
        EOT
      }
    }

    # ── Requisições por segundo ─────────────────────────────────────────────
    # rate(..., 1 second) sobre o counter reproduz o rate() do PromQL.
    widget_line {
      title  = "Requisições por segundo"
      row    = 4
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT rate(sum(autogiro_http_requests_total), 1 second) AS 'req/s'
          FROM Metric
          WHERE metricName = 'autogiro_http_requests_total'
          SINCE 3 hours ago
          TIMESERIES
        EOT
      }
    }

    # ── Requisições em andamento ────────────────────────────────────────────
    # Gauge: usa latest() por endpoint, e não sum() acumulado.
    widget_line {
      title  = "Requisições em andamento"
      row    = 7
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT latest(autogiro_http_requests_in_progress) AS 'Em voo'
          FROM Metric
          WHERE metricName = 'autogiro_http_requests_in_progress'
          SINCE 1 hour ago
          TIMESERIES
        EOT
      }
    }

    # Throughput por família de status HTTP (2xx, 4xx, 5xx).
    widget_stacked_bar {
      title  = "Throughput por status HTTP"
      row    = 7
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT rate(sum(autogiro_http_requests_total), 1 second)
          FROM Metric
          WHERE metricName = 'autogiro_http_requests_total'
          FACET status_code
          SINCE 3 hours ago
          TIMESERIES
        EOT
      }
    }

    # Endpoints mais lentos: equivalente ao topk(10, ...) do Grafana.
    widget_table {
      title  = "Endpoints mais lentos (p95)"
      row    = 10
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT histogramPercentile(autogiro_http_request_duration_seconds_bucket, 95) AS 'p95 (s)'
          FROM Metric
          WHERE metricName = 'autogiro_http_request_duration_seconds_bucket'
          FACET endpoint
          SINCE 1 hour ago
          LIMIT 10
        EOT
      }
    }

    widget_table {
      title  = "Exceções não tratadas por endpoint"
      row    = 10
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(autogiro_http_exceptions_total) AS 'Ocorrências'
          FROM Metric
          WHERE metricName = 'autogiro_http_exceptions_total'
          FACET exception, endpoint
          SINCE 1 day ago
          LIMIT 20
        EOT
      }
    }
  }

  # ═══ Página 3: Infraestrutura ══════════════════════════════════════════════
  # Estas métricas NÃO vêm do Prometheus: são coletadas pelo agente de
  # infraestrutura do New Relic (nri-kubernetes, dentro do nri-bundle) e ficam
  # no evento `K8sContainerSample`, não na tabela `Metric`. O filtro por
  # `clusterName` isola o cluster do AutoGiro de qualquer outro na mesma conta.
  page {
    name        = "Infraestrutura"
    description = "CPU e memória dos pods do cluster Kubernetes (agente de infra do New Relic)."

    widget_line {
      title  = "CPU por pod (cores)"
      row    = 1
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT average(cpuUsedCores) AS 'Cores'
          FROM K8sContainerSample
          WHERE clusterName = '${var.new_relic_cluster_name}'
          AND namespaceName = '${var.namespace}'
          FACET podName
          SINCE 3 hours ago
          TIMESERIES
        EOT
      }
    }

    widget_line {
      title  = "Memória por pod (MiB)"
      row    = 1
      column = 7
      width  = 6
      height = 3

      # Divisão por 1024^2 converte bytes em MiB, que é a unidade dos limites
      # declarados no Deployment.
      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT average(memoryUsedBytes) / 1048576 AS 'MiB'
          FROM K8sContainerSample
          WHERE clusterName = '${var.new_relic_cluster_name}'
          AND namespaceName = '${var.namespace}'
          FACET podName
          SINCE 3 hours ago
          TIMESERIES
        EOT
      }
    }

    # Uso relativo ao limite: é o sinal que o HPA observa e o que antecede
    # throttling de CPU ou OOMKill.
    widget_billboard {
      title  = "CPU média x limite (%)"
      row    = 4
      column = 1
      width  = 3
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT average(cpuUsedCores) / average(cpuLimitCores) * 100 AS 'CPU (%)'
          FROM K8sContainerSample
          WHERE clusterName = '${var.new_relic_cluster_name}'
          AND namespaceName = '${var.namespace}'
          SINCE 30 minutes ago
        EOT
      }

      warning  = 70
      critical = 90
    }

    widget_billboard {
      title  = "Memória média x limite (%)"
      row    = 4
      column = 4
      width  = 3
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT average(memoryUsedBytes) / average(memoryLimitBytes) * 100 AS 'Memória (%)'
          FROM K8sContainerSample
          WHERE clusterName = '${var.new_relic_cluster_name}'
          AND namespaceName = '${var.namespace}'
          SINCE 30 minutes ago
        EOT
      }

      warning  = 70
      critical = 90
    }

    # uniqueCount de podName revela variações de réplica causadas pelo HPA.
    widget_line {
      title  = "Réplicas em execução (efeito do HPA)"
      row    = 4
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT uniqueCount(podName) AS 'Pods'
          FROM K8sContainerSample
          WHERE clusterName = '${var.new_relic_cluster_name}'
          AND namespaceName = '${var.namespace}'
          SINCE 6 hours ago
          TIMESERIES
        EOT
      }
    }

    # Reinícios acumulados por container: detecta CrashLoopBackOff e OOMKill.
    widget_table {
      title  = "Reinícios de container"
      row    = 7
      column = 1
      width  = 12
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT latest(restartCount) AS 'Reinícios',
                 latest(status) AS 'Status'
          FROM K8sContainerSample
          WHERE clusterName = '${var.new_relic_cluster_name}'
          FACET podName, containerName
          SINCE 1 day ago
          LIMIT 30
        EOT
      }
    }
  }

  # ═══════════════════════════════════════════════════════════════════════════
  # API Gateway
  #
  # Métricas publicadas pelo próprio Kong, e não pela aplicação. A distinção
  # importa: a aplicação só enxerga o que chegou até ela, enquanto o gateway
  # enxerga também o que barrou na borda. Um 401 por token ausente aparece aqui
  # com `source = 'kong'` e não existe em nenhuma métrica do autogiro-api.
  # ═══════════════════════════════════════════════════════════════════════════
  page {
    name        = "API Gateway (Kong)"
    description = "Tráfego, latência e bloqueios vistos do gateway — o que a aplicação não enxerga."

    # ── Requisições por código HTTP ─────────────────────────────────────────
    widget_line {
      title  = "Requisições por código HTTP"
      row    = 1
      column = 1
      width  = 8
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT rate(sum(kong_http_requests_total), 1 minute)
          FROM Metric
          WHERE metricName = 'kong_http_requests_total'
          FACET code
          SINCE 3 hours ago
          TIMESERIES
        EOT
      }
    }

    # `source` separa quem respondeu: 'kong' é resposta do gateway (o plugin de
    # JWT rejeitando), 'service' é resposta da aplicação. É a leitura direta de
    # "o gateway está protegendo as rotas".
    widget_billboard {
      title  = "Bloqueados pelo gateway (source = kong)"
      row    = 1
      column = 9
      width  = 4
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(kong_http_requests_total) AS 'Barrados na borda'
          FROM Metric
          WHERE metricName = 'kong_http_requests_total'
            AND source = 'kong'
          SINCE 3 hours ago
        EOT
      }
    }

    # ── Latência: gateway vs. aplicação ─────────────────────────────────────
    # A separação entre as duas responde "quem está lento": `kong_latency` é o
    # tempo gasto dentro do gateway (roteamento e plugins), `upstream_latency` é
    # o tempo que a aplicação levou para responder.
    widget_line {
      title  = "Latência no gateway vs. no upstream (ms)"
      row    = 4
      column = 1
      width  = 8
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT average(kong_kong_latency_ms_sum) / average(kong_kong_latency_ms_count) AS 'Gateway',
                 average(kong_upstream_latency_ms_sum) / average(kong_upstream_latency_ms_count) AS 'Aplicação'
          FROM Metric
          SINCE 3 hours ago
          TIMESERIES
        EOT
      }
    }

    widget_billboard {
      title  = "Conexões ativas no Kong"
      row    = 4
      column = 9
      width  = 4
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT latest(kong_nginx_connections_total) AS 'Ativas'
          FROM Metric
          WHERE metricName = 'kong_nginx_connections_total'
            AND state = 'active'
          SINCE 10 minutes ago
        EOT
      }
    }

    # ── Tráfego por rota ────────────────────────────────────────────────────
    # Separa a rota pública (/health, /docs) da protegida (/api/v1), mostrando
    # que são dois Ingresses com políticas diferentes no mesmo gateway.
    widget_table {
      title  = "Tráfego por rota e código"
      row    = 7
      column = 1
      width  = 12
      height = 3

      nrql_query {
        account_id = var.new_relic_account_id
        query      = <<-EOT
          SELECT sum(kong_http_requests_total) AS 'Requisições'
          FROM Metric
          WHERE metricName = 'kong_http_requests_total'
          FACET route, code, source
          SINCE 3 hours ago
          LIMIT 30
        EOT
      }
    }
  }
}
