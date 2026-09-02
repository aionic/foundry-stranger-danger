# ---------------------------------------------------------------------------
# Project connections
#
# Property shapes are taken from the executable foundry-samples Bicep rather
# than the prose documentation. Where they disagree the Bicep wins - notably the
# Cosmos category, which the docs render as "AzureCosmosDb" but which the
# working template used "CosmosDB"; the live service canonicalizes it to
# "CosmosDb", so the declaration follows the returned value to avoid drift.
#
# metadata.ResourceId is not optional: Agent Service uses it to resolve the
# backing resource at runtime.
#
# CONNECTION NAMES ARE ACCOUNT-SCOPED, NOT PROJECT-SCOPED.
#
# The ARM path is /accounts/{account}/projects/{project}/connections/{name},
# which reads as though the name is scoped to the project. It is not. Creating
# the same connection name under a second project fails with:
#
#   UserError: Connection <name> already exist, and can only be updated by the
#   workspace that created it, which is the workspace with workspaceId:
#   .../workspaces/<account>@<other-project>@AML
#
# Microsoft's reference template does not hit this because it only ever deploys
# a single project. Every connection name here is therefore suffixed with the
# project key.
# ---------------------------------------------------------------------------

resource "azapi_resource" "connection_cosmos" {
  for_each = var.projects

  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name      = "${azurerm_cosmosdb_account.main.name}-${each.key}"
  parent_id = azapi_resource.project[each.key].id

  body = {
    properties = {
      category = "CosmosDb"
      target   = azurerm_cosmosdb_account.main.endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_cosmosdb_account.main.id
        location   = azurerm_resource_group.main.location
      }
    }
  }

  schema_validation_enabled = false

  retry = local.azapi_retry
}

resource "azapi_resource" "connection_storage" {
  for_each = var.projects

  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name      = "${azurerm_storage_account.main.name}-${each.key}"
  parent_id = azapi_resource.project[each.key].id

  body = {
    properties = {
      category = "AzureStorageAccount"
      target   = azurerm_storage_account.main.primary_blob_endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_storage_account.main.id
        location   = azurerm_resource_group.main.location
      }
    }
  }

  schema_validation_enabled = false

  retry = local.azapi_retry
}

resource "azapi_resource" "connection_search" {
  for_each = var.projects

  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name      = "${azurerm_search_service.main.name}-${each.key}"
  parent_id = azapi_resource.project[each.key].id

  body = {
    properties = {
      category = "CognitiveSearch"
      target   = "https://${azurerm_search_service.main.name}.search.windows.net"
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_search_service.main.id
        location   = azurerm_search_service.main.location
      }
    }
  }

  schema_validation_enabled = false

  retry = local.azapi_retry
}
