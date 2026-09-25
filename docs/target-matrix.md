# Deployment targets

Every target runs the same container (`agent/Dockerfile`) and the same env vars. Pick by how you run services today.

- **Easiest:** `python deploy.py` asks which target, then runs that folder's steps for you. `--dry-run` shows the commands first.

| Target | Folder | Tooling | Secrets from | Model identity (no key) | Scale to zero |
|---|---|---|---|---|---|
| Local / any Docker host | root `docker-compose.yml` | Docker Compose | `.env` file | — | — |
| Any Linux VM (EC2, Azure VM, GCE, on-prem) | `deploy/vm-any-cloud` | cloud-init / `install.sh` | Env file (or fetched from the cloud secret store) | Instance role / managed identity / VM SA | No |
| AWS EC2 | `deploy/aws-ec2` | Terraform | Secrets Manager | Instance profile → Bedrock | No |
| AWS ECS Fargate | `deploy/aws-ecs-fargate` | Terraform | Secrets Manager | Task role → Bedrock | No (min 1 task) |
| AWS Lambda | `deploy/aws-lambda` | Terraform | Secrets Manager | Execution role → Bedrock | Yes |
| Azure Container Apps | `deploy/azure-container-apps` | Terraform | Key Vault | Managed identity | Yes (min replicas 0) |
| Azure App Service | `deploy/azure-app-service` | Terraform | Key Vault references | Managed identity | No |
| Google Cloud Run | `deploy/gcp-cloud-run` | gcloud script or Terraform | Secret Manager | Service account → Vertex | Yes |
| Vertex AI Agent Engine | `deploy/gcp-vertex-agent-engine` | Python deploy script (ADK variant) | Env vars at deploy | Service account → Vertex | Managed runtime — check current Agent Engine pricing |
| Kubernetes — EKS / AKS / GKE / any | `deploy/kubernetes` (+ `overlays/eks`, `aks`, `gke`) | kustomize (`kubectl apply -k`) | Kubernetes Secret | IRSA / Pod Identity · Azure Workload Identity · GKE Workload Identity | No |
| Hugging Face Spaces | `deploy/hugging-face-spaces` | git push to a Space | Space Secrets | — | Sleeps when idle (per Space settings) |

## All targets

| Need | Setting |
|---|---|
| Outbound | HTTPS 443 to `scanner.saf3ai.com`, `analyzer.saf3ai.com`, your LLM provider |
| Inbound | Service port only (8080, or the platform's `$PORT`) |
| Health check | `GET /healthz` |
| Scaling | Replicas or `WEB_CONCURRENCY` worker processes (one turn at a time per process) |
| Runs as | Non-root |

→ verify any target with the 3 requests in `verify-and-troubleshoot.md`.
