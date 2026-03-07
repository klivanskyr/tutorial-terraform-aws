provider "aws" {
  region = "us-west-1"
}

#resoure resoure_type resoure name. Resource address = "aws_instance.app_server"
# aws_instance = ec2
resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]

  tags = {
    Name        = var.instance_name
    Project     = "terraform-tutorial"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (Ubuntu's AWS account)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-22.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = "terraform-tutorial-key"
  public_key = file("~/.ssh/terraform-tutorial.pub")

  tags = {
    Name        = "terraform-tutorial-key"
    Project     = "terraform-tutorial"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

resource "aws_security_group" "allow_ssh" {
  name        = "allow_ssh"
  description = "Allow SSH inbound"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # open to all IPs — fine for learning
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "allow-ssh"
    Project     = "terraform-tutorial"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}