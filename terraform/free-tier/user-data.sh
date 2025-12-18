#!/bin/bash
set -e

# Логирование
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "Starting user data script..."

# Обновление системы
apt-get update
apt-get upgrade -y

# Установка Docker
sh get-docker.sh
systemctl enable docker
systemctl start docker

# Docker Compose
curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# AWS CLI
apt-get install -y awscli jq

# Создание пользователя для приложения
useradd -m -s /bin/bash appuser
usermod -aG docker appuser

# Создание директории для приложения
mkdir -p /opt/app
chown appuser:appuser /opt/app

# Получение credentials из Secrets Manager
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id ${db_secret_arn} \
  --region ${aws_region} \
  --query SecretString \
  --output text)

DB_HOST=$(echo $DB_SECRET | jq -r .host)
DB_PASSWORD=$(echo $DB_SECRET | jq -r .password)

# Создание .env файла
cat > /opt/app/.env << EOF
DOMAIN=\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
ENVIRONMENT=production
PROJECT_NAME="FastAPI Project"
BACKEND_CORS_ORIGINS=["http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"]
SECRET_KEY=$(openssl rand -base64 32)
FIRST_SUPERUSER=admin@example.com
FIRST_SUPERUSER_PASSWORD=changethis123

POSTGRES_SERVER=$DB_HOST
POSTGRES_PORT=5432
POSTGRES_DB=fastapi_db
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$DB_PASSWORD

FRONTEND_HOST=http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
EOF

chown appuser:appuser /opt/app/.env

echo "User data script completed!"