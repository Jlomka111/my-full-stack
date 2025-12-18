output "ec2_public_ip" {
  description = "EC2 Public IP"
  value       = aws_eip.app.public_ip
}

output "rds_endpoint" {
  description = "RDS Endpoint"
  value       = aws_db_instance.main.endpoint
}

output "db_secret_command" {
  description = "Command to get DB credentials"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db_creds.id} --region ${var.aws_region}"
}

output "ssh_command" {
  description = "SSH to EC2"
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_eip.app.public_ip}"
}

output "app_url" {
  description = "Application URL"
  value       = "http://${aws_eip.app.public_ip}"
}

output "api_docs_url" {
  description = "API Documentation"
  value       = "http://${aws_eip.app.public_ip}:8000/docs"
}

output "estimated_monthly_cost" {
  description = "Estimated cost"
  value       = "$0-3/month (Free Tier year 1), $20/month after"
}
