data "aws_caller_identity" "current" {}
terraform {
  required_version = ">= 1.6"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  
  backend "s3" {
    bucket         = "terraform-state-jlomka-1765962452"
    key            = "terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "terraform-lock"
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Environment = "dev"
      Project     = "fastapi-freetier"
      ManagedBy   = "terraform"
    }
  }
}


resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = { Name = "dev-vpc" }
}


resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "dev-igw" }
}


resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  
  tags = { Name = "dev-public-subnet" }
}

resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"      # Другой диапазон (не 10.0.1.0!)
  availability_zone = "eu-central-1b"    # Другая зона (не 1a!)
  map_public_ip_on_launch = true

  tags = {
    Name = "dev-public-subnet-2"
  }
}


resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = { Name = "dev-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ec2" {
  name        = "dev-ec2-sg"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.main.id
  
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # В продакшене ограничьте своим IP
  }
  

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = { Name = "dev-ec2-sg" }
}


resource "aws_security_group" "rds" {
  name        = "dev-rds-sg"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
    description     = "PostgreSQL from EC2"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = { Name = "dev-rds-sg" }
}


resource "aws_db_subnet_group" "main" {
  name       = "dev-db-subnet"
  subnet_ids = [aws_subnet.public.id, aws_subnet.public_2.id]
  
  tags = { Name = "dev-db-subnet-group" }
}


resource "random_password" "db_password" {
  length  = 32
  special = true
}

resource "random_id" "secret_suffix" {
  byte_length = 4
}


resource "aws_secretsmanager_secret" "db_creds" {
  name                    = "dev-db-password-${random_id.secret_suffix.hex}"
  recovery_window_in_days = 0
  
  tags = { Name = "dev-db-credentials" }
}

resource "aws_secretsmanager_secret_version" "db_creds" {
  secret_id = aws_secretsmanager_secret.db_creds.id
  secret_string = jsonencode({
    username          = "postgres"
    password          = random_password.db_password.result
    engine            = "postgres"
    host              = aws_db_instance.main.address
    port              = 5432
    dbname            = "fastapi_db"
    connection_string = "postgresql://postgres:${random_password.db_password.result}@${aws_db_instance.main.address}:5432/fastapi_db"
  })
}


resource "aws_db_instance" "main" {
  identifier     = "dev-postgres"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro"  
  
  allocated_storage = 20  
  storage_type      = "gp2"  
  storage_encrypted = true
  
  db_name  = "fastapi_db"
  username = "postgres"
  password = random_password.db_password.result
  
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  backup_retention_period = 1  
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"
  
  skip_final_snapshot = true
  multi_az            = false  
  publicly_accessible = false
  
  enabled_cloudwatch_logs_exports = ["postgresql"]
  
  tags = { Name = "dev-postgres" }
}


resource "aws_key_pair" "deployer" {
  key_name   = "dev-deployer-key"
  public_key = file("~/.ssh/id_rsa.pub")
}


resource "aws_instance" "app" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"  
  
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.deployer.key_name
  

  user_data = templatefile("${path.module}/user-data.sh", {
    db_secret_arn = aws_secretsmanager_secret.db_creds.arn
    aws_region    = var.aws_region
    aws_account_id = data.aws_caller_identity.current.account_id
  })
  
  root_block_device {
    volume_size = 30  # FREE TIER: 30GB
    volume_type = "gp2"
    encrypted   = true
  }
  
  tags = {
    Name = "dev-app-server"
  }
  
  depends_on = [aws_db_instance.main]
}


resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  
  tags = { Name = "dev-app-eip" }
}


data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical
  
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


resource "aws_iam_role" "ec2_role" {
  name = "dev-ec2-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_secrets_policy" {
  name = "dev-ec2-secrets-policy"
  role = aws_iam_role.ec2_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "dev-ec2-profile"
  role = aws_iam_role.ec2_role.name
}


