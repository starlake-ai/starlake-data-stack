output "instance_ip" {
  description = "Public IP address of the instance"
  value       = openstack_compute_instance_v2.instance.access_ip_v4
}
