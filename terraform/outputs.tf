output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "location" {
  value = azurerm_resource_group.main.location
}

output "subscription_id" {
  value = var.subscription_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "isolation_mode" {
  description = "Which Cosmos grant scoping this deployment used."
  value       = var.isolation_mode
}

# ---------------------------------------------------------------------------
# Foundry
# ---------------------------------------------------------------------------

output "foundry_account_name" {
  value = azapi_resource.foundry.name
}

output "foundry_account_id" {
  value = azapi_resource.foundry.id
}

output "model_deployment_name" {
  value = azurerm_cognitive_deployment.model.name
}

output "projects" {
  description = "Per-project identifiers the evidence scripts key off."
  value = {
    for k, _ in var.projects : k => {
      name         = k
      resource_id  = azapi_resource.project[k].id
      principal_id = local.project_principal_ids[k]
      # 32-char source value returned by the project API.
      internal_id = local.project_internal_ids[k]
      # Dashed GUID. Observed Cosmos and Blob container names use this form.
      guid     = local.project_guids[k]
      endpoint = local.project_endpoints[k]
      agent = {
        name          = var.projects[k].agent_name
        instructions  = var.projects[k].agent_instructions
        sample_prompt = var.projects[k].sample_prompt
      }
      expected_cosmos_containers  = local.cosmos_containers[k]
      predictable_blob_containers = values(local.predictable_blob_containers[k])
      expected_blob_condition     = local.blob_conditions_owner[k]
    }
  }
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

output "cosmos_account_name" {
  value = azurerm_cosmosdb_account.main.name
}

output "cosmos_endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}

output "cosmos_database_name" {
  value = local.cosmos_database_name
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "storage_blob_endpoint" {
  value = azurerm_storage_account.main.primary_blob_endpoint
}

output "search_service_name" {
  value = azurerm_search_service.main.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.workspace_id
}

# ---------------------------------------------------------------------------
# Probes
#
# Secrets. Consumed by 11-test-cross-access.ps1 via `terraform output -json`.
# ---------------------------------------------------------------------------

output "probe_identities" {
  description = "Probe service principal credentials and the permission shape each one models."
  sensitive   = true
  value = {
    for k, v in local.probes : k => {
      display_name  = azuread_application.probe[k].display_name
      client_id     = azuread_application.probe[k].client_id
      object_id     = azuread_service_principal.probe[k].object_id
      client_secret = azuread_application_password.probe[k].value
      models        = v.broad ? "documented Cosmos scope + broad Blob connectivity control" : "hardened: container/ABAC-scoped to project ${v.project}"
      project       = v.project
    }
  }
}
