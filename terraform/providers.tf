provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "autogiro"
      ManagedBy   = "terraform"
      Environment = "academico"
    }
  }
}

# ─── Acesso ao cluster ───────────────────────────────────────────────────────
# Os providers kubernetes, helm e kubectl autenticam no EKS com um token de
# curta duração obtido pelo `aws eks get-token`. O bloco `exec` roda a cada
# operação, de modo que o token nunca fica gravado no state (ao contrário de
# um data source, que persistiria o valor).
#
# Requisito: AWS CLI v2 no PATH e credenciais válidas no ambiente.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
    }
  }
}

# load_config_file=false impede que o provider tente ler um kubeconfig do disco.
provider "kubectl" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
  }
}

# Provider do New Relic (API NerdGraph). Quando a chave nao e informada os
# recursos ficam com count = 0 e o provider nunca chega a ser chamado, o que
# mantem o `terraform plan` do CI funcionando sem credenciais.
provider "newrelic" {
  account_id = var.new_relic_account_id
  api_key    = var.new_relic_api_key
  region     = "US"
}
