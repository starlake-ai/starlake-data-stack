output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = var.reserve_ip ? aws_eip.lb[0].public_ip : aws_instance.app_server.public_ip
}

output "instance_public_dns" {
  description = "Public DNS of the EC2 instance"
  value       = var.reserve_ip ? aws_eip.lb[0].public_dns : aws_instance.app_server.public_dns
}
