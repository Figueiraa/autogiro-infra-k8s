# Provider do kind (cluster Kubernetes local em Docker).
provider "kind" {}

# Os providers kubernetes e helm usam as credenciais do cluster criado pelo
# recurso kind_cluster.this (dependência implícita).
provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}

# Mesmas credenciais do provider kubernetes. load_config_file=false impede que
# ele tente ler um kubeconfig do disco.
provider "kubectl" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  load_config_file       = false
}

# Provider do New Relic (API NerdGraph). Quando a chave nao e informada os
# recursos ficam com count = 0 e o provider nunca chega a ser chamado, o que
# mantem o `terraform plan` do CI funcionando sem credenciais.
provider "newrelic" {
  account_id = var.new_relic_account_id
  api_key    = var.new_relic_api_key
  region     = "US"
}
