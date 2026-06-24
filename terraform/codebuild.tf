# =============================================================================
# Zero-touch VoC lifecycle via CodePipeline -> CodeBuild running VAST's vastcloud CLI.
#
#   terraform apply (cluster_action="deploy")  -> pipeline runs -> cluster created
#   terraform apply (cluster_action="destroy") -> pipeline runs -> cluster deleted
#
# The flag is baked into the S3 source artifact (deploy.env), so flipping it and
# re-applying changes the artifact hash, which re-triggers the pipeline. No
# null_resource / local-exec. CodeBuild executes scripts/*.sh which wrap vastcloud.
#
# Requires a Secrets Manager secret with the Polaris login, JSON: {"username","password"}.
#   aws secretsmanager create-secret --name vast/polaris \
#     --secret-string '{"username":"you@company.com","password":"..."}'
# =============================================================================

variable "cluster_action" {
  type        = string
  default     = "none"
  description = "deploy | destroy | none. Drives the CodeBuild run."
  validation {
    condition     = contains(["deploy", "destroy", "none"], var.cluster_action)
    error_message = "cluster_action must be deploy, destroy, or none."
  }
}

variable "cluster_name" {
  type    = string
  default = "voc-fieldeng"
}

variable "cluster_nodes" {
  type    = number
  default = 1
}

variable "cluster_instance_type" {
  type        = string
  default     = ""
  description = "Empty = VoC default (i3en.24xlarge minimum; smaller unsupported)."
}

variable "polaris_secret_id" {
  type        = string
  default     = "vast/polaris"
  description = "Secrets Manager secret id/ARN with JSON {username,password} for Polaris login."
}

locals {
  deploy_env = join("\n", [
    "CLUSTER_NAME=${var.cluster_name}",
    "ACTION=${var.cluster_action}",
    "REGION=${var.region}",
    "ZONE=${var.azs[0]}",
    "SUBNET_ID=${aws_subnet.private[var.azs[0]].id}",
    "SG_ID=${aws_security_group.vast_cluster_access.id}",
    "NODES=${var.cluster_nodes}",
    "INSTANCE_TYPE=${var.cluster_instance_type}",
    "PROFILE=${var.aws_profile}",
    "",
  ])
  name_prefix = "vast-voc-${var.environment}"
}

# ---------------------------------------------------------------------------
# Source artifact: zip of buildspec + scripts + generated deploy.env (holds the flag)
# ---------------------------------------------------------------------------
data "archive_file" "source" {
  type        = "zip"
  output_path = "${path.module}/.build/voc-source.zip"

  source {
    content  = file("${path.module}/../buildspec.yml")
    filename = "buildspec.yml"
  }
  source {
    content  = file("${path.module}/../scripts/deploy-voc.sh")
    filename = "scripts/deploy-voc.sh"
  }
  source {
    content  = file("${path.module}/../scripts/destroy-voc.sh")
    filename = "scripts/destroy-voc.sh"
  }
  source {
    content  = local.deploy_env
    filename = "deploy.env"
  }
}

