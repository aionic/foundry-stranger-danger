data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# Base is stored in state, so the expiry tag does not drift on every plan.
resource "time_offset" "expiry" {
  offset_days = var.lifetime_days
}

locals {
  suffix = random_string.suffix.result

  names = {
    foundry_account = "${var.name_prefix}${local.suffix}"
    cosmos          = "cosmos-${var.name_prefix}-${local.suffix}"
    storage         = "st${var.name_prefix}${local.suffix}"
    search          = "srch-${var.name_prefix}-${local.suffix}"
    key_vault       = "kv-${var.name_prefix}-${local.suffix}"
    log_analytics   = "log-${var.name_prefix}-${local.suffix}"
    app_insights    = "appi-${var.name_prefix}-${local.suffix}"
  }

  # The Foundry Agent Service database. Created by the capability hosts, not by
  # this configuration, but its name is fixed and we need it for RBAC scopes.
  cosmos_database_name = "enterprise_memory"

  # The account serialises operations against itself and surfaces contention in
  # several shapes: 409 RequestConflict on concurrent writes, and 409
  # TransientError / "Etag conflict" when a child resource is deleted while the
  # account is still settling. All are retryable.
  azapi_retry = {
    error_message_regex = [
      "RequestConflict",
      "Another operation is in progress",
      "TransientError",
      "Etag conflict",
    ]
    interval_seconds     = 15
    max_interval_seconds = 120
  }

  # Capability hosts take far longer to settle, so they back off harder.
  azapi_retry_slow = {
    error_message_regex = [
      "RequestConflict",
      "Another operation is in progress",
      "TransientError",
      "Etag conflict",
    ]
    interval_seconds     = 30
    max_interval_seconds = 180
  }

  # Tenant governance automation disables public network access on data
  # resources shortly after creation unless these tags are present. Without
  # them the Foundry runtime itself is refused by the Cosmos firewall:
  #
  #   Request originated from IP <ip> through public internet. This is blocked
  #   by your Cosmos DB account firewall settings.
  #
  # Terraform sets public_network_access_enabled = true, so the drift appears
  # only after apply and looks like a service-side change.
  control_bypass_tags = var.apply_control_bypass_tags ? {
    SecurityControl = "ignore"
    CostControl     = "ignore"
  } : {}

  tags = merge(
    {
      purpose    = "security-validation"
      scenario   = "foundry-cross-project-isolation"
      owner      = var.owner
      managed_by = "terraform"
      autodelete = formatdate("YYYY-MM-DD", time_offset.expiry.rfc3339)
    },
    local.control_bypass_tags,
    var.extra_tags,
  )
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}
