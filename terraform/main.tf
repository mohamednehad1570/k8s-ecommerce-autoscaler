# ── GKE Cluster: Auto-Scaling Kubernetes for E-Commerce ───────────────────────
# Regional cluster across 3 zones in europe-west1.
# Three node pools with distinct purposes:
#   default-pool  — system workloads (monitoring, ArgoCD, KEDA, ingress)
#   workload-pool — application workloads (Online Boutique, ML service)
#   burst-pool    — Spot VMs for autoscaling events (HPA/KEDA scale-out)

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region   # region (not zone) = regional cluster = 3-zone HA

  # ── Control plane configuration ─────────────────────────────────────────────
  # `release_channel` — STABLE: GKE manages K8s version upgrades automatically
  #                     on the stable channel (tested, no breaking API changes)
  release_channel {
    channel = var.gke_version
  }

  # ── Remove the default node pool immediately after cluster creation ──────────
  # We define all pools explicitly below for full control over configuration.
  # `remove_default_node_pool = true` + `initial_node_count = 1` is the standard
  # Terraform pattern: create cluster (requires >=1 node), then delete default pool.
  remove_default_node_pool = true
  initial_node_count       = 1

  # ── Networking ───────────────────────────────────────────────────────────────
  # Default VPC networking — sufficient for this project.
  # Network policies are applied at the pod level in Phase 6 (security hardening).
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {}

  # ── Deletion protection ──────────────────────────────────────────────────────
  # Prevents accidental `terraform destroy` from wiping the cluster.
  # Must be set to false before intentional destruction.
  deletion_protection = false
}

# ── Node Pool 1: default-pool (system workloads) ──────────────────────────────
# Hosts: Prometheus, Grafana, Alertmanager, Loki, ArgoCD, KEDA operator,
#        NGINX Ingress controller, cert-manager, Sealed Secrets controller.
# Fixed size: system components must always be running — no autoscaling here.
# 1 node/zone × 3 zones = 3 nodes total, 12 vCPU, 48 GB RAM steady-state.
resource "google_container_node_pool" "default_pool" {
  name       = "default-pool"
  cluster    = google_container_cluster.primary.name
  location   = var.region
  node_count = 1   # per zone — regional cluster multiplies by 3

  # ── Node management ──────────────────────────────────────────────────────────
  management {
    auto_repair  = true    # GKE auto-replaces unhealthy nodes — required for HA
    auto_upgrade = false   # We control upgrade timing — no surprise restarts
  }

  node_config {
    machine_type = var.system_pool_machine_type   # e2-standard-4: 4 vCPU / 16 GB
    disk_type    = "pd-ssd"                        # SSD boot disk — no HDD latency
    disk_size_gb = 50

    # ── OAuth scopes ─────────────────────────────────────────────────────────
    # `cloud-platform` grants nodes access to all GCP APIs they need
    # (logging, monitoring, artifact registry for image pulls)
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # ── Node labels ───────────────────────────────────────────────────────────
    # Used by pod nodeSelector/nodeAffinity rules to schedule system workloads
    # specifically onto this pool (configured in Phase 3-5 manifests)
    labels = {
      pool = "system"
      env  = "production"
    }

    metadata = {
      disable-legacy-endpoints = "true"   # Security best practice: block legacy metadata API
    }
  }
}

# ── Node Pool 2: workload-pool (application workloads) ────────────────────────
# Hosts: Google Online Boutique (11 microservices), FastAPI+Prophet ML service.
# Fixed size: application baseline must be stable during HPA vs KEDA comparison.
# 2 nodes/zone × 3 zones = 6 nodes total, 24 vCPU, 96 GB RAM steady-state.
resource "google_container_node_pool" "workload_pool" {
  name       = "workload-pool"
  cluster    = google_container_cluster.primary.name
  location   = var.region
  node_count = 2   # per zone — 2 nodes/zone gives inter-node pod distribution

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    machine_type = var.workload_pool_machine_type   # e2-standard-4: 4 vCPU / 16 GB
    disk_type    = "pd-ssd"
    disk_size_gb = 50
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool = "workload"
      env  = "production"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}

# ── Node Pool 3: burst-pool (Spot VMs for autoscaling events) ─────────────────
# Hosts: overflow pods during HPA and KEDA scale-out events (Locust load tests).
# Starts at 0 nodes ($0/hour when idle). Cluster Autoscaler provisions on demand.
# Both HPA and KEDA draw from this pool — Grafana shows pure timing difference.
# Max 3 nodes/zone × 3 zones = 9 Spot nodes at peak burst.
resource "google_container_node_pool" "burst_pool" {
  name     = "burst-pool"
  cluster  = google_container_cluster.primary.name
  location = var.region

  # ── Cluster Autoscaler ────────────────────────────────────────────────────
  # `min_node_count = 0` — scales to zero when idle: $0/hour between tests
  # `max_node_count = 3` — 3/zone × 3 zones = 9 Spot nodes maximum at peak
  autoscaling {
    min_node_count = 0
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    machine_type = var.burst_pool_machine_type   # e2-standard-2: 2 vCPU / 8 GB
    disk_type    = "pd-ssd"
    disk_size_gb = 50

    # ── Spot VM configuration ─────────────────────────────────────────────────
    # `spot = true` — enables Spot pricing: 60-80% cheaper than on-demand
    # Acceptable here: burst pods are stateless and short-lived.
    # If GCP reclaims a Spot node mid-test, Cluster Autoscaler provisions another.
    spot = true

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool = "burst"
      env  = "production"
    }

    # ── Spot node taint ───────────────────────────────────────────────────────
    # Prevents non-burst workloads from accidentally scheduling on Spot nodes.
    # Only pods with a matching toleration will land here.
    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}
