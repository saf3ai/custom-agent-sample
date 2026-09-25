# Kubernetes: EKS · AKS · GKE

Kustomize base + one overlay per cloud. Uses `kubectl apply -k` (kubectl 1.27+, kustomize built in). Run every command from `deploy/kubernetes/`.

## What's here

| Path | Purpose |
|---|---|
| `base/` | Namespace `saf3ai-agent` · ServiceAccount · Deployment (2 replicas, non-root, read-only root FS) · Service (ClusterIP 80 → 8080) · NetworkPolicy · PodDisruptionBudget |
| `base/config.env` | Non-secret settings → ConfigMap `saf3ai-agent-config` |
| `base/secret.example.env` | Template for `base/secret.env` → Secret `saf3ai-agent-secrets` |
| `overlays/eks` | ECR image · Bedrock · IRSA role annotation (Pod Identity option) |
| `overlays/aks` | ACR image · Azure OpenAI · Azure Workload Identity |
| `overlays/gke` | Artifact Registry image · Vertex AI · GKE Workload Identity · metadata-server egress |

## 1. Common setup

```bash
cp base/secret.example.env base/secret.env    # set SAF3AI_API_KEY (+ your LLM key if the provider needs one)
```

- `secret.env` is gitignored. Never commit it.
- Fill every `<PLACEHOLDER>` in `overlays/<cloud>/kustomization.yaml`.
- Smoke test first without an LLM: delete the `LLM_*` lines in the overlay. The agent falls back to `LLM_PROVIDER=mock`.
- Build for your node CPU: `--platform linux/amd64` (or `linux/arm64` for Arm node pools).

## 2. EKS (Bedrock, no LLM key)

Prereqs: the cluster's OIDC provider. Network policy enabled in the VPC CNI (only if you want the NetworkPolicy enforced).

1. Build and push to ECR
   ```bash
   aws ecr create-repository --repository-name saf3ai-sample-agent --region <AWS_REGION>
   aws ecr get-login-password --region <AWS_REGION> | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com
   docker build --platform linux/amd64 -t <ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/saf3ai-sample-agent:1.0.0 ../../agent
   docker push <ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/saf3ai-sample-agent:1.0.0
   ```
2. Create the IAM role for the ServiceAccount (IRSA). Its policy allows `bedrock:InvokeModel` on your model or inference profile.
   ```bash
   eksctl utils associate-iam-oidc-provider --cluster <CLUSTER> --approve
   eksctl create iamserviceaccount --cluster <CLUSTER> --namespace saf3ai-agent --name saf3ai-agent \
     --role-name saf3ai-agent-bedrock --attach-policy-arn <BEDROCK_INVOKE_POLICY_ARN> --role-only --approve
   ```
   - **EKS Pod Identity instead:** run `aws eks create-pod-identity-association --cluster-name <CLUSTER> --namespace saf3ai-agent --service-account saf3ai-agent --role-arn <ROLE_ARN>`. Then delete the IRSA patch and uncomment `networkpolicy-pod-identity.yaml` in the overlay.
3. Deploy: `kubectl apply -k overlays/eks`

## 3. AKS (Azure OpenAI)

Prereqs: the cluster was created or updated with `--enable-oidc-issuer --enable-workload-identity`.

1. Build in ACR (no local Docker needed) and let the cluster pull from it
   ```bash
   az acr build --registry <ACR_NAME> --image saf3ai-sample-agent:1.0.0 ../../agent
   az aks update -g <RESOURCE_GROUP> -n <CLUSTER> --attach-acr <ACR_NAME>
   ```
2. Create the managed identity and federate it with the ServiceAccount
   ```bash
   az identity create -g <RESOURCE_GROUP> -n saf3ai-agent-id --query clientId -o tsv   # -> <MANAGED_IDENTITY_CLIENT_ID>
   az identity federated-credential create -g <RESOURCE_GROUP> --identity-name saf3ai-agent-id --name saf3ai-agent \
     --issuer "$(az aks show -g <RESOURCE_GROUP> -n <CLUSTER> --query oidcIssuerProfile.issuerUrl -o tsv)" \
     --subject system:serviceaccount:saf3ai-agent:saf3ai-agent --audience api://AzureADTokenExchange
   ```
   - The sample's `azure-openai` provider uses `AZURE_OPENAI_API_KEY`, so add it to `base/secret.env`.
   - The identity is there so the pod can read Azure resources, e.g. Key Vault through the Secrets Store CSI driver. Grant it only the roles it needs.
