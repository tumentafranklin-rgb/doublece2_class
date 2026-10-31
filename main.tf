terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "terraform-vpc"
      ManagedBy = "Terraform"
    }
  }
}

# --------------------
# Variables
# --------------------

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair in this region"
  type        = string
}

variable "admin_cidr" {
  description = "Your public IPv4 address followed by /32"
  type        = string

  validation {
    condition = (
      can(cidrnetmask(var.admin_cidr)) &&
      can(regex("/32$", var.admin_cidr))
    )
    error_message = "Enter a single IPv4 address with /32."
  }
}

variable "instance_type" {
  description = "An x86_64-compatible EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "enable_nat_gateway" {
  description = "Enable outbound internet for the private subnet; adds charges"
  type        = bool
  default     = false
}

# --------------------
# Availability zone and AMI
# --------------------

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --------------------
# VPC and subnets
# --------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "terraform-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "private-subnet"
  }
}

# --------------------
# Internet gateway and public routing
# --------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "internet-gateway"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --------------------
# Private routing and optional NAT
# --------------------

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-route-table"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "nat-elastic-ip"
  }
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public.id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "nat-gateway"
  }
}

resource "aws_route" "private_internet" {
  count = var.enable_nat_gateway ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

# --------------------
# Public security group
# --------------------

resource "aws_security_group" "public" {
  name_prefix = "public-ec2-"
  description = "Allow SSH from your public IP"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "public-ec2-security-group"
  }
}

resource "aws_vpc_security_group_ingress_rule" "public_ssh" {
  security_group_id = aws_security_group.public.id
  description       = "SSH from administrator"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "public" {
  security_group_id = aws_security_group.public.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --------------------
# Private security group
# --------------------

resource "aws_security_group" "private" {
  name_prefix = "private-ec2-"
  description = "Allow SSH from public EC2 security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "private-ec2-security-group"
  }
}

resource "aws_vpc_security_group_ingress_rule" "private_ssh" {
  security_group_id = aws_security_group.private.id
  description       = "SSH through public instance"

  referenced_security_group_id = aws_security_group.public.id

  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "private" {
  security_group_id = aws_security_group.private.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --------------------
# Public EC2 instance
# --------------------

resource "aws_instance" "public" {
  ami           = nonsensitive(data.aws_ssm_parameter.amazon_linux.value)
  instance_type = var.instance_type
  key_name      = "backup"

  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.public.id]

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "public-ec2"
  }
}

# --------------------
# Private EC2 instance
# --------------------

resource "aws_instance" "private" {
  ami           = nonsensitive(data.aws_ssm_parameter.amazon_linux.value)
  instance_type = var.instance_type
  key_name      = "devops"

  subnet_id                   = aws_subnet.private.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.private.id]

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "private-ec2"
  }
}

# --------------------
# Outputs
# --------------------

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "public_instance_id" {
  value = aws_instance.public.id
}

output "private_instance_id" {
  value = aws_instance.private.id
}

output "public_instance_ip" {
  value = aws_instance.public.public_ip
}

output "private_instance_ip" {
  value = aws_instance.private.private_ip
}