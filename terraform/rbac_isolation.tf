# ---------------------------------------------------------------------------
# Phase 2 - data-plane grants
#
# This file is the whole point of the exercise. It is where the cross-project
# boundary is either drawn or left open, and the two modes below are what the
# validation compares.
#
# COSMOS
#   documented: ONE grant per project, scoped at the 'enterprise_memory'
#               DATABASE. The compatibility name is retained for the broad
#               reference shape measured by this lab. That database is shared
#               by every project in the account, so the grant reaches other
#               projects' containers.
#
#   hardened:   One grant per container the project owns. The identity cannot
#               address another project's containers at all.
#
# STORAGE
#   Account-scoped with a project-container-prefix ABAC condition in BOTH modes.
#   Blob scope is therefore independent from the Cosmos comparison variable.
# ---------------------------------------------------------------------------

locals {
  # Keys must be resolvable at plan time, so they are built from the project key
  # and the static container suffix. The fully-qualified container name depends
  # on the project's internalId and is therefore only in the value.
  cosmos_container_grants = var.isolation_mode == "hardened" ? merge([
    for pk, _ in var.projects : {
      for s in local.scopable_container_suffixes : "${pk}|${s}" => {
        project   = pk
        container = "${local.project_guids[pk]}-${s}"
      }
    }
  ]...) : {}

  cosmos_database_scope = "${azurerm_cosmosdb_account.main.id}/dbs/${local.cosmos_database_name}"

  cosmos_data_contributor_role_id = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/${local.cosmos_sql_role_ids.data_contributor}"
}

# ---------------------------------------------------------------------------
# Cosmos - documented (database scope)
# ---------------------------------------------------------------------------

resource "azurerm_cosmosdb_sql_role_assignment" "project_database_scoped" {
  for_each = var.isolation_mode == "documented" ? var.projects : {}

  name                = uuidv5("dns", "proj-db-scope-${each.key}-${local.suffix}")
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = local.cosmos_data_contributor_role_id
  principal_id        = local.project_principal_ids[each.key]

  # Shared by every project in the account.
  scope = local.cosmos_database_scope

  depends_on = [time_sleep.after_capability_hosts]
}

# ---------------------------------------------------------------------------
# Cosmos - hardened (container scope)
# ---------------------------------------------------------------------------

resource "azurerm_cosmosdb_sql_role_assignment" "project_container_scoped" {
  for_each = local.cosmos_container_grants

  name                = uuidv5("dns", "proj-coll-scope-${each.key}-${local.suffix}")
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = local.cosmos_data_contributor_role_id
  principal_id        = local.project_principal_ids[each.value.project]

  scope = "${local.cosmos_database_scope}/colls/${each.value.container}"

  depends_on = [time_sleep.after_capability_hosts]
}

# ---------------------------------------------------------------------------
# Storage - account scope with an ABAC condition on container name prefix
#
# Per-container role assignments were the original approach, built from the
# documented names <workspaceId>-azureml-blobstore and
# <workspaceId>-agents-blobstore. That does not work, for two reasons found
# empirically:
#
#   1. The documented names are wrong. Real containers use the DASHED guid, and
#      the second is <guid>-<12 hex>-azureml-agent, not -agents-blobstore. The
#      hex segment is not predictable, so the name cannot be constructed at all.
#
#   2. Azure Storage ACCEPTS a role assignment scoped to a container that does
#      not exist. Cosmos rejects the equivalent. So the wrong grants applied
#      cleanly, reported success, and did nothing - a silent no-op that looks
#      exactly like least privilege in a portal or a plan.
#
# An ABAC condition on the container name prefix is scoped just as tightly, and
# is immune to both the naming discrepancy and to containers being created
# lazily after the grant.
# ---------------------------------------------------------------------------

locals {
  # Confines data actions to containers whose name begins with the project's
  # GUID. Non-data actions are unaffected, which is what the leading negated
  # ActionMatches block expresses.
  #
  # A condition may only reference actions the role actually grants - naming
  # blobs/write in a condition attached to Storage Blob Data Reader is rejected
  # with InvalidRoleAssignmentCondition. Hence one variant per role shape.
  blob_prefix_match = {
    for k, guid in local.project_guids :
    k => "(@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase '${guid}')"
  }

  # Storage Blob Data Reader
  blob_conditions_read = {
    for k, guid in local.project_guids : k => join("", [
      "((!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'}))",
      " OR ", local.blob_prefix_match[k], ")",
    ])
  }

  # Storage Blob Data Owner
  blob_conditions_owner = {
    for k, guid in local.project_guids : k => join("", [
      "((",
      "!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})",
      " AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'})",
      " AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete'})",
      " AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action'})",
      ") OR ", local.blob_prefix_match[k], ")",
    ])
  }
}

resource "azurerm_role_assignment" "project_blob_prefix_scoped" {
  for_each = var.projects

  scope              = azurerm_storage_account.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.storage_blob_data_owner}"
  principal_id       = local.project_principal_ids[each.key]
  principal_type     = "ServicePrincipal"

  condition_version = "2.0"
  condition         = local.blob_conditions_owner[each.key]

  depends_on = [time_sleep.after_capability_hosts]
}
