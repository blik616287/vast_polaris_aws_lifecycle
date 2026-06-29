# =============================================================================
# Cross-account VPC peering so a Palette-managed cluster in the SPECTRO account
# can reach the VAST on Cloud cluster (VMS + data VIPs) running in the FIELDENG
# VAST VPC — enabling CSI integration testing from the spectro profile, alongside
# the same-account fieldeng test.
#
# Why a new VPC: the spectro account already has a 10.20.0.0/16 VPC (vast-voc-ue2)
# that overlaps the fieldeng VAST VPC (10.20.0.0/16). Peering can't span overlapping
# CIDRs, so we stand up a fresh, non-overlapping 10.30.0.0/16 test VPC and peer THAT.
#
# Pairs with the main voc apply: add the test CIDR to vast_client_cidrs there so the
# VAST SG opens its client ports to 10.30/16 (this module adds the routes + the VPC).
# Workflow: terraform plan -> review -> apply (never auto-apply).
# =============================================================================

locals {
  azs_idx = { for i, az in var.azs : az => i }
  nat_azs = var.single_nat ? [var.azs[0]] : var.azs
}

# ---------------------------------------------------------------------------
# New non-overlapping test VPC (spectro account)
# ---------------------------------------------------------------------------
resource "aws_vpc" "test" {
  cidr_block           = var.spectro_test_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "vast-csi-test-spectro" }
}

resource "aws_subnet" "public" {
  for_each                = local.azs_idx
  vpc_id                  = aws_vpc.test.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.spectro_test_cidr, 4, each.value)
  map_public_ip_on_launch = true
  tags = {
    Name                     = "vast-csi-test-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each          = local.azs_idx
  vpc_id            = aws_vpc.test.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.spectro_test_cidr, 4, each.value + 8)
  tags = {
    Name                              = "vast-csi-test-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ---------------------------------------------------------------------------
# IGW + NAT (cluster nodes need egress to pull images, incl. build-on-deploy crane)
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "test" {
  vpc_id = aws_vpc.test.id
  tags   = { Name = "vast-csi-test-igw" }
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"
  tags     = { Name = "vast-csi-test-nat-${each.key}" }
}

resource "aws_nat_gateway" "test" {
  for_each      = toset(local.nat_azs)
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = { Name = "vast-csi-test-nat-${each.key}" }
  depends_on    = [aws_internet_gateway.test]
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.test.id
  tags   = { Name = "vast-csi-test-public-rt" }
}

resource "aws_route" "public_inet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.test.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id   = aws_vpc.test.id
  tags     = { Name = "vast-csi-test-private-rt-${each.key}" }
}

resource "aws_route" "private_nat" {
  for_each               = aws_route_table.private
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.test[var.single_nat ? var.azs[0] : each.key].id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ---------------------------------------------------------------------------
# Cross-account peering: requester (spectro) -> accepter (fieldeng VAST VPC)
# ---------------------------------------------------------------------------
resource "aws_vpc_peering_connection" "spectro_to_vast" {
  vpc_id        = aws_vpc.test.id
  peer_vpc_id   = var.vast_vpc_id
  peer_owner_id = var.fieldeng_account_id
  auto_accept   = false
  tags          = { Name = "spectro-csi-test-to-vast-fieldeng" }
}

resource "aws_vpc_peering_connection_accepter" "vast" {
  provider                  = aws.fieldeng
  vpc_peering_connection_id = aws_vpc_peering_connection.spectro_to_vast.id
  auto_accept               = true
  tags                      = { Name = "vast-fieldeng-accept-spectro-csi-test" }
}

# ---------------------------------------------------------------------------
# Routes: spectro test VPC -> VAST (10.20/16) on every test route table
# ---------------------------------------------------------------------------
resource "aws_route" "test_to_vast" {
  for_each                  = merge({ public = aws_route_table.public }, aws_route_table.private)
  route_table_id            = each.value.id
  destination_cidr_block    = var.vast_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.spectro_to_vast.id
}

# ---------------------------------------------------------------------------
# Return routes on the fieldeng VAST VPC -> spectro test CIDR (10.30/16).
# Discovers all VAST VPC route tables and adds the peer route to each.
# ---------------------------------------------------------------------------
data "aws_route_tables" "vast" {
  provider = aws.fieldeng
  vpc_id   = var.vast_vpc_id
}

resource "aws_route" "vast_to_test" {
  provider                  = aws.fieldeng
  for_each                  = toset(data.aws_route_tables.vast.ids)
  route_table_id            = each.value
  destination_cidr_block    = var.spectro_test_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.spectro_to_vast.id
  # accepter must be established before the route resolves the connection
  depends_on = [aws_vpc_peering_connection_accepter.vast]
}
