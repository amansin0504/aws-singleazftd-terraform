output "firepower-appliance" {
  value       = aws_instance.ftdv.*.public_ip
  description = "Firepower Management Address"
}
