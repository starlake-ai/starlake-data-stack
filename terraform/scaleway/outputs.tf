output "instance_ip" {
  description = "Public IP address of the instance"
  value       = scaleway_instance_server.web.public_ip
}
