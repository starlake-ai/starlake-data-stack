# Security Group
resource "aws_security_group" "starlake" {
  name        = "starlake-data-stack-sg"
  description = "Allow inbound traffic for Starlake Data Stack"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Gizmo"
    from_port   = 10900
    to_port     = 10900
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "starlake-sg"
  }
}

# Key Pair
resource "aws_key_pair" "deployer" {
  key_name   = "starlake-deployer-key"
  public_key = file(var.public_key_path)
}

# AMI (Ubuntu 22.04 LTS)
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

# EC2 Instance
resource "aws_instance" "app_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.deployer.key_name

  vpc_security_group_ids = [aws_security_group.starlake.id]

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/startup.sh", {
    repo_url     = var.repo_url
    repo_branch  = var.repo_branch
    repo_tag     = var.repo_tag
    enable_https = var.enable_https
    domain_name  = var.domain_name
    email        = var.email
  })

  # Replacing startup script trigger if it changes
  user_data_replace_on_change = true

  tags = {
    Name = "StarlakeDataStack"
  }
}

# Elastic IP (reserved if requested)
resource "aws_eip" "lb" {
  count    = var.reserve_ip ? 1 : 0
  instance = aws_instance.app_server.id
  domain   = "vpc"
}
