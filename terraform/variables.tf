variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "location" {
  description = "Azure region. Must support Foundry Agent Service and the chosen model."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Resource group to create. Everything in this build lives inside it."
  type        = string
  default     = "rg-foundry-isolation-wus3"
}

variable "name_prefix" {
  description = "Short prefix for generated resource names. Lowercase alphanumeric."
  type        = string
  default     = "fnd"

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.name_prefix))
    error_message = "name_prefix must be 2-6 lowercase alphanumeric characters."
  }
}

# ---------------------------------------------------------------------------
# The variable this whole build exists to exercise.
# ---------------------------------------------------------------------------

variable "isolation_mode" {
  description = <<-EOT
    Controls how the Cosmos DB data-plane grant for each project managed identity
    is scoped.

      documented - Reproduces the broad reference shape tested by this lab: a single
                   Cosmos DB Built-in Data Contributor assignment scoped at the
                   'enterprise_memory' DATABASE. That database is shared by every
                   project in the account, so the grant spans other projects'
                   containers.

      hardened   - One Cosmos DB Built-in Data Contributor assignment per
                   container that belongs to the project. Least privilege.

                   Cannot be applied to a clean deployment: Cosmos rejects a
                   grant scoped to a container that does not exist, and the
                   modern runtime's containers are created only on a project's
                   first agent invocation. See var.modern_containers_exist.

    Storage uses an account-scoped role with a project-prefix ABAC condition in
    both modes; Cosmos is where the two modes differ.
  EOT
  type        = string
  default     = "hardened"

  validation {
    condition     = contains(["documented", "hardened"], var.isolation_mode)
    error_message = "isolation_mode must be either 'documented' or 'hardened'."
  }
}

# ---------------------------------------------------------------------------
# Projects and their agents
# ---------------------------------------------------------------------------

variable "projects" {
  description = <<-EOT
    The Foundry projects to create. Two entries model the cross-project question.
    Each project gets its own managed identity, connections, capability host and
    hello-world agent with distinct instructions and a distinct user prompt, so
    the data written into each project's containers is visibly different.
  EOT
  type = map(object({
    display_name       = string
    description        = string
    agent_name         = string
    agent_instructions = string
    sample_prompt      = string
  }))

  default = {
    alpha = {
      display_name       = "Project Alpha"
      description        = "Isolation validation project A"
      agent_name         = "alpha-hello-agent"
      agent_instructions = "You are ALPHA, the agent for Project Alpha. Always begin your reply with the literal token ALPHA-CANARY. Keep answers to one short sentence."
      sample_prompt      = "Introduce yourself and state which project you belong to."
    }
    bravo = {
      display_name       = "Project Bravo"
      description        = "Isolation validation project B"
      agent_name         = "bravo-hello-agent"
      agent_instructions = "You are BRAVO, the agent for Project Bravo. Always begin your reply with the literal token BRAVO-CANARY. Keep answers to one short sentence."
      sample_prompt      = "Introduce yourself and state which project you belong to."
    }
  }

  validation {
    condition     = length(var.projects) >= 2
    error_message = "At least two projects are required to test cross-project isolation."
  }
}

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

variable "model_name" {
  description = "Model to deploy for the agents."
  type        = string
  default     = "gpt-4o"
}

variable "model_version" {
  description = "Model version."
  type        = string
  default     = "2024-11-20"
}

variable "model_sku" {
  description = "Deployment SKU."
  type        = string
  default     = "GlobalStandard"
}