3. Deploy: `kubectl apply -k overlays/aks`

## 4. GKE (Vertex AI, no LLM key)

Prereqs: Workload Identity enabled on the cluster and node pool (on by default in Autopilot).

1. Build and push to Artifact Registry
   ```bash
   gcloud artifacts repositories create <REPOSITORY> --repository-format docker --location <REGION>
   gcloud auth configure-docker <REGION>-docker.pkg.dev
   docker build --platform linux/amd64 -t <REGION>-docker.pkg.dev/<PROJECT_ID>/<REPOSITORY>/saf3ai-sample-agent:1.0.0 ../../agent
   docker push <REGION>-docker.pkg.dev/<PROJECT_ID>/<REPOSITORY>/saf3ai-sample-agent:1.0.0
   ```
2. Create a Google service account with Vertex access and bind it to the ServiceAccount
   ```bash
   gcloud iam service-accounts create saf3ai-agent --project <PROJECT_ID>
   gcloud projects add-iam-policy-binding <PROJECT_ID> --role roles/aiplatform.user \
     --member "serviceAccount:saf3ai-agent@<PROJECT_ID>.iam.gserviceaccount.com"
   gcloud iam service-accounts add-iam-policy-binding saf3ai-agent@<PROJECT_ID>.iam.gserviceaccount.com \
     --role roles/iam.workloadIdentityUser --member "serviceAccount:<PROJECT_ID>.svc.id.goog[saf3ai-agent/saf3ai-agent]"
   ```
3. Deploy: `kubectl apply -k overlays/gke`

## 5. Test

```bash
kubectl -n saf3ai-agent rollout status deploy/saf3ai-agent
kubectl -n saf3ai-agent logs deploy/saf3ai-agent | grep "Saf3AI ready"
kubectl -n saf3ai-agent port-forward svc/saf3ai-agent 8080:80        # second terminal
curl -s localhost:8080/chat -H "Content-Type: application/json" -d '{"message":"Where is my order?"}'
```

| Result | Meaning |
|---|---|
| `200 {"reply", "conversation_id"}` | Allowed. Trace visible in the Saf3AI console under your `SAF3AI_AGENT_ID` |
| `403 {"blocked": true, "stage", "reasons"}` | Your Saf3AI policy blocked the prompt (`SAF3AI_ENFORCEMENT=block`) |

## 6. Operate

- **Scaling:** each process runs one agent turn at a time. Scale with replicas (`kubectl -n saf3ai-agent scale deploy/saf3ai-agent --replicas 4` or an HPA). For more processes per pod, raise `WEB_CONCURRENCY` and the memory limit.
- **Config changes:** edit `config.env` / `secret.env` / overlay and re-apply. The generated name hash rolls the pods.
- **Read-only root FS:** `/tmp` is writable. If logs show `Read-only file system` for another path, add an `emptyDir` there.
- **Egress:** HTTPS 443 to `analyzer.saf3ai.com`, `scanner.saf3ai.com` and your LLM API, plus DNS. See the FQDN note in `base/networkpolicy.yaml`.
- **Network hop:** Saf3AI scanning adds a network hop per turn. Benchmark in your environment.

## 7. Expose (optional)

- Add an Ingress (ALB, Application Gateway, GKE Ingress, NGINX…) pointing at Service `saf3ai-agent`, port `80`.
- Allow the ingress controller's namespace in `base/networkpolicy.yaml` (commented example there).
- `/chat` has no authentication of its own. Put auth in front (OIDC at the ingress, an API gateway, or mTLS).

## 8. Teardown

```bash
kubectl delete -k overlays/<cloud>        # deletes the namespace and everything in it
```

| Cloud | Remove the identity |
|---|---|
| EKS | `eksctl delete iamserviceaccount --cluster <CLUSTER> --namespace saf3ai-agent --name saf3ai-agent` |
| AKS | `az identity delete -g <RESOURCE_GROUP> -n saf3ai-agent-id` |
| GKE | `gcloud iam service-accounts delete saf3ai-agent@<PROJECT_ID>.iam.gserviceaccount.com` |

Delete the image repository if you no longer need it.
