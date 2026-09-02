# ---------------------------------------------------------------------------
# Probe service principals
#
# A project's system-assigned managed identity cannot be impersonated, so we
# cannot obtain a token as it and test its grants directly. Instead each probe
# receives a CLONE of a specific permission shape. We are testing the
# authorization model, using a surrogate principal with identical scoping.
#
#   probe-scoped-<project>  container-scoped to that project's containers only
#                           -> models a hardened project identity
#
#   probe-broad             scoped at the shared 'enterprise_memory' database
#                           and at the storage ACCOUNT
#                           -> models documented Cosmos scope and provides a
#                              positive Blob connectivity control. Its Blob
#                              grant is intentionally broader than guidance.
#
# Probes get READ roles. If one identity can read another project's
# conversation history, the boundary has already failed; write access would add
# nothing to the finding and a great deal of risk.
#
# The generated client secrets land in local Terraform state. This is a
# throwaway validation subscription, state is gitignored, and 99-destroy.ps1
# removes the applications. Do not reuse this pattern anywhere durable.
# ---------------------------------------------------------------------------

data "azuread_client_config" "current" {}

locals {
  probes = var.enable_probe_identities ? merge(
    { for k, _ in var.projects : "scoped-${k}" => { project = k, broad = false } },
    { "broad" = { project = null, broad = true } },
  ) : {}

  scoped_probes = { for k, v in local.probes : k => v if !v.broad }

  # Keys are plan-time resolvable; the container name is not, so it lives in the value.
  probe_cosmos_container_grants = var.enable_probe_identities ? merge([
    for pk, _ in var.projects : {
      for s in local.scopable_container_suffixes : "scoped-${pk}|${s}" => {
        probe     = "scoped-${pk}"
        container = "${local.project_guids[pk]}-${s}"
      }
    }
  ]...) : {}

  cosmos_data_reader_role_id = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/${local.cosmos_sql_role_ids.data_reader}"
}

resource "azuread_application" "probe" {
  for_each = local.probes

  display_name = "sp-foundry-isolation-probe-${each.key}-${local.suffix}"
  owners       = [data.azuread_client_config.current.object_id]

  description = each.value.broad ? "Isolation probe: mirrors the documented database-scoped grant" : "Isolation probe: mirrors a hardened container-scoped grant for project ${each.value.project}"
}

resource "azuread_service_principal" "probe" {
  for_each = local.probes

  client_id = azuread_application.probe[each.key].client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "probe" {
  for_each = local.probes

  application_id = azuread_application.probe[each.key].id
  display_name   = "isolation-probe"

  # Sourced from time_offset rather than timestamp() so the value is stable
  # across plans and matches the environment's autodelete tag.
  end_date = time_offset.expiry.rfc3339
}

# ---------------------------------------------------------------------------
# Scoped probes - container-level grants
# ---------------------------------------------------------------------------

resource "azurerm_cosmosdb_sql_role_assignment" "probe_container_scoped" {
  for_each = local.probe_cosmos_container_grants

  name                = uuidv5("dns", "probe-coll-${each.key}-${local.suffix}")
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = local.cosmos_data_reader_role_id
  principal_id        = azuread_service_principal.probe[each.value.probe].object_id

  scope = "${local.cosmos_database_scope}/colls/${each.value.container}"

  depends_on = [time_sleep.after_capability_hosts]
}

resource "azurerm_role_assignment" "probe_blob_prefix_scoped" {
  for_each = local.scoped_probes

  scope              = azurerm_storage_account.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.storage_blob_data_reader}"
  principal_id       = azuread_service_principal.probe[each.key].object_id
  principal_type     = "ServicePrincipal"

  condition_version = "2.0"
  condition         = local.blob_conditions_read[each.value.project]

  depends_on = [time_sleep.after_capability_hosts]
}

# ---------------------------------------------------------------------------
# Broad probe - documented Cosmos shape + Blob connectivity control
#
# One database-scoped Cosmos grant and one account-scoped Blob grant. The
# Cosmos shape mirrors documented setup. The Blob shape is deliberately broad
# so the matrix has a positive connectivity control; it does not model the
# documented per-container Blob assignments.
# ---------------------------------------------------------------------------

resource "azurerm_cosmosdb_sql_role_assignment" "probe_database_scoped" {
  for_each = var.enable_probe_identities ? { broad = local.probes["broad"] } : {}

  name                = uuidv5("dns", "probe-db-${local.suffix}")
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = local.cosmos_data_reader_role_id
  principal_id        = azuread_service_principal.probe["broad"].object_id

  scope = local.cosmos_database_scope

  depends_on = [time_sleep.after_capability_hosts]
}

resource "azurerm_role_assignment" "probe_blob_account_scoped" {
  for_each = var.enable_probe_identities ? { broad = local.probes["broad"] } : {}

  scope              = azurerm_storage_account.main.id
  role_definition_id = "${local.role_definition_id_prefix}/${local.role_ids.storage_blob_data_reader}"
  principal_id       = azuread_service_principal.probe["broad"].object_id
  principal_type     = "ServicePrincipal"

  depends_on = [time_sleep.after_capability_hosts]
}