variable "model_capacity" {
  description = "Deployment capacity in thousands of TPM."
  type        = number
  default     = 50
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

variable "cosmos_capacity_mode" {
  description = <<-EOT
    serverless  - No RU/s ceiling to manage and negligible cost for a validation
                  environment. Documented as supported by standard agent setup.

    provisioned - Sets a total throughput limit instead. Use this only if a
                  capability host fails to provision under serverless. Two
                  projects running Responses API agents need >= 10,000 RU/s
                  (5 containers x 1000 RU/s x 2 projects).
  EOT
  type        = string
  default     = "serverless"

  validation {
    condition     = contains(["serverless", "provisioned"], var.cosmos_capacity_mode)
    error_message = "cosmos_capacity_mode must be either 'serverless' or 'provisioned'."
  }
}

variable "cosmos_total_throughput_limit" {
  description = "Account-wide RU/s cap. Only applies when cosmos_capacity_mode is 'provisioned'."
  type        = number
  default     = 12000
}

variable "search_sku" {
  description = <<-EOT
    Azure AI Search SKU.

    'basic' is the default because the hello-world agents perform no retrieval -
    Search exists only to satisfy the capability host's vectorStoreConnections
    requirement. 'standard' frequently reports InsufficientResourcesAvailable in
    busy regions.
  EOT
  type        = string
  default     = "basic"
}

variable "search_location" {
  description = <<-EOT
    Region for Azure AI Search. Defaults to var.location.

    Override when the primary region reports InsufficientResourcesAvailable.
    Search capacity is constrained independently of everything else.
  EOT
  type        = string
  default     = null
}

variable "capability_host_stagger_seconds" {
  description = <<-EOT
    Delay between successive project capability host creations.

    Every project's capability host provisions containers in the same Cosmos
    account and will create the shared 'enterprise_memory' database if absent,
    so concurrent creation races. Terraform cannot chain a for_each serially,
    so each project waits (sorted index * this value) seconds.

    Raise this first if a capability host fails to provision.
  EOT
  type        = number
  default     = 240
}

variable "log_retention_days" {
  description = "Log Analytics retention."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Evidence gathering
# ---------------------------------------------------------------------------

variable "modern_containers_exist" {
  description = <<-EOT
    Whether every project has already had an agent invoked at least once.

    Azure Cosmos DB rejects a role assignment scoped to a container that does
    not exist:

      "The collection with name [<project-id>-agent-definitions-v1] in provided
       scope [...] could not be found."

    The modern runtime's <project-id>-agent-definitions-v1 and
    <project-id>-run-state-v1 containers are created lazily, on a project's
    FIRST Responses API invocation - not by the capability host. So on a clean
    deployment they cannot yet be targeted.

    This produces a genuine ordering constraint, and is very likely why the
    reference guidance grants at database scope: database scope is the only
    scope that covers containers which do not exist yet.

    Deployment therefore has two phases:

      1. Apply with isolation_mode = "documented" and this set to false.
      2. Run scripts/02-run-agents.ps1, which invokes an agent in every project
         and so creates the remaining containers.
      3. Apply with this set to true, and isolation_mode = "hardened" if you
        want the least-privilege end state. The orchestrator persists this
        value in the ignored modern-containers.auto.tfvars.json marker so
        later plain plans cannot remove the modern grants.

    When false, container-scoped grants cover only the three containers the
    capability host creates.
  EOT
  type        = bool
  default     = false
}

variable "enable_probe_identities" {
  description = <<-EOT
    Create the probe service principals used to produce the allow/deny matrix.

    A project's system-assigned managed identity cannot be impersonated, so we
    cannot obtain a token as it. Instead each probe SP receives a clone of a
    specific permission shape, which makes the authorization model directly
    testable.

    Requires permission to create Entra app registrations. Set to false to
    deploy the environment without the enforcement test.
  EOT
  type        = bool
  default     = true
}

variable "grant_deployer_data_access" {
  description = <<-EOT
    Grant the Terraform caller broad Cosmos and Storage data-plane read access.

    This is the control arm of the experiment: it proves the containers exist and
    hold distinct per-project data, so that a DENY elsewhere in the matrix is a
    real denial rather than an empty container.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Tagging and lifecycle
# ---------------------------------------------------------------------------

variable "lifetime_days" {
  description = "Days from apply until the environment should be torn down. Drives the autodelete tag."
  type        = number
  default     = 7
}

variable "owner" {
  description = "Value for the owner tag."
  type        = string
  default     = "platform-team"
}

variable "apply_control_bypass_tags" {
  description = <<-EOT
    Apply SecurityControl=ignore and CostControl=ignore to every resource.

    Required in tenants whose governance automation disables public network
    access on data resources after creation. Without these tags the Cosmos
    account is silently switched to publicNetworkAccess=Disabled and the
    Foundry runtime can no longer reach it, which surfaces as a 403 from the
    agent invocation rather than anything that looks like a networking problem.

    Set to false in tenants that do not run that automation.
  EOT
  type        = bool
  default     = true
}

variable "extra_tags" {
  description = "Additional tags merged over the defaults."
  type        = map(string)
  default     = {}
}
