output "alb_dns_name" {
  description = "ALB DNS name — use as Private Connection Host address in Agent Space"
  value       = aws_lb.mcp.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID (for Route53 alias records)"
  value       = aws_lb.mcp.zone_id
}

output "cluster_name" {
  value = aws_ecs_cluster.mcp.name
}

output "service_names" {
  description = "ECS service names per account"
  value       = { for k, svc in aws_ecs_service.mcp : k => svc.name }
}

output "ecr_repositories" {
  description = "ECR repository URLs — push images here before services start"
  value       = local.ecr_urls
}

output "push_commands" {
  description = "Commands to build and push images"
  value = <<-EOT
    # Login to ECR
    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com

    # Build and push AWS MCP image
    docker build --platform linux/amd64 -t ${local.ecr_urls["aws"]}:latest -f deploy/Dockerfile .
    docker push ${local.ecr_urls["aws"]}:latest

    # Build and push Aliyun MCP image (only if using aliyun accounts)
    docker build --platform linux/amd64 -t ${local.ecr_urls["aliyun"]}:latest -f deploy/Dockerfile.aliyun .
    docker push ${local.ecr_urls["aliyun"]}:latest

    # Force ECS to pull new images
    aws ecs update-service --cluster ${aws_ecs_cluster.mcp.name} --service <service-name> --force-new-deployment --region ${var.region}
  EOT
}

output "dns_instructions" {
  description = "CNAME records to create"
  value       = { for k, acct in var.accounts : k => "${acct.host} → CNAME → ${aws_lb.mcp.dns_name}" }
}

output "vpc_id" {
  value = local.vpc_id
}

output "private_subnet_ids" {
  value = local.private_subnet_ids
}
