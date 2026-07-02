locals {
  azs_idx = { for i, az in var.azs : az => i }
  nat_azs = var.single_nat ? [var.azs[0]] : var.azs
}

# ---------------------------------------------------------------------------
# Peer VPC (fieldeng) + subnets (ELB-tagged for Palette managed clusters)
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_subnet" "public" {
  for_each                = local.azs_idx
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.cidr, 4, each.value)
  map_public_ip_on_launch = true
  tags = {
    Name                     = "${var.name}-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each          = local.azs_idx
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.cidr, 4, each.value + 8)
  tags = {
    Name                              = "${var.name}-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ---------------------------------------------------------------------------
# IGW + NAT (nodes need egress to pull images incl. build-on-deploy crane)
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"
  tags     = { Name = "${var.name}-nat-${each.key}" }
}

resource "aws_nat_gateway" "this" {
  for_each      = toset(local.nat_azs)
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = { Name = "${var.name}-nat-${each.key}" }
  depends_on    = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public-rt" }
}

resource "aws_route" "public_inet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id   = aws_vpc.this.id
  tags     = { Name = "${var.name}-private-rt-${each.key}" }
}

resource "aws_route" "private_nat" {
  for_each               = aws_route_table.private
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat ? var.azs[0] : each.key].id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ---------------------------------------------------------------------------
# Same-account peering to the VAST VPC (auto-accept — same owner)
# ---------------------------------------------------------------------------
resource "aws_vpc_peering_connection" "to_vast" {
  vpc_id      = aws_vpc.this.id
  peer_vpc_id = var.vast_vpc_id
  auto_accept = true
  tags        = { Name = "${var.name}-to-vast" }
}

# tenant VPC -> VAST (10.20/16) on every tenant route table
resource "aws_route" "tenant_to_vast" {
  for_each                  = merge({ public = aws_route_table.public }, aws_route_table.private)
  route_table_id            = each.value.id
  destination_cidr_block    = var.vast_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_vast.id
}

# ---------------------------------------------------------------------------
# Return routes on the VAST VPC -> this tenant CIDR. The main voc route tables
# set `lifecycle { ignore_changes = [route] }`, so these peer routes (owned by
# this state) won't be reconciled away by the voc apply.
# ---------------------------------------------------------------------------
data "aws_route_tables" "vast" {
  vpc_id = var.vast_vpc_id
}

resource "aws_route" "vast_to_tenant" {
  for_each                  = toset(data.aws_route_tables.vast.ids)
  route_table_id            = each.value
  destination_cidr_block    = var.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_vast.id
}
