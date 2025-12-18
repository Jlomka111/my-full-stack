#!/bin/bash

# 1. Логирование (все выводы пойдут в /var/log/user-data.log)
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

set -e # Прекратить выполнение при ошибке

echo "--- [1/6] Обновление системы и установка зависимостей ---"
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl \
    git \
    jq \
    docker.io \
    docker-compose-v2 \
    awscli

# Включаем Docker
systemctl enable --now docker
usermod -aG docker ubuntu

echo "--- [2/6] Получение метаданных инстанса (IMDSv2) ---"
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)

echo "--- [3/6] Настройка директорий приложения ---"
APP_DIR="/opt/app"
mkdir -p $APP_DIR
chown ubuntu:ubuntu $APP_DIR

echo "--- [4/6] Получение секретов из AWS Secrets Manager ---"
# Мы используем ARN секрета, который Terraform передаст в этот скрипт
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ${db_secret_arn} --region ${aws_region} --query SecretString --output text)

DB_HOST=$(echo $SECRET_JSON | jq -r .host)
DB_PASS=$(echo $SECRET_JSON | jq -r .password)
DB_USER=$(echo $SECRET_JSON | jq -r .username)
DB_NAME=$(echo $SECRET_JSON | jq -r .dbname)

echo "--- [5/6] Создание файла конфигурации .env ---"
# Этот файл будет использовать docker-compose
cat > $APP_DIR/.env << EOF
# Основные настройки
DOMAIN=$PUBLIC_IP
ENVIRONMENT=production
PROJECT_NAME="FastAPI-Project"
SECRET_KEY=$(openssl rand -base64 32)

# Настройки базы данных (из RDS)
POSTGRES_SERVER=$DB_HOST
POSTGRES_PORT=5432
POSTGRES_DB=$DB_NAME
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASS

# Настройки CORS и хостов
BACKEND_CORS_ORIGINS=["http://$PUBLIC_IP", "http://localhost"]
FRONTEND_HOST=http://$PUBLIC_IP

# Настройки ECR
ECR_URL=${aws_account_id}.dkr.ecr.${aws_region}.amazonaws.com
EOF

chown ubuntu:ubuntu $APP_DIR/.env

echo "--- [6/6] Авторизация в Docker Registry (ECR) ---"
aws ecr get-login-password --region ${aws_region} | \
    docker login --username AWS --password-stdin ${aws_account_id}.dkr.ecr.${aws_region}.amazonaws.com

echo "--- ✅ USER DATA COMPLETED СUCCESSFULLY ---"