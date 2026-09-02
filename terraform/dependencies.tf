# ---------------------------------------------------------------------------
# Azure Cosmos DB for NoSQL - BYO thread/agent storage
#
# The 'enterprise_memory' database and its per-project containers are created by
# the Foundry capability hosts, not here. This configuration only provides the
# account and disables key-based auth so that every access is an Entra identity
# we can attribute.
# ---------------------------------------------------------------------------

resource "azurerm_cosmosdb_account" "main" {
  name                = local.names.cosmos
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  # Forces all data-plane access through Entra ID + Cosmos data-plane RBAC,
  # which is the control being validated. With keys enabled the test would be
  # meaningless.
  local_authentication_enabled = false

  minimal_tls_version           = "Tls12"
  public_network_access_enabled = true

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.main.location
    failover_priority = 0
  }

  dynamic "capabilities" {
    for_each = var.cosmos_capacity_mode == "serverless" ? [1] : []
    content {
      name = "EnableServerless"
    }
  }

  dynamic "capacity" {
    for_each = var.cosmos_capacity_mode == "provisioned" ? [1] : []
    content {
      total_throughput_limit = var.cosmos_total_throughput_limit
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Storage - BYO file storage
#
# Two containers per project are created by the capability host. Observed names:
#   <dashed-project-guid>-azureml-blobstore
#   <dashed-project-guid>-<service-assigned-12-hex>-azureml-agent
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "main" {
  name                = local.names.storage
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Same rationale as Cosmos: no shared keys means every blob request carries an
  # Entra identity that RBAC and ABAC can be evaluated against.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Azure AI Search - BYO vector store
#
# Required by the project capability host (vectorStoreConnections) even though
# the hello-world agents perform no retrieval.
# ---------------------------------------------------------------------------

resource "azurerm_search_service" "main" {
  name                = local.names.search
  resource_group_name = azurerm_resource_group.main.name
  location            = coalesce(var.search_location, var.location)
  sku                 = var.search_sku

  local_authentication_enabled  = false
  public_network_access_enabled = true
  partition_count               = 1
  replica_count                 = 1

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Key Vault
#
# Listed as a standard agent setup dependency. Not referenced by any capability
# host property.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "main" {
  name                = local.names.key_vault
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  tags = local.tags
}
