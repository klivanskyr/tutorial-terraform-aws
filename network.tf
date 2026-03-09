# ============================================================
# VPC (Virtual Private Cloud)
# ============================================================

# A VPC is your own isolated section of the AWS network.
# Nothing inside it is reachable from the internet unless you
# explicitly allow it. Think of it as your private data center network.
#
# CIDR notation: 10.0.0.0/16 means the first 16 bits are fixed (10.0.x.x),
# giving you 65,536 possible IP addresses to hand out to resources.
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  # Required for ECS tasks to resolve AWS service hostnames (like ECR, Secrets Manager).
  # Without this, DNS lookups inside the VPC won't work.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "main" }
}

# ============================================================
# Subnets
# ============================================================

# Subnets are subdivisions of your VPC CIDR range, locked to a specific
# Availability Zone (a physically separate data center).
# We spread across 2 AZs so that if one goes down, the other keeps running.
#
# us-west-1 only has 2 AZs: us-west-1b and us-west-1c
# (us-west-1a was deprecated by AWS)

# --- Public subnets ---
# Resources here get a public IP and can be reached from the internet
# (via the Internet Gateway). The ALB lives here.

resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24" # 256 addresses: 10.0.1.0 – 10.0.1.255
  availability_zone = "us-west-1a"

  # Automatically assign a public IP to any resource launched here.
  # Needed so the ALB can be reached from the internet.
  map_public_ip_on_launch = true

  tags = { Name = "public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-1c"

  map_public_ip_on_launch = true

  tags = { Name = "public-b" }
}

# --- Private subnets ---
# Resources here have NO public IP and cannot be reached from the internet.
# ECS tasks, RDS, and RDS Proxy all live here.

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "us-west-1a"

  tags = { Name = "private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "us-west-1c"

  tags = { Name = "private-b" }
}

# ============================================================
# Internet Gateway
# ============================================================

# The Internet Gateway (IGW) is the door between your VPC and the internet.
# Without it, nothing in your VPC can send or receive internet traffic.
# Attaching it to the VPC doesn't automatically route traffic through it —
# you also need to add routes (see route tables below).
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "main" }
}

# ============================================================
# NAT Gateway
# ============================================================

# Private subnet resources (ECS tasks) have no public IP, so they can't
# reach the internet directly. But they need outbound internet access to:
#   - Pull Docker images from ECR
#   - Call AWS APIs (Secrets Manager, CloudWatch logs)
#   - Make outbound HTTP calls from Django
#
# A NAT Gateway solves this: it sits in a PUBLIC subnet and forwards
# outbound traffic from private subnets to the internet, then relays
# the response back. Private resources are never directly reachable.
#
# NAT Gateways require a static public IP — that's the Elastic IP below.

resource "aws_eip" "nat" {
  # "vpc = true" associates this IP with the VPC (as opposed to EC2-Classic,
  # which is a very old AWS networking model you won't encounter today).
  domain = "vpc"

  # Must wait for the IGW to exist before the EIP can be used for NAT.
  depends_on = [aws_internet_gateway.main]

  tags = { Name = "nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id # NAT Gateway lives in a public subnet

  tags = { Name = "main" }
}

# ============================================================
# Route Tables
# ============================================================

# A route table is a set of rules that decide where network traffic goes.
# Every subnet must be associated with a route table.

# --- Public route table ---
# Routes internet-bound traffic (0.0.0.0/0) to the Internet Gateway.
# The ALB and other public resources use this.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"          # All traffic not destined for the VPC...
    gateway_id = aws_internet_gateway.main.id  # ...goes to the internet
  }

  tags = { Name = "public" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --- Private route table ---
# Routes internet-bound traffic to the NAT Gateway (not directly to the IGW).
# ECS tasks, RDS, and RDS Proxy use this.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id  # Goes through NAT, not the internet directly
  }

  tags = { Name = "private" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# Security Groups
# ============================================================

# Security groups are stateful firewalls attached to individual resources.
# "Stateful" means if you allow inbound traffic, the response is
# automatically allowed out — you don't need a separate outbound rule.
#
# The key security principle here is "least privilege" — each resource
# only accepts traffic from the specific resource that needs to reach it,
# not from the whole internet or VPC.

# --- ALB Security Group ---
# The load balancer faces the internet. Allow HTTPS from anywhere.
resource "aws_security_group" "alb" {
  name   = "alb"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Also allow HTTP so we can redirect to HTTPS (optional but common)
  ingress {
    description = "HTTP from internet (for redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic. The ALB needs to forward requests to ECS.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"          # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "alb" }
}

# --- ECS Security Group ---
# Django containers only accept traffic from the ALB on port 8000.
# Nobody else can reach them directly.
resource "aws_security_group" "ecs" {
  name   = "ecs"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "From ALB only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    # Reference the ALB security group ID instead of a CIDR range.
    # This means "allow traffic from any resource that has the ALB security group attached."
    # It's more precise than an IP range because ALB IPs can change.
    security_groups = [aws_security_group.alb.id]
  }

  # ECS needs outbound access to reach ECR (pull images), Secrets Manager,
  # CloudWatch (logs), and RDS Proxy.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ecs" }
}

# --- RDS Proxy Security Group ---
# The proxy accepts postgres connections (port 5432) from ECS only.
resource "aws_security_group" "rds_proxy" {
  name   = "rds-proxy"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "Postgres from ECS only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "rds-proxy" }
}

# --- RDS Security Group ---
# The database accepts postgres connections from the RDS Proxy only.
# ECS never talks to RDS directly — it always goes through the proxy.
resource "aws_security_group" "rds" {
  name   = "rds"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "Postgres from RDS Proxy only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds_proxy.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "rds" }
}
