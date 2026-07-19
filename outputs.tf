###############################################################################
# Primary outputs (id + arn) — the active namespace, whichever of the three
# types var.namespace_type selected.
###############################################################################

output "id" {
 description = "The ID of the active Cloud Map namespace (whichever of PRIVATE_DNS/PUBLIC_DNS/HTTP was selected)."
 value = local.namespace_id
}

output "arn" {
 description = <<EOT
The ARN of the active Cloud Map namespace (cross-resource reference type).
Format: arn:aws:servicediscovery:<region>:<account-id>:namespace/<namespace-id>.
EOT
 value = local.namespace_arn
}

output "name" {
 description = "The name of the namespace (var.namespace_name)."
 value = var.namespace_name
}

output "namespace_type" {
 description = "The namespace type this module instance created (PRIVATE_DNS, PUBLIC_DNS, or HTTP)."
 value = var.namespace_type
}

output "hosted_zone_id" {
 description = <<EOT
The ID of the Route 53 hosted zone Cloud Map auto-created for a PRIVATE_DNS or
PUBLIC_DNS namespace. Null for an HTTP namespace (no hosted zone is created).
EOT
 value = local.namespace_hosted_zone_id
}

output "http_name" {
 description = "The name of the HTTP namespace as reported by the provider. Null unless namespace_type = HTTP."
 value = try(aws_service_discovery_http_namespace.this[0].http_name, null)
}

###############################################################################
# Services
###############################################################################

output "service_ids" {
 description = "Map of services key (from var.services) to the aws_service_discovery_service id."
 value = { for k, s in aws_service_discovery_service.this: k => s.id }
}

output "service_arns" {
 description = "Map of services key (from var.services) to the aws_service_discovery_service ARN."
 value = { for k, s in aws_service_discovery_service.this: k => s.arn }
}

output "service_names" {
 description = "Map of services key (from var.services) to the service's rendered name (var.services[*].name, defaulted to the map key)."
 value = { for k, s in aws_service_discovery_service.this: k => s.name }
}

###############################################################################
# Instances
###############################################################################

output "instance_ids" {
 description = "Map of instances key (from var.instances) to the aws_service_discovery_instance id."
 value = { for k, i in aws_service_discovery_instance.this: k => i.id }
}

###############################################################################
# Tags
###############################################################################

output "tags_all" {
 description = "All tags on the active namespace, including those inherited from provider default_tags (resource tags win on key conflict)."
 value = local.namespace_tags_all
}
