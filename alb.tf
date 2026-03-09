# ============================================================
# Application Load Balancer
# ============================================================

# The ALB is the public entry point for the Django API.
# It lives in the public subnets and routes HTTP traffic to ECS tasks.
#
# Note: we don't put HTTPS on the ALB. CloudFront handles HTTPS for
# visitors (visitor → CloudFront is HTTPS), and CloudFront → ALB is HTTP
# within AWS's private network. This is a common and accepted pattern —
# the traffic never leaves AWS's infrastructure unencrypted.
resource "aws_lb" "main" {
  name               = "django-api"
  internal           = false             # internet-facing (public subnets)
  load_balancer_type = "application"     # ALB (vs NLB which is layer 4 / TCP only)
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

# ============================================================
# Target Group
# ============================================================

# A target group is the list of backends the ALB sends traffic to.
# ECS automatically registers and deregisters task IPs here as tasks
# start and stop (configured via the load_balancer block in ecs.tf).
resource "aws_lb_target_group" "django_api" {
  name        = "django-api"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id

  # "ip" is required for Fargate — tasks are identified by their private IP,
  # not by an EC2 instance ID (which is what "instance" type uses).
  target_type = "ip"

  # The ALB periodically sends requests to this path to check if the task
  # is healthy. Unhealthy tasks are removed from rotation and replaced.
  health_check {
    path                = "/api/health"
    matcher             = "200"
    interval            = 30  # seconds between checks
    healthy_threshold   = 2   # consecutive successes to mark healthy
    unhealthy_threshold = 3   # consecutive failures to mark unhealthy
  }
}

# ============================================================
# Listeners
# ============================================================

# A listener is a rule that says: "when traffic arrives on port X, do Y".
# This one forwards all port 80 traffic to the ECS target group.
# CloudFront connects to the ALB on port 80 (HTTP).
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.django_api.arn
  }
}

# ============================================================
# Output
# ============================================================

output "alb_dns_name" {
  description = "ALB domain — used as the CloudFront origin for /api/*"
  value       = aws_lb.main.dns_name
}
