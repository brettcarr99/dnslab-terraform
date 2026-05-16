terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "random_id" "tsig_key" {
  byte_length = 32
}

# ── Fixed private IPs (known at plan time, safe to template into user-data) ──

locals {
  root_ip        = cidrhost(var.subnet_cidr, 10)
  tld_ip         = cidrhost(var.subnet_cidr, 11)
  sld_ip         = cidrhost(var.subnet_cidr, 12)
  resolver_ip    = cidrhost(var.subnet_cidr, 13)
  client_ip      = cidrhost(var.subnet_cidr, 14)
  dnsmaster_ip   = cidrhost(var.subnet_cidr, 15)
  tsig_secret    = random_id.tsig_key.b64_std
  scripts_bucket = aws_s3_bucket.dns_lab_scripts.id
}

# ── Network ──────────────────────────────────────────────────────────────────

resource "aws_vpc" "dns_lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "dns-lab-vpc" }
}

resource "aws_internet_gateway" "dns_lab" {
  vpc_id = aws_vpc.dns_lab.id

  tags = { Name = "dns-lab-igw" }
}

resource "aws_subnet" "dns_lab" {
  vpc_id                  = aws_vpc.dns_lab.id
  cidr_block              = var.subnet_cidr
  map_public_ip_on_launch = true

  tags = { Name = "dns-lab-subnet" }
}

resource "aws_route_table" "dns_lab" {
  vpc_id = aws_vpc.dns_lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dns_lab.id
  }

  tags = { Name = "dns-lab-rt" }
}

resource "aws_route_table_association" "dns_lab" {
  subnet_id      = aws_subnet.dns_lab.id
  route_table_id = aws_route_table.dns_lab.id
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "dns_lab" {
  name        = "dns-lab-sg"
  description = "DNS lab - SSH from allowed CIDR, DNS within VPC, full egress"
  vpc_id      = aws_vpc.dns_lab.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "DNS UDP (intra-VPC)"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "DNS TCP (intra-VPC)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All egress (yum updates, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "dns-lab-sg" }
}

# ── EC2 Instances ─────────────────────────────────────────────────────────────

resource "aws_instance" "root_server" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.dns_lab.id
  private_ip                  = local.root_ip
  vpc_security_group_ids      = [aws_security_group.dns_lab.id]
  iam_instance_profile        = aws_iam_instance_profile.dns_lab.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user_data/root.sh", {
    root_ip        = local.root_ip
    tld_ip         = local.tld_ip
    dnsmaster_ip   = local.dnsmaster_ip
    tsig_secret    = local.tsig_secret
    sns_topic_arn  = aws_sns_topic.dns_lab.arn
    scripts_bucket = local.scripts_bucket
    aws_region     = var.aws_region
  })

  tags = {
    Name = "dns-lab-root"
    Role = "root-nameserver"
  }
}

resource "aws_instance" "tld_server" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.dns_lab.id
  private_ip                  = local.tld_ip
  vpc_security_group_ids      = [aws_security_group.dns_lab.id]
  iam_instance_profile        = aws_iam_instance_profile.dns_lab.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user_data/tld.sh", {
    tld_ip         = local.tld_ip
    sld_ip         = local.sld_ip
    dnsmaster_ip   = local.dnsmaster_ip
    tsig_secret    = local.tsig_secret
    sns_topic_arn  = aws_sns_topic.dns_lab.arn
    scripts_bucket = local.scripts_bucket
    aws_region     = var.aws_region
  })

  tags = {
    Name = "dns-lab-tld"
    Role = "tld-nameserver"
  }
}

resource "aws_instance" "sld_server" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.dns_lab.id
  private_ip                  = local.sld_ip
  vpc_security_group_ids      = [aws_security_group.dns_lab.id]
  iam_instance_profile        = aws_iam_instance_profile.dns_lab.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user_data/sld.sh", {
    sld_ip         = local.sld_ip
    dnsmaster_ip   = local.dnsmaster_ip
    tsig_secret    = local.tsig_secret
    sns_topic_arn  = aws_sns_topic.dns_lab.arn
    scripts_bucket = local.scripts_bucket
    aws_region     = var.aws_region
  })

  tags = {
    Name = "dns-lab-sld"
    Role = "2ld-nameserver"
  }
}

resource "aws_instance" "resolver" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.dns_lab.id
  private_ip                  = local.resolver_ip
  vpc_security_group_ids      = [aws_security_group.dns_lab.id]
  iam_instance_profile        = aws_iam_instance_profile.dns_lab.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user_data/resolver.sh", {
    root_ip        = local.root_ip
    sns_topic_arn  = aws_sns_topic.dns_lab.arn
    scripts_bucket = local.scripts_bucket
    aws_region     = var.aws_region
  })

  tags = {
    Name = "dns-lab-resolver"
    Role = "resolver"
  }
}

resource "aws_instance" "client" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.dns_lab.id
  private_ip                  = local.client_ip
  vpc_security_group_ids      = [aws_security_group.dns_lab.id]
  iam_instance_profile        = aws_iam_instance_profile.dns_lab.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user_data/client.sh", {
    resolver_ip    = local.resolver_ip
    sns_topic_arn  = aws_sns_topic.dns_lab.arn
    scripts_bucket = local.scripts_bucket
    aws_region     = var.aws_region
  })

  tags = {
    Name = "dns-lab-client"
    Role = "client"
  }
}

resource "aws_instance" "dnsmaster" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.dns_lab.id
  private_ip                  = local.dnsmaster_ip
  vpc_security_group_ids      = [aws_security_group.dns_lab.id]
  iam_instance_profile        = aws_iam_instance_profile.dns_lab.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user_data/dnsmaster.sh", {
    root_ip        = local.root_ip
    tld_ip         = local.tld_ip
    sld_ip         = local.sld_ip
    tsig_secret    = local.tsig_secret
    sns_topic_arn  = aws_sns_topic.dns_lab.arn
    scripts_bucket = local.scripts_bucket
    aws_region     = var.aws_region
  })

  tags = {
    Name = "dns-lab-dnsmaster"
    Role = "dns-primary"
  }
}
