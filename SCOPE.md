# tf-mod-aws-service-discovery — SCOPE

Composite module for **AWS Cloud Map** (the service formerly/still branded
"Service Discovery" in its Terraform resource names). A single module call
creates **one namespace** (of a caller-chosen type), plus the services and
service-registry instances that hang off it. This is the modern complement to
— and, via `aws_ecs_service.service_registries`, the direct dependency of —
Amazon ECS service discovery / ECS Service Connect.

- **Module type:** Composite
- **Primary resource (keystone-ish):** one of `aws_service_discovery_private_dns_namespace.this`,
  `aws_service_discovery_public_dns_namespace.this`, `aws_service_discovery_http_namespace.this`
  — selected as a conditional singleton (`count = 0/1`) by `var.namespace_type`.
  There is no single hard-coded keystone resource address because Cloud Map has
  no generic namespace type; a caller picks exactly one of the three per module
  call, so the "keystone" is whichever singleton materializes.

## In-scope resources
- `aws_service_discovery_private_dns_namespace` — namespace singleton (namespace_type = PRIVATE_DNS)
- `aws_service_discovery_public_dns_namespace` — namespace singleton (namespace_type = PUBLIC_DNS)
- `aws_service_discovery_http_namespace` — namespace singleton (namespace_type = HTTP)
- `aws_service_discovery_service` — 0..N, `for_each` over `var.services`, keyed by a stable caller string
- `aws_service_discovery_instance` — 0..N, `for_each` over `var.instances`, keyed by a stable caller string

## Out-of-scope resources (consumed by reference)
- The VPC for a PRIVATE_DNS namespace — consumed as `vpc_id` (a plain `vpc-xxxxxxxx` string), not managed here
- The Route 53 hosted zone Cloud Map auto-creates for PRIVATE_DNS/PUBLIC_DNS namespaces — Cloud Map owns its
  full lifecycle; this module surfaces its id (`hosted_zone_id`) read-only and never manages
  `aws_route53_zone`/`aws_route53_record` against it directly
- The ECS service (`aws_ecs_service`) that wires `service_registries { registry_arn = ... }` at this
  module's service ARN — consumed by reference, not managed here
- EC2 instances / ECS tasks / any other compute whose IP or instance ID is registered via `var.instances`

## Consumes
| Input | Type | Source module |
|---|---|---|
| `vpc_id` | `string` (`vpc-xxxxxxxx`) | `tf-mod-aws-vpc` (required only when `namespace_type = PRIVATE_DNS`) |
| `services[*].health_check_config` health target | n/a (probed by Route 53, not Terraform-managed) | — |

> This module sits mid-stack: it consumes only a VPC id (for private namespaces) and is itself consumed
> by compute/container modules that need a service-registry ARN to advertise into.

## Required IAM permissions
| Action | Required for |
|---|---|
| `servicediscovery:CreateHttpNamespace`, `servicediscovery:CreatePrivateDnsNamespace`, `servicediscovery:CreatePublicDnsNamespace` | Namespace creation (whichever type `var.namespace_type` selects) |
| `servicediscovery:GetNamespace`, `servicediscovery:ListNamespaces` | Namespace read-back / drift detection |
| `servicediscovery:DeleteNamespace` | Namespace destroy |
| `servicediscovery:CreateService`, `servicediscovery:GetService`, `servicediscovery:UpdateService`, `servicediscovery:DeleteService`, `servicediscovery:ListServices` | Service lifecycle (`var.services`) |
| `servicediscovery:RegisterInstance`, `servicediscovery:GetInstance`, `servicediscovery:DeregisterInstance`, `servicediscovery:ListInstances` | Instance lifecycle (`var.instances`) |
| `servicediscovery:TagResource`, `servicediscovery:UntagResource`, `servicediscovery:ListTagsForResource` | Tag management on namespace/service |
| `route53:CreateHostedZone`, `route53:GetHostedZone`, `route53:ListHostedZonesByName`, `route53:DeleteHostedZone` | PRIVATE_DNS/PUBLIC_DNS namespaces auto-provision (and auto-delete) a hidden Route 53 hosted zone — Cloud Map calls these Route 53 APIs on the caller's behalf |
| `ec2:DescribeVpcs`, `ec2:DescribeRegions` | PRIVATE_DNS namespace creation validates the supplied VPC |

