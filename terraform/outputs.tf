# Feed these into scripts/deploy-voc.sh / `vastcloud cluster create`.
output "vast_vpc_id" {
  value = aws_vpc.vast.id
}

output "vast_private_subnet_ids" {
  description = "Map AZ -> private subnet id (deploy VoC into one of these)."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "vast_public_subnet_ids" {
  value = { for az, s in aws_subnet.public : az => s.id }
}

output "vast_cluster_access_sg_id" {
  description = "Pass to: vastcloud cluster create --aws-security-group-ids <id>"
  value       = aws_security_group.vast_cluster_access.id
}

output "deploy_subnet_id" {
  description = "Default subnet for VoC deploy (first AZ private subnet)."
  value       = aws_subnet.private[var.azs[0]].id
}

output "deploy_zone" {
  value = var.azs[0]
}

output "peering_connection_id" {
  value = var.enable_peering ? aws_vpc_peering_connection.peer[0].id : null
}

# Convenience: ready-to-run deploy command (fill cluster name).
output "deploy_hint" {
  value = "scripts/deploy-voc.sh <cluster-name>   # uses these outputs automatically"
}
