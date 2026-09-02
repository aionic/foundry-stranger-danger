# ---------------------------------------------------------------------------
# Foundry projects
#
# Each project gets its own system-assigned managed identity. That identity is
# the subject of the entire isolation question: what it can reach in the shared
# Cosmos and Storage accounts is what determines whether projects are actually
# separated.
# ---------------------------------------------------------------------------

resource "azapi_resource" "project" {
  for_each = var.projects

  type      = "Microsoft.CognitiveServices/accounts/projects@2026-05-01"
  name      = each.key
  parent_id = azapi_resource.foundry.id
  location  = var.location
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      displayName = each.value.display_name
      description = each.value.description
    }
  }

  response_export_values = [
    "properties.internalId",
    "identity.principalId",
  ]

  schema_validation_enabled = false

  # The account serialises operations against itself. Two project PUTs issued
  # concurrently - or one issued while the model deployment is still settling -
  # return 409 RequestConflict. Retry rather than hand-ordering every
  # interaction with the account.
  retry = local.azapi_retry

  timeouts {
    create = "30m"
  }

  depends_on = [
    time_sleep.after_foundry_account,
    azurerm_cognitive_deployment.model,
  ]
}

locals {
  # 32-character hex, no dashes. Microsoft's docs call this both 'project ID'
  # and 'workspace ID'; they are the same value.
  project_internal_ids = {
    for k, p in azapi_resource.project : k => p.output.properties.internalId
  }

  project_principal_ids = {
    for k, p in azapi_resource.project : k => p.output.identity.principalId
  }

  # Cosmos container names use the dashed GUID rendering of internalId.
  project_guids = {
    for k, v in local.project_internal_ids : k => format(
      "%s-%s-%s-%s-%s",
      substr(v, 0, 8), substr(v, 8, 4), substr(v, 12, 4), substr(v, 16, 4), substr(v, 20, 12)
    )
  }

  # Expected container names, used to build container-scoped role assignments.
  #
  # The evidence scripts do NOT trust these - they enumerate what actually
  # exists and correlate it back to internalId. If the platform ever changes
  # this convention the evidence stays honest and these locals become the thing
  # that needs fixing.
  #
  # Split by WHEN the container comes into existence, because Cosmos rejects a
  # role assignment scoped to a container that does not exist yet:
  #   "The collection with name [...] in provided scope [...] could not be found."
  cosmos_container_suffixes_classic = [
    "thread-message-store",
    "system-thread-message-store",
    "agent-entity-store",
  ]

  # Created lazily on the project's first Responses API invocation.
  cosmos_container_suffixes_modern = [
    "agent-definitions-v1",
    "run-state-v1",
  ]

  cosmos_container_suffixes = concat(
    local.cosmos_container_suffixes_classic,
    local.cosmos_container_suffixes_modern,
  )

  # The subset that can actually be targeted by a container-scoped grant on this
  # apply. See var.modern_containers_exist.
  scopable_container_suffixes = var.modern_containers_exist ? local.cosmos_container_suffixes : local.cosmos_container_suffixes_classic

  cosmos_containers = {
    for k, guid in local.project_guids : k => [
      for s in local.cosmos_container_suffixes : "${guid}-${s}"
    ]
  }

  # Only the predictable one. The other container is
  # <guid>-<12 hex>-azureml-agent; the hex segment is assigned by the service
  # and cannot be derived, which is why blob grants use an ABAC name-prefix
  # condition rather than per-container scopes. Note the DASHED guid - the
  # documented no-dash form does not match what the service creates.
  predictable_blob_containers = {
    for k, guid in local.project_guids : k => {
      azureml = "${guid}-azureml-blobstore"
    }
  }

  project_endpoints = {
    for k, p in azapi_resource.project :
    k => "https://${local.names.foundry_account}.services.ai.azure.com/api/projects/${k}"
  }
}
