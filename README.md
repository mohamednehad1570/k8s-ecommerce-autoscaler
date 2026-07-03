# Auto-Scaling Kubernetes Cluster for E-Commerce

Predictive auto-scaling system for high-traffic e-commerce events (Black Friday,
Flash Sales) built on Google Kubernetes Engine (GKE).

## Architecture

- **ML Forecasting**: FastAPI + Prophet predicts traffic spikes from historical data
- **Predictive Scaling**: KEDA pre-emptively scales pods before demand lands
- **Reactive Baseline**: HPA scales pods in response to live CPU/memory metrics
- **Workload**: Google Online Boutique (11 microservices)
- **GitOps**: ArgoCD declarative delivery from this repository
- **Observability**: Prometheus + Grafana + Loki — all scaling evidence captured

## Stack

| Layer | Tool |
|---|---|
| Cloud | GCP / GKE Standard (europe-west1) |
| Autoscaling | KEDA (predictive) + HPA (reactive baseline) |
| ML Service | FastAPI + Prophet |
| GitOps | ArgoCD |
| CI | GitHub Actions → GHCR |
| Observability | kube-prometheus-stack + Loki |
| Load Testing | Locust |
| Security | Falco + Sealed Secrets + RBAC + Network Policies |

## Project Structure

\`\`\`
├── terraform/          # GKE infrastructure as code
├── kubernetes/         # K8s manifests (managed by ArgoCD)
│   ├── base/           # Base manifests
│   └── overlays/prod/  # Production patches
├── ml-service/         # FastAPI + Prophet prediction service
├── .github/workflows/  # CI pipeline definitions
└── scripts/            # Helper scripts
\`\`\`
