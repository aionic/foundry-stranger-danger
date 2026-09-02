# Prevent a normal plan from silently removing the four modern project grants
# and four modern probe grants after the two-phase hardening workflow.
#
# deploy-and-harden.ps1 writes modern-containers.auto.tfvars.json after it has
# proved every modern container exists. Phase 1 explicitly overrides this value
# to false; the steady-state hardened configuration must keep it true.
resource "terraform_data" "hardened_state_guard" {
  input = {
    isolation_mode          = var.isolation_mode
    modern_containers_exist = var.modern_containers_exist
  }

  lifecycle {
    precondition {
      condition     = var.isolation_mode != "hardened" || var.modern_containers_exist
      error_message = "Hardened mode requires modern_containers_exist=true. Use scripts/deploy-and-harden.ps1; do not apply a plan that would remove modern container grants."
    }
  }
}