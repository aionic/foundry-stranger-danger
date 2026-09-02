# ---------------------------------------------------------------------------
# Built-in role definition IDs.
#
# Referenced by GUID rather than by name on purpose: Microsoft renamed the
# Foundry RBAC roles (Azure AI User -> Foundry User, and siblings) and both sets
# of names are in circulation during the rollout. The GUIDs did not change.
# ---------------------------------------------------------------------------

locals {
  role_ids = {
    # Control plane
    cosmos_db_operator            = "230815da-be43-4aae-9cb4-875f7bd000aa"
    storage_account_contributor   = "17d1049b-9a84-46fb-8f53-869881c3d3ab"
    search_index_data_contributor = "8ebe5a00-799e-43f5-93ac-243d3dce84a7"
    search_service_contributor    = "7ca78c08-252a-4471-8644-bb5ff32d4ba0"
    monitoring_metrics_publisher  = "3913510d-42f4-4e42-8a64-420c390055eb"

    # Storage data plane
    storage_blob_data_owner       = "b7e6dc6d-f1e8-4753-8033-0f276bb0955b"
    storage_blob_data_contributor = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
    storage_blob_data_reader      = "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"

    # Foundry
    foundry_user            = "53ca6127-db72-4b80-b1b0-d745d6d5456d" # formerly Azure AI User
    foundry_project_manager = "eadc314b-1a2d-4efa-be10-5d325db5065e" # formerly Azure AI Project Manager
  }

  role_definition_id_prefix = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions"

  # Cosmos DB SQL (data plane) role definitions are per-account, not per-subscription.
  cosmos_sql_role_ids = {
    data_reader      = "00000000-0000-0000-0000-000000000001"
    data_contributor = "00000000-0000-0000-0000-000000000002"
  }
}

# ---------------------------------------------------------------------------
# Phase 1 - provisioning grants
#
# These must exist BEFORE the capability hosts are created. The capability host
# provisions each project's containers using the project's managed identity, so
# without these the capability host PUT fails.
#
# Note the shape: every Phase 1 grant is at ACCOUNT scope, because at this point
# the per-project containers do not exist yet and cannot be targeted. Phase 1 is
# intentionally broad; Phase 2 is where the boundary is supposed to be drawn.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "project_cosmos_operator" {
  for_each = var.projects

  scope              = azurerm_cosmosdb_account.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.cosmos_db_operator}"
  principal_id       = local.project_principal_ids[each.key]
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "project_storage_account_contributor" {
  for_each = var.projects

  scope              = azurerm_storage_account.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.storage_account_contributor}"
  principal_id       = local.project_principal_ids[each.key]
  principal_type     = "ServicePrincipal"
}

# INTENTIONAL LAB CONDITION: Search has no Phase 2 hardening in this
# repository. Each project retains service-scoped object and index-data roles
# so the shared-service boundary can be measured. A production design that
# requires vector isolation should use one Search service per project.
resource "azurerm_role_assignment" "project_search_index_data_contributor" {
  for_each = var.projects

  scope              = azurerm_search_service.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.search_index_data_contributor}"
  principal_id       = local.project_principal_ids[each.key]
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "project_search_service_contributor" {
  for_each = var.projects

  scope              = azurerm_search_service.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.search_service_contributor}"
  principal_id       = local.project_principal_ids[each.key]
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "project_appinsights_metrics_publisher" {
  for_each = var.projects

  scope              = azurerm_application_insights.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.monitoring_metrics_publisher}"
  principal_id       = local.project_principal_ids[each.key]
  principal_type     = "ServicePrincipal"
}

# Role assignments are eventually consistent. Creating a capability host against
# a not-yet-propagated grant fails, and capability hosts cannot be updated - the
# only recovery is to delete and recreate the project.
resource "time_sleep" "after_phase1_rbac" {
  depends_on = [
    azurerm_role_assignment.project_cosmos_operator,
    azurerm_role_assignment.project_storage_account_contributor,
    azurerm_role_assignment.project_search_index_data_contributor,
    azurerm_role_assignment.project_search_service_contributor,
    azurerm_role_assignment.project_appinsights_metrics_publisher,
  ]
  create_duration = "60s"
}

# ---------------------------------------------------------------------------
# Deployer access
#
# Lets the operator create and invoke agents, and read both projects' data as
# the control arm of the experiment.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "deployer_foundry_project_manager" {
  scope              = azapi_resource.foundry.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.foundry_project_manager}"
  principal_id       = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "deployer_foundry_user" {
  scope              = azapi_resource.foundry.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.foundry_user}"
  principal_id       = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "deployer_blob_reader" {
  count = var.grant_deployer_data_access ? 1 : 0

  scope              = azurerm_storage_account.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.storage_blob_data_reader}"
  principal_id       = data.azurerm_client_config.current.object_id
}

# Account-wide Cosmos read for the deployer. Deliberately broad: this is the
# control that proves both projects' containers exist and hold distinct data,
# so that a DENY elsewhere in the matrix is a real denial and not an empty
# container.
resource "azurerm_cosmosdb_sql_role_assignment" "deployer_data_reader" {
  count = var.grant_deployer_data_access ? 1 : 0

  name                = uuidv5("dns", "deployer-data-reader-${local.suffix}")
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/${local.cosmos_sql_role_ids.data_reader}"
  principal_id        = data.azurerm_client_config.current.object_id
  scope               = azurerm_cosmosdb_account.main.id
}
