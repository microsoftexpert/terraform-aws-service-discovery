###############################################################################
# Identity
###############################################################################

variable "namespace_name" {
 description = <<EOT
The name of the AWS Cloud Map namespace (the keystone identity of this module),
e.g. "internal.local" (PRIVATE_DNS), "example.com" (PUBLIC_DNS), or
"my-app" (HTTP). FORCE-NEW — Cloud Map has no Update API for a namespace's name;
any change destroys and recreates the namespace (and every service/instance
hanging off it, since services reference the namespace by id).
EOT
 type = string
}

variable "namespace_type" {
 description = <<EOT
The type of Cloud Map namespace this module creates. FORCE-NEW — switching
between namespace types (e.g. PRIVATE_DNS -> HTTP) is not an in-place operation;
it destroys the existing namespace resource and creates a different one.

 - PRIVATE_DNS: DNS-based discovery inside one VPC. Requires vpc_id. AWS
 auto-creates a private Route 53 hosted zone for the namespace.
 - PUBLIC_DNS: DNS-based discovery on the public internet. AWS auto-creates
 a public Route 53 hosted zone for the namespace.
 - HTTP: API-only discovery (DiscoverInstances) — no DNS records, no
 hosted zone. This is what ECS Service Connect uses.
EOT
 type = string

 validation {
 condition = contains(["PRIVATE_DNS", "PUBLIC_DNS", "HTTP"], var.namespace_type)
 error_message = "namespace_type must be one of: PRIVATE_DNS, PUBLIC_DNS, HTTP."
 }
}

variable "vpc_id" {
 description = <<EOT
ID of the VPC to associate with a PRIVATE_DNS namespace. FORCE-NEW — required
when namespace_type = PRIVATE_DNS, and must be omitted for PUBLIC_DNS/HTTP
namespaces (they are not VPC-scoped). Wire from terraform-aws-vpc (the VPC must
have DNS support and DNS hostnames enabled).
EOT
 type = string
 default = null

 validation {
 condition = (var.namespace_type == "PRIVATE_DNS") == (var.vpc_id != null)
 error_message = "vpc_id is required when namespace_type = PRIVATE_DNS, and must be null otherwise."
 }

 validation {
 condition = var.vpc_id == null || can(regex("^vpc-[0-9a-f]{8,}$", var.vpc_id))
 error_message = "vpc_id must be a VPC id (vpc-xxxxxxxx) or null."
 }
}

variable "description" {
 description = "Free-text description stored on the namespace. Null (default) leaves it unset."
 type = string
 default = null
}

###############################################################################
# Services (child collection — for_each over map(object(...)))
#
# Each entry is one aws_service_discovery_service. Keyed by a stable caller
# string used as the service's DNS name unless `name` overrides it, mirroring
# the terraform-aws-route53-zone `records` pattern. All services in this module
# call register against the single namespace created above.
###############################################################################

variable "services" {
 description = <<EOT
Map of Cloud Map services to create under this namespace, keyed by a stable
caller string (e.g. "web", "orders-api"). Each entry is one
aws_service_discovery_service.

Per service:
 - name: the service's name (and DNS name component
 when dns_config is set). Defaults to the map
 key. FORCE-NEW.
 - description: free-text description.
 - force_destroy: delete all registered instances so the
 service can be destroyed without error.
 Defaults to false (the safe posture) — a
 destroy fails loudly if instances remain
 rather than silently deregistering them.
 - discovery_type: set to "HTTP" for API-only discovery
 (DiscoverInstances, no DNS record) — the shape
 used under an HTTP namespace. Null (default)
 for DNS-based services under PRIVATE_DNS /
 PUBLIC_DNS namespaces.

 - dns_config.routing_policy: MULTIVALUE (default) or WEIGHTED. FORCE-NEW
 is not required to change this, but changing
 the record `type` below is.
 - dns_config.dns_records: list of { type, ttl }. type is one of
 A, AAAA, SRV, CNAME (FORCE-NEW per record
 entry). ttl is the resolver cache TTL in
 seconds. Required whenever dns_config is set.
 Not supported (must be null) under an HTTP
 namespace — HTTP namespace services have no
 DNS records.

 - health_check_config: Route 53 health check against a live
 endpoint. ONLY supported for services in a
 PUBLIC_DNS namespace (AWS provider
 constraint) — mutually exclusive with
 health_check_custom_config.
 type: HTTP (default), HTTPS, or TCP. FORCE-NEW.
 resource_path: path Route 53 requests. Defaults to "/".
 failure_threshold: consecutive failed checks before the
 endpoint is marked unhealthy. Max 10.
 Defaults to 1.

 - health_check_custom_config: an application-reported health signal (the
 caller calls UpdateInstanceCustomHealthStatus)
 instead of an unauthenticated HTTP(S)/TCP
 probe. Mutually exclusive with
 health_check_config. FORCE-NEW.
 NOTE: this block is DEPRECATED upstream in
 the aws provider in favor of
 health_check_config — AWS has not removed it,
 but new work should prefer health_check_config
 unless the app-reported signal is genuinely
 needed. See SCOPE.md for the tradeoff.
 failure_threshold: always 1 per the provider (30s intervals
 before Cloud Map flips instance health).

 - tags: merged with the module-wide tags.

 services = {
 web = {
 dns_config = {
 dns_records = [{ type = "A", ttl = 10 }]
 }
 }
 orders-api = {
 dns_config = { dns_records = [{ type = "A", ttl = 10 }] }
 health_check_config = { failure_threshold = 3 }
 }
 }
