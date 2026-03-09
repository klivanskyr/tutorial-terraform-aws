# ============================================================
# ECR — Elastic Container Registry
# ============================================================

# ECR is AWS's private Docker registry. Your ECS tasks will pull
# the Django image from here. Think of it like a private Docker Hub
# that lives inside your AWS account.
resource "aws_ecr_repository" "django_api" {
  name         = "django-api"
  # MUTABLE means you can push new images with the same tag (e.g. "latest").
  # IMMUTABLE would force a unique tag every push — better for production
  # traceability, but more complex to manage while learning.
  image_tag_mutability = "MUTABLE"

  # Allow `terraform destroy` to delete the repo even if it contains images.
  # For production, remove this so you can't accidentally wipe your image history.
  force_delete = true

  # Scan images for known OS/package vulnerabilities on every push.
  # Results show up in the ECR console. Free, always worth enabling.
  image_scanning_configuration {
    scan_on_push = true
  }
}

# ECR repositories persist images forever by default — this adds up in cost.
# This lifecycle policy automatically deletes untagged images older than 1 day,
# keeping only the 5 most recent tagged images.
# "untagged" images are the old layers left behind when you re-push "latest".
resource "aws_ecr_lifecycle_policy" "django_api" {
  repository = aws_ecr_repository.django_api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 5 most recent tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v", "latest"]
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "ecr_repository_url" {
  description = "Use this URL to tag and push your Docker image."
  value       = aws_ecr_repository.django_api.repository_url
}
