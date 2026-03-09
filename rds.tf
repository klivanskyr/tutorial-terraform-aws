# ============================================================
# Random Password
# ============================================================

# Generate a cryptographically secure random password for the DB.
# This means the password is never written in your code or committed to git —
# Terraform generates it once, stores it in state, and puts it in Secrets Manager.
resource "random_password" "db" {
  length           = 32
  special          = true
  # These characters can break postgres connection strings or shell commands
  # if they appear in a password, so we exclude them.
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

# ============================================================
# Secrets Manager
# ============================================================

# Secrets Manager is AWS's service for storing sensitive values like
# passwords, API keys, and connection strings. It encrypts them at rest,
# controls access via IAM, and can auto-rotate them on a schedule.
#
# RDS Proxy REQUIRES credentials to be stored here — it reads the secret
# at runtime to authenticate to RDS on behalf of your app. Your app
# never needs to know the actual DB password.

# The "secret" is just a named container. The actual value goes in the version below.
resource "aws_secretsmanager_secret" "db" {
  name        = "django-api/db-credentials"
  description = "RDS credentials for the Django API"

  # How long AWS waits before permanently deleting a secret after you destroy it.
  # 0 = delete immediately. For production, set this to 7-30 days to prevent
  # accidental permanent loss.
  recovery_window_in_days = 0
}

# The secret version holds the actual credentials as a JSON string.
# RDS Proxy expects this exact JSON structure with "username" and "password" keys.
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = "appuser"
    password = random_password.db.result
  })
}

# ============================================================
# Django Secret Key
# ============================================================

# A separate secret just for Django's SECRET_KEY.
# It's not DB credentials so it doesn't belong in the DB secret.
resource "random_password" "django_secret_key" {
  length  = 50
  special = false # Django secret key doesn't need special chars
}

resource "aws_secretsmanager_secret" "django_secret_key" {
  name                    = "django-api/secret-key"
  description             = "Django SECRET_KEY for the API"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "django_secret_key" {
  secret_id     = aws_secretsmanager_secret.django_secret_key.id
  secret_string = random_password.django_secret_key.result
}

# ============================================================
# Django Superuser Credentials
# ============================================================

# Auto-generate the admin password so it's never written in code.
# To log into /admin/, retrieve it from Secrets Manager:
#   aws secretsmanager get-secret-value \
#     --secret-id django-api/superuser-credentials \
#     --query SecretString --output text | python3 -m json.tool
resource "random_password" "superuser" {
  length  = 24
  special = false # Avoids any edge-case issues with shell quoting
}

resource "aws_secretsmanager_secret" "superuser" {
  name                    = "django-api/superuser-credentials"
  description             = "Django admin superuser login"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "superuser" {
  secret_id = aws_secretsmanager_secret.superuser.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.superuser.result
    email    = "admin@example.com"
  })
}

# ============================================================
# RDS Subnet Group
# ============================================================

# RDS needs to know which subnets it can use for its instances.
# A subnet group must span at least 2 AZs — AWS requires this for
# Multi-AZ failover capability, even if you're not using Multi-AZ right now.
resource "aws_db_subnet_group" "main" {
  name       = "main"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = { Name = "main" }
}

# ============================================================
# RDS Instance (PostgreSQL)
# ============================================================

resource "aws_db_instance" "main" {
  identifier = "django-api-db"

  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro" # Cheapest option — fine for dev

  # Storage in GB. gp2 is general purpose SSD.
  # gp3 is newer/cheaper at scale but gp2 is simpler for dev.
  allocated_storage = 20
  storage_type      = "gp2"

  # The initial database name created inside Postgres on first boot.
  # This is what Django's DATABASES["NAME"] setting will point to.
  db_name  = "appdb"
  username = "appuser"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Multi-AZ creates a hot standby in a second AZ and auto-fails over
  # if the primary goes down. ~2x the cost. False for dev.
  multi_az = false

  # Encrypt the database storage at rest using AWS-managed keys.
  # Free and always worth enabling.
  storage_encrypted = true

  # Automated backups — how many days to retain them (0 = disabled).
  # Set to at least 7 in production.
  backup_retention_period = 1

  # skip_final_snapshot = true means Terraform can destroy this DB without
  # first creating a backup snapshot. Set to FALSE in production —
  # otherwise a `terraform destroy` permanently deletes all your data.
  skip_final_snapshot = true

  # Prevents `terraform destroy` from deleting the DB unless you first
  # set this to false and re-apply. A safety net in production.
  deletion_protection = false

  tags = { Name = "django-api-db" }
}

# ============================================================
# IAM Role for RDS Proxy
# ============================================================

# RDS Proxy needs permission to read from Secrets Manager so it can
# authenticate to RDS. In AWS, permissions are granted via IAM roles.
#
# An IAM role has two parts:
#   1. Trust policy — who is allowed to ASSUME (use) this role
#   2. Permission policy — what the role is allowed to DO

# Trust policy: allow the RDS Proxy service to assume this role
resource "aws_iam_role" "rds_proxy" {
  name = "rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Permission policy: allow the role to read the DB secret from Secrets Manager
resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "rds-proxy-secrets-access"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      # Restrict to only the specific secret this proxy needs —
      # not all secrets in the account.
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}

# ============================================================
# RDS Proxy
# ============================================================

# The proxy sits between your app and RDS and provides:
#   - Connection pooling: reuses DB connections instead of opening a new one
#     per Django request (Django's default behavior kills RDS under load)
#   - Faster failover: if RDS fails over to standby, the proxy handles
#     reconnection so your app only sees a brief pause, not a full crash
#   - IAM auth: apps can authenticate via IAM instead of passwords
resource "aws_db_proxy" "main" {
  name                   = "django-api-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]

  # Require TLS between your app and the proxy.
  # Always leave this true — there's no reason to disable it.
  require_tls = true

  # How the proxy authenticates to RDS — using the secret we created above.
  # The proxy reads the username/password from Secrets Manager and uses
  # them to open a pool of connections to RDS on your behalf.
  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.db.arn
    iam_auth    = "DISABLED" # Password auth via secret (simplest for now)
  }
}

# The target group links the proxy to the actual RDS instance.
# "Default" target group is automatically created with the proxy.
resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.main.name

  connection_pool_config {
    # Max percentage of RDS's max_connections the proxy will use.
    # RDS db.t3.micro supports ~85 connections. 100% = proxy can use all of them.
    max_connections_percent = 100
  }
}

# Register the RDS instance as the proxy's target.
# This is the actual link: proxy → RDS instance.
resource "aws_db_proxy_target" "main" {
  db_proxy_name          = aws_db_proxy.main.name
  target_group_name      = aws_db_proxy_default_target_group.main.name
  db_instance_identifier = aws_db_instance.main.identifier
}

# ============================================================
# Outputs
# ============================================================

# Your Django app connects to the PROXY endpoint, not the RDS endpoint directly.
# The proxy endpoint is what goes in your DATABASE_HOST environment variable.
output "rds_proxy_endpoint" {
  description = "Connect Django to this host, not the RDS instance directly."
  value       = aws_db_proxy.main.endpoint
}
