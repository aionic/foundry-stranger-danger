# ---------------------------------------------------------------------------
# Capability hosts
#
# These are what actually turn a project into an agent host, and what provision
# each project's containers in the shared Cosmos and Storage accounts.
#
# Three constraints drive the shape of this file:
#   1. Capability hosts are CREATE-ONLY. Same name + different config returns
#      400; a second host on the same scope returns 409. There is no update
#      path - recovery means deleting the project.
#   2. The account host must exist before any project host.
#   3. There is no inheritance. Connections referenced on the account host are
#      not used by a project unless that project's own host names them.
# ---------------------------------------------------------------------------

resource "azapi_resource" "account_capability_host" {
  type      = "Microsoft.CognitiveServices/accounts/capabilityHosts@2025-06-01"
  name      = "caphost-account"
  parent_id = azapi_resource.foundry.id

  # The account host takes nothing but the kind. Storage bindings live on the
  # project hosts.
  body = {
    properties = {
      capabilityHostKind = "Agents"
    }
  }

  schema_validation_enabled = false

  retry = local.azapi_retry

  depends_on = [
    time_sleep.after_phase1_rbac,
    azurerm_cognitive_deployment.model,
  ]
}

# ---------------------------------------------------------------------------
# Serialising project capability hosts
#
# All projects share one Cosmos account, and each capability host creates the
# 'enterprise_memory' database if it is missing. Creating them concurrently
# races on that database. Terraform cannot express "resource N depends on
# resource N-1" across a for_each, so each project waits a multiple of the
# stagger interval based on its sorted position.
#
# This is a heuristic, not a lock. If a capability host ever fails to provision,
# raise capability_host_stagger_seconds before anything else.
# ---------------------------------------------------------------------------

locals {
  project_order = { for i, k in sort(keys(var.projects)) : k => i }
}

resource "time_sleep" "capability_host_stagger" {
  for_each = var.projects

  depends_on      = [azapi_resource.account_capability_host]
  create_duration = "${local.project_order[each.key] * var.capability_host_stagger_seconds}s"
}

resource "azapi_resource" "project_capability_host" {
  for_each = var.projects

  type      = "Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-06-01"
  name      = "caphost-${each.key}"
  parent_id = azapi_resource.project[each.key].id

  body = {
    properties = {
      capabilityHostKind       = "Agents"
      threadStorageConnections = [azapi_resource.connection_cosmos[each.key].name]
      storageConnections       = [azapi_resource.connection_storage[each.key].name]
      vectorStoreConnections   = [azapi_resource.connection_search[each.key].name]
    }
  }

  schema_validation_enabled = false

  retry = local.azapi_retry_slow

  timeouts {
    create = "60m"
    delete = "60m"
  }

  depends_on = [time_sleep.capability_host_stagger]
}

# Containers are provisioned asynchronously as the capability host settles.
# Phase 2 role assignments target those containers by name.
resource "time_sleep" "after_capability_hosts" {
  depends_on      = [azapi_resource.project_capability_host]
  create_duration = "120s"
}