No `iam:PassRole` is required — this module registers no execution role. Callers wiring an ECS task
into `service_registries` handle that role in `tf-mod-aws-ecs-service`, not here.

## AWS Prerequisites
- **No mandatory service-linked role for Cloud Map itself.** (ECS Service Connect, which commonly
  layers on top of an HTTP namespace, has its own ECS-side IAM/SLR requirements — out of scope here.)
- **PRIVATE_DNS namespaces auto-create a *private* Route 53 hosted zone** associated with `var.vpc_id`.
  That zone is entirely Cloud-Map-managed: deleting the namespace deletes the zone. Do not also create
  an `aws_route53_zone` for the same domain against the same VPC — the two would collide.
- **PUBLIC_DNS namespaces auto-create a *public* Route 53 hosted zone** and are internet-resolvable once
  delegated. There is no `us-east-1` constraint for Cloud Map itself (unlike CloudFront/ACM/WAFv2).
- **The VPC must have `enable_dns_support` and `enable_dns_hostnames` set to `true`** before a
  PRIVATE_DNS namespace will resolve correctly inside it.
- **ECS Service Connect** uses an HTTP namespace (`namespace_type = "HTTP"`) as its shared namespace —
  this module is the correct source for that namespace when wiring `tf-mod-aws-ecs-service`.
- **Quotas:** default Cloud Map quotas include 100 namespaces per account/Region, 6,000 services per
  account/Region, and 400,000 registered instances per account/Region (all soft, raisable via Service
  Quotas). Namespace count is rarely a constraint at Casey's scale; large ECS estates can approach the
  service/instance quotas and should request an increase proactively.

## Emits
| Output | Description | Consumed by |
|---|---|---|
| `id` | Active namespace id | Any module referencing this namespace (e.g. an ECS Service Connect `namespace` argument) |
| `arn` | Active namespace ARN | IAM policies scoping `servicediscovery:*` actions to this namespace |
| `name` | Namespace name | Documentation / DNS composition |
| `namespace_type` | Which of PRIVATE_DNS/PUBLIC_DNS/HTTP this instance created | Conditional wiring in calling code |
| `hosted_zone_id` | Auto-created Route 53 zone id (null for HTTP) | Any module needing to look up records in the hidden zone (read-only) |
| `http_name` | HTTP namespace's reported name (null unless HTTP) | Debug/verification |
| `service_ids` | Map of `services` key -> service id | `aws_ecs_service.service_registries.registry_arn` callers typically want `service_arns` instead |
| `service_arns` | Map of `services` key -> service ARN | `tf-mod-aws-ecs-service` `service_registries` block |
| `service_names` | Map of `services` key -> rendered service name | Documentation / cross-checking DNS names |
| `instance_ids` | Map of `instances` key -> instance id | Debug/verification |
| `tags_all` | All tags on the active namespace incl. provider `default_tags` | Governance/audit |

## Provider gotchas
- **`namespace_type` is FORCE-NEW in effect.** There is no "convert a PRIVATE_DNS namespace to HTTP"
  operation — this module renders three mutually-exclusive resources gated by `count`, so changing
  `var.namespace_type` destroys whichever singleton existed and creates a different resource type
  entirely (and every `aws_service_discovery_service` hanging off it, since services reference
  `namespace_id`).
- **Namespace `name`/`vpc` have no Update API.** Confirmed against the live `hashicorp/aws` v6.54.0
  schema (`terraform providers schema -json`): none of the three namespace resources declare any
  `block_types` (no nested blocks at all, and no `timeouts {}`), and the provider implements no
  in-place update path for `name` or `vpc` — any change requires replacement.
- **No `timeouts` variable in this module — a deliberate deviation from the universal-tail
  convention.** Verified via the same schema dump: `aws_service_discovery_private_dns_namespace`,
  `aws_service_discovery_public_dns_namespace`, `aws_service_discovery_http_namespace`,
  `aws_service_discovery_service`, and `aws_service_discovery_instance` expose zero customizable
  `timeouts` blocks. Adding a `timeouts` variable with nothing to render it into would be dead code,
  so it is omitted entirely rather than faked.
- **`dns_config.dns_records[*].type` and `dns_config.namespace_id` force new on change** — changing a
  service's record type (e.g. A -> SRV) recreates the `aws_service_discovery_service`. `routing_policy`
  does not force new.
