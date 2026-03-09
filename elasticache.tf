# ============================================================
# ElastiCache Subnet Group
# ============================================================

# A subnet group tells ElastiCache which subnets it can place nodes in.
# We use private subnets — Redis should never be directly reachable
# from the internet, only from ECS tasks inside the VPC.
resource "aws_elasticache_subnet_group" "main" {
  name       = "django-api"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

# ============================================================
# Security Group
# ============================================================

# Redis only accepts connections from ECS tasks.
# Nothing else in the VPC (or the internet) can reach it.
resource "aws_security_group" "redis" {
  name   = "redis"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "Redis from ECS only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "redis" }
}

# ============================================================
# ElastiCache Redis Cluster
# ============================================================

# A single-node Redis cluster. For production you'd use replication_group
# (which gives you a primary + read replicas + automatic failover),
# but for dev a single cluster.t3.micro node is fine and costs ~$12/month.
#
# We use Redis 7 — it adds many useful commands and the parameter group
# "default.redis7" works out of the box with no custom configuration.
resource "aws_elasticache_cluster" "main" {
  cluster_id           = "django-api"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]

  tags = { Name = "django-api" }
}

# ============================================================
# Output
# ============================================================

output "redis_endpoint" {
  description = "Redis endpoint — set as REDIS_URL in ECS task definition"
  value       = "redis://${aws_elasticache_cluster.main.cache_nodes[0].address}:6379"
}
