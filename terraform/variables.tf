# ── Input variables for the GKE cluster configuration ─────────────────────────
# Variables make the Terraform code reusable and keep secrets out of source code.
# Values are supplied at runtime via terraform.tfvars (gitignored) or CLI flags.

variable "project_id" {
  description = "GCP project ID where all resources will be created"
  type        = string
  # No default — must be explicitly supplied. Prevents accidental deploys to wrong project.
}

variable "region" {
  description = "GCP region for the GKE cluster. europe-west1 = Belgium (lowest EU latency)"
  type        = string
  default     = "europe-west1"
}

variable "cluster_name" {
  description = "Name of the GKE cluster — must match gke-stop/gke-start aliases"
  type        = string
  default     = "k8s-ecommerce-autoscaler"
}

variable "gke_version" {
  description = "GKE release channel — stable ensures tested, production-grade K8s versions"
  type        = string
  default     = "STABLE"
}

variable "system_pool_machine_type" {
  description = "Machine type for system-pool: runs monitoring, ArgoCD, KEDA, ingress"
  type        = string
  default     = "e2-standard-4"
}

variable "workload_pool_machine_type" {
  description = "Machine type for workload-pool: runs Online Boutique + ML service"
  type        = string
  default     = "e2-standard-4"
}

variable "burst_pool_machine_type" {
  description = "Machine type for burst-pool: Spot VMs for HPA/KEDA scale-out events"
  type        = string
  default     = "e2-standard-2"
}
