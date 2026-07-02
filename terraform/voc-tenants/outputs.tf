output "vpc_id" {
  description = "BYO-VPC id for this tenant's Palette cluster."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = { for az, s in aws_subnet.public : az => s.id }
}

output "private_subnet_ids" {
  description = "Worker/CP subnets for the Palette cluster."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "peering_connection_id" {
  value = aws_vpc_peering_connection.to_vast.id
}

output "deploy_hint" {
  description = "Placement for a Palette static-VPC cluster that reaches the VoC VMS."
  value = format(
    "VPC_ID=%s AZS=%s PRIVATE_SUBNET_IDS=%s",
    aws_vpc.this.id,
    join(",", var.azs),
    join(",", [for az in var.azs : aws_subnet.private[az].id]),
  )
}