EOT
 type = map(object({
 name = optional(string)
 description = optional(string)
 force_destroy = optional(bool, false)
 discovery_type = optional(string)

 dns_config = optional(object({
 routing_policy = optional(string, "MULTIVALUE")
 dns_records = list(object({
 type = string
 ttl = number
 }))
 }))

 health_check_config = optional(object({
 type = optional(string, "HTTP")
 resource_path = optional(string, "/")
 failure_threshold = optional(number, 1)
 }))

 health_check_custom_config = optional(object({
 failure_threshold = optional(number, 1)
 }))

 tags = optional(map(string), {})
 }))
 default = {}

 validation {
 condition = alltrue(flatten([
 for s in var.services: [
 for r in try(s.dns_config.dns_records, []): contains(["A", "AAAA", "SRV", "CNAME"], r.type)
 ]
 ]))
 error_message = "Every services[*].dns_config.dns_records[*].type must be one of A, AAAA, SRV, CNAME."
 }

 validation {
 condition = alltrue([
 for s in var.services: s.dns_config == null || contains(["MULTIVALUE", "WEIGHTED"], s.dns_config.routing_policy)
 ])
 error_message = "Every services[*].dns_config.routing_policy must be MULTIVALUE or WEIGHTED."
 }

 validation {
 condition = alltrue([
 for s in var.services: s.health_check_config == null || contains(["HTTP", "HTTPS", "TCP"], s.health_check_config.type)
 ])
 error_message = "Every services[*].health_check_config.type must be HTTP, HTTPS, or TCP."
 }

 validation {
 condition = alltrue([
 for s in var.services: s.discovery_type == null || s.discovery_type == "HTTP"
 ])
 error_message = "services[*].discovery_type only accepts \"HTTP\" (or null) — it is the only value the provider supports."
 }

 validation {
 condition = alltrue([
 for s in var.services: !(s.health_check_config != null && s.health_check_custom_config != null)
 ])
 error_message = "Each service may set at most one of health_check_config or health_check_custom_config, not both."
 }

 validation {
 condition = alltrue([
 for s in var.services: s.health_check_config == null || var.namespace_type == "PUBLIC_DNS"
 ])
 error_message = "health_check_config is only supported for services registered under a PUBLIC_DNS namespace (AWS provider constraint)."
 }

 validation {
 condition = alltrue([
 for s in var.services: !(var.namespace_type == "HTTP" && s.dns_config != null)
 ])
 error_message = "dns_config is not supported for services under an HTTP namespace — HTTP namespaces are discovered via DiscoverInstances only, not DNS."
 }
}

###############################################################################
# Instances (child collection — for_each over map(object(...)))
###############################################################################

variable "instances" {
 description = <<EOT
Map of service-registry instances to create, keyed by a stable caller string
(e.g. "web-1a", "orders-task-abc123"). Each entry is one
aws_service_discovery_instance registering one endpoint against a service
defined in var.services.

Per instance:
 - service_key: the var.services map key this instance registers against.
 - instance_id: the Cloud Map instance id. FORCE-NEW. Defaults to the map
 key when omitted.
 - attributes: map of instance attributes (e.g. AWS_INSTANCE_IPV4,
 AWS_INSTANCE_PORT, AWS_EC2_INSTANCE_ID, or custom keys) — see
 the RegisterInstance API reference for the supported keys
 and syntax per namespace/service type.

 instances = {
 web-1a = {
 service_key = "web"
 attributes = { AWS_INSTANCE_IPV4 = "10.0.1.10", AWS_INSTANCE_PORT = "8080" }
 }
 }
EOT
 type = map(object({
 service_key = string
 instance_id = optional(string)
 attributes = map(string)
 }))
 default = {}

 validation {
 condition = alltrue([for i in var.instances: contains(keys(var.services), i.service_key)])
 error_message = "Every instances[*].service_key must reference a key present in var.services."
 }
}

###############################################################################
# Universal tail
###############################################################################

variable "tags" {
 description = <<EOT
A map of tags to assign to all taggable resources created by this module (the
namespace and every service — aws_service_discovery_instance is not taggable).
These merge with provider-level default_tags; resource tags win on key
conflict. The computed tags_all output reflects the merged set.
EOT
 type = map(string)
 default = {}
}

# NOTE: no `timeouts` variable in this module. Confirmed against the live
# hashicorp/aws v6.54.0 schema (`terraform providers schema -json`) — none of
# aws_service_discovery_private_dns_namespace, aws_service_discovery_public_dns_namespace,
# aws_service_discovery_http_namespace, aws_service_discovery_service, or
# aws_service_discovery_instance expose a `timeouts {}` block, so there is
# nothing for a timeouts variable to render into. This is a documented
# deviation from the universal-tail convention — see SCOPE.md "Provider
# gotchas".
