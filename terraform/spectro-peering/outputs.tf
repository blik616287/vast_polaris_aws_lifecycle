output "spectro_test_vpc_id" {
  description = "BYO-VPC id for the spectro Palette cluster (deploy-cluster VPC_ID)."
  value       = aws_vpc.test.id
}

output "spectro_test_public_subnet_ids" {
  value = { for az, s in aws_subnet.public : az => s.id }
}

output "spectro_test_private_subnet_ids" {
  description = "Worker subnets for the spectro cluster (deploy-cluster SUBNET_IDS/AZS)."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "peering_connection_id" {
  value = aws_vpc_peering_connection.spectro_to_vast.id
}

output "deploy_cluster_hint" {
  description = "Env for vast-profile deploy-cluster to place a spectro cluster that reaches the VoC VMS."
  value = format(
    "CLOUD_ACCOUNT=isc-spectro VPC_ID=%s AZS=%s SUBNET_IDS=%s VMS_ENDPOINT=https://%s",
    aws_vpc.test.id,
    join(",", var.azs),
    join(",", [for az in var.azs : aws_subnet.private[az].id]),
    "10.20.13.207"
  )
}
