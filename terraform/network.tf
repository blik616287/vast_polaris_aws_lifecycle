# =============================================================================
# VAST on Cloud (VoC) connective network — self-contained & parameterized.
# Creates the VPC/subnets/NAT/IGW/S3-endpoint/SG that you hand to
# `vastcloud cluster create`. Does NOT create the VAST instances (Polaris does)
# or any Kubernetes cluster. Peering to an existing k8s VPC is optional.
#
# Bakes in every lesson from the first bring-up:
#   - SG opens all VAST client ports AND self-references for intra-cluster comms
#   - S3 gateway endpoint (VoC nodes in private subnets need S3; pre-checker fails without it)
#   - single or per-AZ NAT for private-subnet egress
# Workflow: terraform plan -> review -> terraform apply (never auto-apply).
# =============================================================================

locals {
  # Who may reach VAST VIPs/VMS. Default: in-VPC clients. Add peer CIDR when peering.
  client_cidrs = distinct(concat(
    length(var.vast_client_cidrs) > 0 ? var.vast_client_cidrs : [var.vast_vpc_cidr],
    var.enable_peering && var.peer_vpc_cidr != "" ? [var.peer_vpc_cidr] : []
  ))

  client_tcp_ports = concat(var.vast_nfs_ports, var.vast_mgmt_ports, var.vast_nvme_ports, [var.vast_ssh_port])

  # Flatten (port x cidr) for per-rule for_each.
  client_ingress = {
    for pair in setproduct(local.client_tcp_ports, local.client_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  nat_azs = var.single_nat ? [var.azs[0]] : var.azs
}

# ---------------------------------------------------------------------------
# VPC + subnets
# ---------------------------------------------------------------------------
resource "aws_vpc" "vast" {
  cidr_block           = var.vast_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "vast-voc-${var.environment}" }
}

resource "aws_subnet" "private" {
  for_each          = { for i, az in var.azs : az => i }
  vpc_id            = aws_vpc.vast.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vast_vpc_cidr, var.private_subnet_newbits, each.value)
  tags              = { Name = "vast-private-${each.key}" }
}

resource "aws_subnet" "public" {
  for_each                = { for i, az in var.azs : az => i }
  vpc_id                  = aws_vpc.vast.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vast_vpc_cidr, var.public_subnet_newbits, each.value + 200)
  map_public_ip_on_launch = true
  tags                    = { Name = "vast-public-${each.key}" }
}

# ---------------------------------------------------------------------------
# IGW + NAT
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "vast" {
  vpc_id = aws_vpc.vast.id
  tags   = { Name = "vast-igw-${var.environment}" }
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"
  tags     = { Name = "vast-nat-${each.key}" }
}

resource "aws_nat_gateway" "vast" {
  for_each      = toset(local.nat_azs)
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = { Name = "vast-nat-${each.key}" }
  depends_on    = [aws_internet_gateway.vast]
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vast.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vast.id
  }
  tags = { Name = "vast-public-rt-${var.environment}" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id   = aws_vpc.vast.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.vast[var.single_nat ? var.azs[0] : each.key].id
  }
  tags = { Name = "vast-private-rt-${each.key}" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint — REQUIRED. VoC nodes in private subnets need S3 (state
# bucket, AMIs, callhome); the deploy pre-checker's "S3 gateway" probe fails
# from a private subnet without it. Free.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.vast.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([for rt in aws_route_table.private : rt.id], [aws_route_table.public.id])
  tags              = { Name = "vast-s3-gateway-${var.environment}" }
}

# ---------------------------------------------------------------------------
# Optional VPC peering to an existing k8s VPC
# ---------------------------------------------------------------------------
resource "aws_vpc_peering_connection" "peer" {
  count       = var.enable_peering ? 1 : 0
  vpc_id      = aws_vpc.vast.id
  peer_vpc_id = var.peer_vpc_id
  auto_accept = true
  tags        = { Name = "vast-to-${var.environment}-peer" }
}

# Return routes in the peered VPC -> VAST VPC
resource "aws_route" "peer_to_vast" {
  for_each                  = var.enable_peering ? toset(var.peer_route_table_ids) : toset([])
  route_table_id            = each.value
  destination_cidr_block    = var.vast_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

# VAST VPC -> peer routes (private + public)
resource "aws_route" "vast_private_to_peer" {
  for_each                  = var.enable_peering ? aws_route_table.private : {}
  route_table_id            = each.value.id
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

resource "aws_route" "vast_public_to_peer" {
  count                     = var.enable_peering ? 1 : 0
  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

# ---------------------------------------------------------------------------
# Security group handed to `vastcloud cluster create --aws-security-group-ids`.
# Client ports from allowed CIDRs + self-reference for intra-cluster comms.
# ---------------------------------------------------------------------------
resource "aws_security_group" "vast_cluster_access" {
  name        = "vast-cluster-access-${var.environment}"
  description = "VAST VoC: client access + intra-cluster comms"
  vpc_id      = aws_vpc.vast.id
  tags        = { Name = "vast-cluster-access-${var.environment}" }
}

resource "aws_vpc_security_group_ingress_rule" "client_tcp" {
  for_each          = local.client_ingress
  security_group_id = aws_security_group.vast_cluster_access.id
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
  description       = "tcp/${each.value.port} from ${each.value.cidr}"
}

# Intra-cluster: VoC nodes must reach each other on the full internal TCP/UDP
# range (replication 49001/49002, CAS/Silo UDP 4005/5205-5240, etc.).
resource "aws_vpc_security_group_ingress_rule" "self_all" {
  security_group_id            = aws_security_group.vast_cluster_access.id
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.vast_cluster_access.id
  description                  = "intra-cluster: all traffic within the SG"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vast_cluster_access.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