- **`health_check_config` is silently ignored (and rejected by this module's validation) on
  non-PUBLIC_DNS namespaces** — AWS only evaluates Route 53 health checks against a public DNS record.
  Use `health_check_custom_config` (app-reported health) under PRIVATE_DNS, or skip health checking
  under HTTP namespaces (which have no DNS records to check in the first place).
- **`health_check_custom_config` is deprecated upstream in the `hashicorp/aws` provider** in favor of
  `health_check_config`, per the live schema/docs pull for this module. AWS has not removed the
  underlying API, so it remains supported here, but new designs should default to
  `health_check_config` unless an application-reported health signal is genuinely required (see
  "Secure-by-default decisions" below for the tradeoff this creates).
- **Destroying a namespace with active service instances fails.** `aws_service_discovery_instance`
  resources must be destroyed (or `force_destroy = true` set on the owning `aws_service_discovery_service`)
  before the parent service — and every service before the namespace. Terraform's own dependency graph
  handles the ordering automatically as long as instances/services are declared in this same module
  call; a namespace whose services were created **outside** Terraum (e.g. by ECS Service Connect
  auto-registering instances) will not destroy cleanly without `force_destroy` on the service or manual
  deregistration first.
- **`aws_service_discovery_instance.attributes` is entirely free-form** — the provider does not validate
  keys against the RegisterInstance API's expected attribute names (e.g. `AWS_INSTANCE_IPV4`,
  `AWS_INSTANCE_PORT`, `AWS_EC2_INSTANCE_ID`); a typo produces a silently-ignored attribute, not a plan
  error. Cross-check attribute names against the AWS Cloud Map RegisterInstance API reference.

## Secure-by-default decisions
| Posture | Default | Opt-out |
|---|---|---|
| Service destroy safety | `force_destroy = false` | Set `services[*].force_destroy = true` to allow destroying a service with live registered instances |
| Health-check signal preference | Neither `health_check_config` nor `health_check_custom_config` is set by default (both null) — the module does not force a choice | Caller supplies one explicitly per service |
| VPC scoping for private discovery | `vpc_id` required and validated (regex + cross-field check) for `PRIVATE_DNS`, forbidden otherwise | n/a — enforced by variable validation, not a runtime toggle |

> **Tradeoff documented, not defaulted:** `health_check_config` performs an *unauthenticated* HTTP(S)/TCP
> probe against a live endpoint — simple, but it means Route 53 itself is making outbound calls to
> whatever `resource_path` you configure, with no auth. `health_check_custom_config` instead relies on
> the application calling `UpdateInstanceCustomHealthStatus` to report its own health — no unauthenticated
> network probe, but it requires the workload to integrate with the Cloud Map API and is deprecated
> upstream in the provider. For NPI-adjacent services behind a PRIVATE_DNS namespace (where
> `health_check_config` isn't even legal — see "Provider gotchas"), `health_check_custom_config` is the
> only first-party health-check option; for PUBLIC_DNS namespaces, prefer `health_check_config` per the
> provider's own deprecation guidance unless the app-reported signal is a firm requirement. This module
> deliberately does not pick one for you — set the block that matches your posture.

## Design decisions
- **One namespace per module call, chosen via `count`-gated singletons, not a `for_each` over namespace
  type.** A caller creates exactly one namespace per invocation in every real usage pattern this library
  has seen (one Cloud Map namespace per environment/cluster); modeling namespace type as a `for_each` key
  would let a single call accidentally create two live namespaces sharing the same `namespace_name`,
  which Cloud Map does not support cleanly. `count = var.namespace_type == "X" ? 1 : 0` on each of the
  three namespace resources, collapsed via `one(concat(...))` for cross-references, keeps exactly one
  namespace resource in state and gives a single stable output surface (`id`/`arn`/etc.) regardless of
  which type was chosen.
- **Services and instances are still `for_each` child collections** keyed by stable caller strings — the
  "one keystone, N children" composite shape holds even though the keystone itself is a conditional
  singleton rather than a single hard-coded resource address.
- **`instances[*].service_key` is validated against `keys(var.services)`** at plan time so a typo'd
  service reference fails with a clear `validation` error instead of an opaque "index does not exist"
  crash deep in the `for_each` expansion.
- Resource count: 5 resource types — well under the 35-type ceiling; no split risk.
