# State local — decisão deliberada, ao contrário dos outros dois repos de infra.
#
# `autogiro-auth` e `autogiro-infra-db` usam HCP Terraform porque criam recursos
# persistentes na nuvem (Lambda + IAM role, projeto Neon) que precisam ser
# reconhecidos entre execuções da pipeline.
#
# Aqui não:
#
#   * No CI, o job `Cluster smoke test` cria o cluster e o destrói no mesmo job
#     (`terraform destroy` com `if: always()`). O state nasce e morre ali — um
#     backend remoto não teria nada a preservar e dois jobs concorrentes
#     disputariam o mesmo workspace.
#
#   * No deploy, o cluster é kind rodando na máquina local, então o state vive no
#     disco dessa máquina, que é exatamente onde o cluster também vive. Guardá-lo
#     remotamente separaria o state do recurso que ele descreve.
#
# Se algum dia o cluster migrar para um Kubernetes gerenciado, este arquivo passa a
# declarar o mesmo bloco `cloud` dos outros repos.
