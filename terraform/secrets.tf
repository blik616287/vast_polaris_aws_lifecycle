# =============================================================================
# Polaris credentials -> Secrets Manager (TF-managed).
# CodeBuild reads these from Secrets Manager (SECRETS_MANAGER env vars), so the
# password never appears in build logs. Provide the values in a GITIGNORED
# secrets.auto.tfvars (do NOT commit), or via TF_VAR_polaris_password etc.
#
# NOTE: secret_string lands in terraform state — use an encrypted remote backend.
# If a `vast/polaris` secret already exists outside TF, set manage_polaris_secret=false.
# =============================================================================

variable "polaris_username" {
  type      = string
  default   = ""
  sensitive = true
}

variable "polaris_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "manage_polaris_secret" {
  type        = bool
  default     = true
  description = "true = TF creates the vast/polaris secret from the vars above."
}

resource "aws_secretsmanager_secret" "polaris" {
  count                   = var.manage_polaris_secret ? 1 : 0
  name                    = var.polaris_secret_id
  description             = "VAST Polaris login for VoC deploy/destroy (CodeBuild)"
  recovery_window_in_days = 0 # allow immediate re-create on destroy/apply cycles
}

resource "aws_secretsmanager_secret_version" "polaris" {
  count     = var.manage_polaris_secret ? 1 : 0
  secret_id = aws_secretsmanager_secret.polaris[0].id
  secret_string = jsonencode({
    username = var.polaris_username
    password = var.polaris_password
  })
}
