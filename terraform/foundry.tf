# ---------------------------------------------------------------------------
# Microsoft Foundry account
#
# Modern Foundry: Microsoft.CognitiveServices/accounts with project management
# enabled. This is NOT the legacy hub (Microsoft.MachineLearningServices
# workspace) model.
#
# azapi is used because azurerm has no support for allowProjectManagement,
# projects, or capability hosts.
# ---------------------------------------------------------------------------

resource "azapi_resource" "foundry" {
  type      = "Microsoft.CognitiveServices/accounts@2026-05-01"
  name      = local.names.foundry_account
  parent_id = azurerm_resource_group.main.id
  location  = var.location
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    properties = {
      # Required for the account to host projects at all.
      allowProjectManagement = true

      # Drives the *.services.ai.azure.com hostname the agent endpoints hang off.
      customSubDomainName = local.names.foundry_account

      publicNetworkAccess = "Enabled"

      # The service forces this to true for project-enabled accounts. Declaring
      # false provokes a full account PUT on every plan.
      disableLocalAuth = true
    }
  }

  response_export_values = [
    "properties.endpoint",
    "identity.principalId",
  ]

  schema_validation_enabled = false
}

# ARM returns before the account has finished settling, which makes the
# immediately-following project and connection PUTs flaky.
resource "time_sleep" "after_foundry_account" {
  depends_on      = [azapi_resource.foundry]
  create_duration = "60s"
}

resource "azurerm_cognitive_deployment" "model" {
  name                 = var.model_name
  cognitive_account_id = azapi_resource.foundry.id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = var.model_sku
    capacity = var.model_capacity
  }

  depends_on = [time_sleep.after_foundry_account]
}
