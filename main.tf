###############################################################################
# Namespace (keystone) — exactly one of the three namespace types is created,
# selected by var.namespace_type via a conditional singleton (count = 0/1).
# This is the correct idiom here rather than a for_each child collection:
# a caller picks ONE namespace type per module call, and Cloud Map has no
# "generic" namespace resource to for_each over.
###############################################################################

resource "aws_service_discovery_private_dns_namespace" "this" {
 count = var.namespace_type == "PRIVATE_DNS" ? 1: 0

 name = var.namespace_name
 description = var.description
 vpc = var.vpc_id

 tags = var.tags
}

resource "aws_service_discovery_public_dns_namespace" "this" {
 count = var.namespace_type == "PUBLIC_DNS" ? 1: 0

 name = var.namespace_name
 description = var.description

 tags = var.tags
}

resource "aws_service_discovery_http_namespace" "this" {
 count = var.namespace_type == "HTTP" ? 1: 0

 name = var.namespace_name
 description = var.description

 tags = var.tags
}

locals {
 # Whichever of the three namespace singletons is active per var.namespace_type
 # — at most one of the three count expressions above ever materializes, so
 # concat + one() collapses cleanly to that resource's attribute (or errors
 # loudly if that invariant is ever violated, which is the safe failure mode).
 namespace_id = one(concat(aws_service_discovery_private_dns_namespace.this[*].id,
 aws_service_discovery_public_dns_namespace.this[*].id,
 aws_service_discovery_http_namespace.this[*].id,))

 namespace_arn = one(concat(aws_service_discovery_private_dns_namespace.this[*].arn,
 aws_service_discovery_public_dns_namespace.this[*].arn,
 aws_service_discovery_http_namespace.this[*].arn,))

 # Only PRIVATE_DNS / PUBLIC_DNS namespaces carry a Route 53 hosted zone;
 # HTTP namespaces do not, so this is null under namespace_type = HTTP.
 namespace_hosted_zone_id = one(concat(aws_service_discovery_private_dns_namespace.this[*].hosted_zone,
 aws_service_discovery_public_dns_namespace.this[*].hosted_zone,))

 namespace_tags_all = one(concat(aws_service_discovery_private_dns_namespace.this[*].tags_all,
 aws_service_discovery_public_dns_namespace.this[*].tags_all,
 aws_service_discovery_http_namespace.this[*].tags_all,))
}

###############################################################################
# Services
#
# for_each over var.services keyed by a stable caller string (no count), so
# adding/removing a service never re-indexes the others. Every service
# registers against the single namespace created above.
###############################################################################

resource "aws_service_discovery_service" "this" {
 for_each = var.services

 name = coalesce(each.value.name, each.key)
 description = try(each.value.description, null)
 namespace_id = local.namespace_id
 force_destroy = try(each.value.force_destroy, false)
 type = try(each.value.discovery_type, null)

 dynamic "dns_config" {
 for_each = each.value.dns_config != null ? { this = each.value.dns_config }: {}
 content {
 namespace_id = local.namespace_id
 routing_policy = dns_config.value.routing_policy

 dynamic "dns_records" {
 for_each = dns_config.value.dns_records
 content {
 type = dns_records.value.type
 ttl = dns_records.value.ttl
 }
 }
 }
 }

 dynamic "health_check_config" {
 for_each = each.value.health_check_config != null ? { this = each.value.health_check_config }: {}
 content {
 type = health_check_config.value.type
 resource_path = health_check_config.value.resource_path
 failure_threshold = health_check_config.value.failure_threshold
 }
 }

 dynamic "health_check_custom_config" {
 for_each = each.value.health_check_custom_config != null ? { this = each.value.health_check_custom_config }: {}
 content {
 failure_threshold = health_check_custom_config.value.failure_threshold
 }
 }

 tags = merge(var.tags, try(each.value.tags, {}))
}

###############################################################################
# Instances
#
# for_each over var.instances keyed by a stable caller string. Each instance
# registers one endpoint against the service named in service_key.
###############################################################################

resource "aws_service_discovery_instance" "this" {
 for_each = var.instances

 instance_id = coalesce(each.value.instance_id, each.key)
 service_id = aws_service_discovery_service.this[each.value.service_key].id
 attributes = each.value.attributes
}
