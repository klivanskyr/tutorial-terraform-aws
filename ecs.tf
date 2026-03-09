# ============================================================
# CloudWatch Log Group
# ============================================================

# ECS containers write stdout/stderr here. Without this, you'd have
# no visibility into what's happening inside your containers.
resource "aws_cloudwatch_log_group" "django_api" {
  name              = "/ecs/django-api"
  retention_in_days = 7 # Auto-delete logs older than 7 days to control cost
}

# ============================================================
# IAM Roles
# ============================================================

# There are TWO distinct IAM roles for ECS tasks — a common source of confusion:
#
# 1. EXECUTION ROLE — used by the ECS *control plane* (not your code) to:
#      - Pull your Docker image from ECR
#      - Write container logs to CloudWatch
#      - Fetch secrets from Secrets Manager to inject as env vars
#
# 2. TASK ROLE — used by the *running container* (your Django code) to
#      call AWS APIs directly (e.g. S3, Secrets Manager, SQS).
#      Your app code uses this role's permissions at runtime.

# --- Execution Role ---
resource "aws_iam_role" "ecs_execution" {
  name = "ecs-execution-role"

  # Trust policy: allow the ECS service to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# AWS provides a managed policy for the standard execution role permissions.
# It covers ECR pull and CloudWatch log writing out of the box.
resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Extra permission: allow the execution role to read our DB secret so ECS
# can inject the password as an environment variable into the container.
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "ecs-execution-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [
        aws_secretsmanager_secret.db.arn,
        aws_secretsmanager_secret.django_secret_key.arn,
        aws_secretsmanager_secret.superuser.arn,
      ]
    }]
  })
}

# --- Task Role ---
resource "aws_iam_role" "ecs_task" {
  name = "ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow ECS Exec — lets you run `aws ecs execute-command` to get a shell
# inside a running container (like SSH, but through AWS SSM, no open ports needed).
# Essential for debugging without a bastion host.
resource "aws_iam_role_policy" "ecs_task_exec_command" {
  name = "ecs-exec-command"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

# ============================================================
# ECS Cluster
# ============================================================

# The cluster is just a logical namespace — it groups your services and tasks.
# With Fargate, there are no EC2 instances to manage inside it.
resource "aws_ecs_cluster" "main" {
  name = "django-api"

  # Container Insights sends CPU, memory, network metrics to CloudWatch.
  # Costs a small amount per task but very useful for monitoring.
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ============================================================
# Task Definition
# ============================================================

# A task definition is like a blueprint for your container.
# It specifies: which image, how much CPU/memory, what ports,
# what environment variables, and where to send logs.
#
# Every time you deploy a new image, ECS creates a new revision
# of this task definition. Old revisions are kept for rollback.
resource "aws_ecs_task_definition" "django_api" {
  family                   = "django-api"
  requires_compatibilities = ["FARGATE"]

  # awsvpc gives each task its own private IP inside the VPC.
  # Required for Fargate — other modes (bridge, host) are EC2-only.
  network_mode = "awsvpc"

  # CPU is in "units" where 1024 = 1 vCPU.
  # 256 = 0.25 vCPU, 512 MB RAM — smallest valid Fargate size, fine for dev.
  cpu    = 256
  memory = 512

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  # container_definitions is a JSON string describing one or more containers.
  # For a simple API, we just have one: the Django container.
  container_definitions = jsonencode([
    {
      name  = "django-api"
      image = "${aws_ecr_repository.django_api.repository_url}:latest"

      portMappings = [{
        containerPort = 8000
        protocol      = "tcp"
      }]

      # Plain env vars — fine for non-sensitive config
      environment = [
        { name = "DATABASE_ENGINE", value = "django.db.backends.postgresql" },
        { name = "DATABASE_HOST",   value = aws_db_proxy.main.endpoint },
        { name = "DATABASE_NAME",   value = "appdb" },
        { name = "DATABASE_USER",   value = "appuser" },
        { name = "DEBUG",           value = "False" },
        # '*' allows any Host header. Needed because ALB health checks hit Django
        # using the task's private IP as the Host, not the domain name.
        # For production, replace with your domain and use a custom health check
        # host header on the ALB instead.
        { name = "ALLOWED_HOSTS",   value = "*" },
        { name = "REDIS_URL",             value = "redis://${aws_elasticache_cluster.main.cache_nodes[0].address}:6379" },
        { name = "CSRF_TRUSTED_ORIGINS", value = "https://terraform-test.deepfeat.ai" },
      ]

      # Secrets are fetched from Secrets Manager at container startup and
      # injected as environment variables — the container never sees the ARN,
      # just the value. The format "secret-arn:json-key::" extracts a specific
      # key from a JSON secret. Our secret has {"username": ..., "password": ...}
      # so ":password::" pulls just the password value.
      secrets = [
        {
          name      = "DATABASE_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.db.arn}:password::"
        },
        {
          # The secret value is a plain string (not JSON), so no key suffix needed.
          name      = "SECRET_KEY"
          valueFrom = aws_secretsmanager_secret.django_secret_key.arn
        },
        # Django reads these three env vars when `createsuperuser --noinput` runs.
        # The container creates the admin account on first startup, then skips it
        # on every subsequent startup (the user already exists in the DB).
        {
          name      = "DJANGO_SUPERUSER_USERNAME"
          valueFrom = "${aws_secretsmanager_secret.superuser.arn}:username::"
        },
        {
          name      = "DJANGO_SUPERUSER_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.superuser.arn}:password::"
        },
        {
          name      = "DJANGO_SUPERUSER_EMAIL"
          valueFrom = "${aws_secretsmanager_secret.superuser.arn}:email::"
        },
      ]

      # Send all container stdout/stderr to CloudWatch Logs.
      # Without this, container output disappears when the task stops.
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.django_api.name
          "awslogs-region"        = "us-west-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# ============================================================
# ECS Service
# ============================================================

# The service ensures your task definition is always running.
# If a container crashes, the service replaces it automatically.
# It also handles rolling deployments when you push a new image.
resource "aws_ecs_service" "django_api" {
  name            = "django-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.django_api.arn
  desired_count   = 1   # Run 1 container. Increase for redundancy/scale.
  launch_type     = "FARGATE"

  # Enables `aws ecs execute-command` so you can shell into a running
  # container for debugging (set up in the task role above).
  enable_execute_command = true

  network_configuration {
    subnets         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups = [aws_security_group.ecs.id]
    # false = no public IP. Traffic comes in through the ALB only.
    assign_public_ip = false
  }

  # Wires this service to the ALB target group.
  # ECS will register each task's private IP into the target group when it starts,
  # and deregister it when the task stops or fails health checks.
  load_balancer {
    target_group_arn = aws_lb_target_group.django_api.arn
    container_name   = "django-api"
    container_port   = 8000
  }

  # Must wait for the listener to exist before the service can register targets.
  depends_on = [aws_lb_listener.http]

  # Tells Terraform to ignore task_definition changes after initial deploy.
  # Without this, every `terraform apply` would force a redeployment back
  # to "latest" even if you'd deployed a newer image via deploy.sh.
  lifecycle {
    ignore_changes = [task_definition]
  }
}