# ---------------------------------------------------------------------------
# Artifact / source bucket (versioned — required for S3 pipeline source)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "pipeline" {
  bucket_prefix = "${local.name_prefix}-pipe-"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "pipeline" {
  bucket                  = aws_s3_bucket.pipeline.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "source" {
  bucket = aws_s3_bucket.pipeline.id
  key    = "source/voc-source.zip"
  source = data.archive_file.source.output_path
  etag   = data.archive_file.source.output_md5
}

# ---------------------------------------------------------------------------
# IAM — CodeBuild role (broad: vastcloud creates VPC/EC2/CFN/S3/IAM resources)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${local.name_prefix}-codebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

# vastcloud provisions a full VoC stack (VPC peers, EC2, CFN, S3 state buckets,
# IAM instance profiles). Admin keeps it working; scope down later if needed.
resource "aws_iam_role_policy_attachment" "codebuild_admin" {
  role       = aws_iam_role.codebuild.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------------------------------------------------------------------------
# CodeBuild project (driven by the pipeline)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "voc" {
  name         = "${local.name_prefix}-lifecycle"
  description  = "Deploy/destroy VAST VoC cluster via vastcloud CLI"
  service_role = aws_iam_role.codebuild.arn

  depends_on = [aws_secretsmanager_secret_version.polaris]

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    dynamic "environment_variable" {
      for_each = var.polaris_secret_id != "" ? [1] : []
      content {
        name  = "POLARIS_USERNAME"
        type  = "SECRETS_MANAGER"
        value = "${var.polaris_secret_id}:username"
      }
    }
    dynamic "environment_variable" {
      for_each = var.polaris_secret_id != "" ? [1] : []
      content {
        name  = "POLARIS_PASSWORD"
        type  = "SECRETS_MANAGER"
        value = "${var.polaris_secret_id}:password"
      }
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  # VoC bring-up/tear-down is long; allow up to 60 min.
  build_timeout = 60

  logs_config {
    cloudwatch_logs {
      group_name  = "/codebuild/${local.name_prefix}"
      stream_name = "lifecycle"
    }
  }
}

# ---------------------------------------------------------------------------
# IAM — CodePipeline role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${local.name_prefix}-pipeline"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
}

data "aws_iam_policy_document" "pipeline" {
  # Full S3 on the dedicated artifact bucket only. CodePipeline's S3 source
  # needs more than the obvious read actions (ListBucketVersions, GetObjectTagging,
  # GetBucketLocation, ...); scoping s3:* to this one bucket is simplest + safe.
  statement {
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.pipeline.arn, "${aws_s3_bucket.pipeline.arn}/*"]
  }
  statement {
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.voc.arn]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# ---------------------------------------------------------------------------
# CodePipeline: S3 source (auto-detect changes) -> CodeBuild
# ---------------------------------------------------------------------------
resource "aws_codepipeline" "voc" {
  name     = "${local.name_prefix}-lifecycle"
  role_arn = aws_iam_role.pipeline.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.pipeline.bucket
  }

  stage {
    name = "Source"
    action {
      name             = "S3Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      version          = "1"
      output_artifacts = ["src"]
      configuration = {
        S3Bucket             = aws_s3_bucket.pipeline.bucket
        S3ObjectKey          = aws_s3_object.source.key
        PollForSourceChanges = "true"
      }
    }
  }

  stage {
    name = "Lifecycle"
    action {
      name            = "VocDeployOrDestroy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["src"]
      configuration = {
        ProjectName = aws_codebuild_project.voc.name
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Teardown project (NO_SOURCE, directly start-buildable) — guarantees the VoC
# cluster is deleted on `terraform destroy`. Self-contained: vastcloud + login
# + `cluster delete`. CodeBuild does the deletion (not local tooling).
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "teardown" {
  name         = "${local.name_prefix}-teardown"
  description  = "Delete the VoC cluster (invoked by terraform destroy)"
  service_role = aws_iam_role.codebuild.arn

  depends_on = [aws_secretsmanager_secret_version.polaris]

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "CLUSTER_NAME"
      value = var.cluster_name
    }
    environment_variable {
      name  = "REGION"
      value = var.region
    }
    environment_variable {
      name  = "PROFILE"
      value = var.aws_profile
    }
    dynamic "environment_variable" {
      for_each = var.polaris_secret_id != "" ? [1] : []
      content {
        name  = "POLARIS_USERNAME"
        type  = "SECRETS_MANAGER"
        value = "${var.polaris_secret_id}:username"
      }
    }
    dynamic "environment_variable" {
      for_each = var.polaris_secret_id != "" ? [1] : []
      content {
        name  = "POLARIS_PASSWORD"
        type  = "SECRETS_MANAGER"
        value = "${var.polaris_secret_id}:password"
      }
    }
  }

  build_timeout = 30

  source {
    type      = "NO_SOURCE"
    buildspec = <<-YAML
      version: 0.2
      phases:
        install:
          commands:
            - set -eu
            - curl -fL -o /usr/local/bin/vastcloud "https://storage.googleapis.com/polaris-vastcloud/linux-amd64/vastcloud" && chmod +x /usr/local/bin/vastcloud
            - |
              URL="$${AWS_CONTAINER_CREDENTIALS_FULL_URI:-http://169.254.170.2$${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}}"
              CREDS=$(curl -sf "$URL")
              for P in default "$PROFILE"; do
                aws configure set aws_access_key_id     "$(echo "$CREDS" | jq -r .AccessKeyId)"     --profile "$P"
                aws configure set aws_secret_access_key "$(echo "$CREDS" | jq -r .SecretAccessKey)" --profile "$P"
                aws configure set aws_session_token     "$(echo "$CREDS" | jq -r .Token)"           --profile "$P"
                aws configure set region "$REGION" --profile "$P"
              done
            - vastcloud config init --non-interactive --provider aws --aws-region "$REGION" --aws-profile "$PROFILE" --endpoint "https://api.aws.polaris.vastdata.com" --account-name "$PROFILE" --force
            - printf '%s' "$POLARIS_PASSWORD" | vastcloud login --username "$POLARIS_USERNAME" --password-stdin
        build:
          commands:
            # Discover the cluster from its S3 state bucket (fresh container has no
            # local ~/.vast state), then delete via vast CLI. No-op if already gone.
            - echo "Discovering VoC cluster $CLUSTER_NAME from S3..."
            - vastcloud cluster list --include-bucket-discovery --non-interactive >/dev/null 2>&1 || true
            - echo "Deleting VoC cluster $CLUSTER_NAME (no-op if it does not exist)..."
            - vastcloud cluster delete "$CLUSTER_NAME" --non-interactive --force --delete-state-bucket || true
            - vastcloud cluster list --include-bucket-discovery || true
    YAML
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/codebuild/${local.name_prefix}"
      stream_name = "teardown"
    }
  }
}

# Destroy-time guard: on `terraform destroy`, synchronously run the teardown
# CodeBuild (which deletes the cluster) BEFORE the project/roles are removed.
# terraform_data is the BUILT-IN successor to null_resource; here it is only a
# thin trigger that blocks until CodeBuild finishes — CodeBuild does the delete.
resource "terraform_data" "teardown_on_destroy" {
  input = {
    project = aws_codebuild_project.teardown.name
    region  = var.region
    profile = var.aws_profile
  }

  # Ensure the teardown project + role still exist while the guard runs on destroy.
  depends_on = [
    aws_codebuild_project.teardown,
    aws_iam_role_policy_attachment.codebuild_admin,
  ]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      echo "==> terraform destroy: triggering CodeBuild ${self.input.project} to delete the VoC cluster"
      BID=$(aws codebuild start-build --project-name ${self.input.project} \
              --region ${self.input.region} --profile ${self.input.profile} \
              --query 'build.id' --output text)
      echo "    build $BID started; waiting for completion..."
      while true; do
        S=$(aws codebuild batch-get-builds --ids "$BID" \
              --region ${self.input.region} --profile ${self.input.profile} \
              --query 'builds[0].buildStatus' --output text)
        echo "    $BID: $S"
        case "$S" in
          SUCCEEDED) echo "    cluster teardown complete"; break ;;
          FAILED|FAULT|STOPPED|TIMED_OUT) echo "    teardown build $S"; exit 1 ;;
        esac
        sleep 20
      done
    EOT
  }
}

output "teardown_project" {
  value = aws_codebuild_project.teardown.name
}

output "pipeline_name" {
  value = aws_codepipeline.voc.name
}

output "codebuild_project" {
  value = aws_codebuild_project.voc.name
}

output "artifact_bucket" {
  value = aws_s3_bucket.pipeline.bucket
}

output "current_action" {
  value = var.cluster_action
}
