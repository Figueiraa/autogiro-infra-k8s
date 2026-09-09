# ═══════════════════════════════════════════════════════════════════════════
# Cluster Kubernetes gerenciado (AWS EKS)
#
# Substitui o cluster kind local. O enunciado exige um cluster com
# escalabilidade rodando em nuvem e provisionado por Terraform.
#
# ─── Premissas de custo ─────────────────────────────────────────────────────
# O ambiente é acadêmico e efêmero: sobe alguns dias antes da entrega e é
# destruído logo depois, com orçamento de aproximadamente US$200 em créditos.
# Todas as decisões abaixo priorizam custo sobre postura de produção, e cada
# desvio está documentado no ponto onde é feito.
#
# Usa os recursos nativos aws_eks_cluster / aws_eks_node_group em vez do módulo
# terraform-aws-modules/eks: o módulo cria por padrão subnets privadas com NAT
# Gateway, KMS próprio para os secrets e grupos de log no CloudWatch — tudo
# cobrado à parte e desnecessário aqui.
# ═══════════════════════════════════════════════════════════════════════════

data "aws_availability_zones" "available" {
  state = "available"
}

# ─── Rede ────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"

  # O EKS exige resolução e nomes de DNS habilitados na VPC.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# DECISÃO DE CUSTO: duas subnets PÚBLICAS, sem NAT Gateway.
#
# O NAT Gateway custa cerca de US$0,045/h mais tráfego processado — algo em
# torno de US$8,60 em 8 dias de cluster, sem contar os dados. Com os nós em
# subnet pública e IP público automático, eles alcançam a internet (registry de
# imagens, endpoint do EKS, ingestão do New Relic) pelo Internet Gateway, que
# não tem custo por hora.
#
# EM PRODUÇÃO ISTO SERIA DIFERENTE: os nós ficariam em subnets privadas, com
# NAT Gateway (ou VPC endpoints) para a saída, e apenas o Load Balancer viveria
# na subnet pública. Aqui a exposição é mitigada pelo security group do node
# group, gerenciado pelo próprio EKS, que não abre portas para 0.0.0.0/0.
#
# São duas AZs porque o EKS recusa criar o control plane com menos que isso.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(aws_vpc.this.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-${count.index}"
    # Sinaliza ao controlador de serviços da AWS que ele pode criar
    # Load Balancers voltados para a internet nestas subnets (o Kong usa).
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ─── IAM: role do control plane ──────────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_eks" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ─── IAM: role dos nós ───────────────────────────────────────────────────────
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Registro do nó no control plane.
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# CNI da AWS: atribui os ENIs e IPs usados pelos pods.
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Pull das imagens da aplicação no ECR.
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ─── Control plane ───────────────────────────────────────────────────────────
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # DECISÃO DE CUSTO: nenhum tipo de log do control plane habilitado.
  # Cada tipo vira um log group no CloudWatch, cobrado por GB ingerido e
  # armazenado. A observabilidade do projeto (requisito R9) vem do New Relic,
  # que coleta logs e métricas de dentro do cluster.
  enabled_cluster_log_types = []

  vpc_config {
    subnet_ids = aws_subnet.public[*].id

    # Endpoint público: o Terraform e o kubectl rodam fora da VPC (máquina
    # local e runner do CI), então precisam alcançar a API do cluster.
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  # A role precisa ter as políticas anexadas ANTES da criação do cluster,
  # senão o EKS falha ao provisionar os ENIs do control plane.
  depends_on = [aws_iam_role_policy_attachment.cluster_eks]

  tags = {
    Name = var.cluster_name
  }
}

# ─── Node group gerenciado ───────────────────────────────────────────────────
# DECISÃO DE CUSTO: instâncias Graviton (ARM). A t4g.small custa cerca de
# US$0,0168/h contra US$0,0208/h da t3.small equivalente em x86 — perto de 20%
# a menos pela mesma capacidade. Exige que a imagem dos nós seja ARM
# (AL2023_ARM_64_STANDARD) e que as imagens da aplicação tenham build arm64.
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id

  instance_types = [var.node_instance_type]
  ami_type       = "AL2023_ARM_64_STANDARD"
  disk_size      = 20
  capacity_type  = "ON_DEMAND"

  # O HPA da aplicação escala PODS (2 a 10). Este bloco escala NÓS: dois nós
  # sustentam a carga normal e o teto de quatro dá folga para o HPA agendar as
  # réplicas extras durante a demonstração de escalabilidade.
  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  # desired_size passa a ser gerenciado pelo cluster depois da criação; sem
  # isto, um scale-out manual ou automático apareceria como drift no plan.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = {
    Name = "${var.cluster_name}-nodes"
  }
}

# ─── Acesso ao gateway ───────────────────────────────────────────────────────
# O EKS cria um security group proprio para os nos, que por padrao so aceita
# trafego interno do cluster. Como o Kong e exposto por NodePort (esta conta nao
# permite criar Load Balancers), a porta precisa ser liberada explicitamente.
#
# `cidr_blocks = ["0.0.0.0/0"]` e o que torna o gateway publicamente acessivel —
# e o que o enunciado pede de um API Gateway. As rotas de negocio atras dele
# seguem protegidas pelo plugin JWT do Kong; o que fica aberto e a porta, nao a API.
resource "aws_security_group_rule" "kong_node_port" {
  type              = "ingress"
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  from_port         = var.kong_node_port
  to_port           = var.kong_node_port
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Proxy do Kong exposto por NodePort"
}

# Instancias do node group, para expor os IPs publicos nos outputs. Depende do
# node group estar pronto, senao a consulta volta vazia.
data "aws_instances" "nodes" {
  instance_tags = {
    "eks:cluster-name" = aws_eks_cluster.this.name
  }

  instance_state_names = ["running"]

  depends_on = [aws_eks_node_group.this]
}
