# fieldeng environment (account 211476615597, us-east-2).
# Self-contained: dedicated VAST VPC, no peering (no Palette VPC in this account).
aws_profile = "fieldeng"
region      = "us-east-2"
environment = "fieldeng"

vast_vpc_cidr = "10.20.0.0/16" # free in fieldeng (in use: 10.0/16, 172.31/16, 192.168/16)
single_nat    = true

# No peering by default. To connect an existing EKS/k8s VPC later, set:
#   enable_peering       = true
#   peer_vpc_id          = "vpc-xxxx"
#   peer_vpc_cidr        = "10.0.0.0/16"
#   peer_route_table_ids = ["rtb-xxxx", "rtb-yyyy"]
#   vast_client_cidrs    = ["<worker-subnet-cidrs>"]
enable_peering = false

# ---- Cluster lifecycle (driven by CodePipeline -> CodeBuild -> vastcloud) ----
# Flip and `terraform apply` to act: the pipeline re-runs and deploys/destroys.
cluster_action = "none" # "deploy" | "destroy" | "none"
cluster_name   = "voc-fieldeng"
cluster_nodes  = 1
# cluster_instance_type = ""           # empty = VoC default (i3en.24xlarge)
polaris_secret_id = "vast/polaris" # Secrets Manager: {"username","password"}
