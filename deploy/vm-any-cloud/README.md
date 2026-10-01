# Linux VM on any cloud (Docker + systemd)

Runs the agent container as systemd service `saf3ai-agent` on port 8080. Works on EC2, Azure VM, GCE, or on-prem.

## What's here

| File | Use for |
|---|---|
| `cloud-init.yaml` | A **new** VM (Ubuntu 22.04 / 24.04). Paste it at create time |
| `install.sh` | An **existing** VM (Ubuntu / Debian / Amazon Linux). Idempotent, never overwrites `agent.env` |

Both set up:
- Docker
- `/etc/saf3ai-agent/agent.env` (root, 0600) → container environment
- `saf3ai-agent.service` → `docker run --env-file … -p 8080:8080`, with a read-only root FS and all capabilities dropped
- Restarts handled by systemd (`Restart=always`), not by Docker

## Option A: new VM (cloud-init)

1. Edit `cloud-init.yaml`: set `IMAGE`, fill `agent.env` (or use the secret store, below), and uncomment your registry login.
2. Paste it:

   | Cloud | Console | CLI |
   |---|---|---|
   | AWS EC2 | Launch instance → Advanced details → **User data** | `aws ec2 run-instances … --user-data file://cloud-init.yaml` |
   | Azure VM | Create VM → Advanced → **Custom data** | `az vm create … --custom-data cloud-init.yaml` |
   | Google GCE | Metadata key **`user-data`**. Use an Ubuntu image: Debian images don't run cloud-init | `gcloud compute instances create … --metadata-from-file user-data=cloud-init.yaml` |
   | On-prem | NoCloud seed, or use `install.sh` | — |

3. Check progress: `sudo cloud-init status --wait && systemctl status saf3ai-agent`

User data can be read from inside the VM and by cloud users with describe rights. Keep real keys out of it and use the secret store.

## Option B: existing VM (install.sh)

```bash
sudo IMAGE=<REGISTRY>/saf3ai-sample-agent:1.0.0 bash install.sh   # an image you pushed
sudo AGENT_SRC=../../agent bash install.sh                         # or build on the VM from the kit
sudo nano /etc/saf3ai-agent/agent.env && sudo systemctl restart saf3ai-agent
```

## Private registry login (run as root, then pull once)

| Registry | Command |
|---|---|
| ECR | `aws ecr get-login-password --region <AWS_REGION> \| sudo docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com` |
| ACR | `sudo az login --identity && sudo az acr login --name <ACR_NAME>` |
| Artifact Registry | `sudo gcloud auth configure-docker <REGION>-docker.pkg.dev` |

Then run `sudo docker pull <IMAGE>`. The service pulls on every start, but if a pull fails (e.g. the ECR login expired after 12 h) it runs the cached image.

## LLM via the VM's cloud identity (no key)

| LLM | Setup |
|---|---|
| Bedrock on EC2 | Instance profile with `bedrock:InvokeModel`. Let the container reach IMDSv2: `aws ec2 modify-instance-metadata-options --instance-id <INSTANCE_ID> --http-put-response-hop-limit 2 --http-endpoint enabled` |
| Vertex AI on GCE | VM service account with `roles/aiplatform.user` and the `cloud-platform` scope. Set `GOOGLE_CLOUD_PROJECT` in `agent.env` |

## Secrets from your cloud's secret store (instead of a file)

1. Store the whole `agent.env` as one secret.
2. In the unit, uncomment the `ExecStartPre=… <FETCH_COMMAND> …` line and paste the fetch command. `agent.env` is then refreshed on every start. If a fetch fails, the last good file is kept.

| Cloud | Store once | `<FETCH_COMMAND>` | VM identity needs |
|---|---|---|---|
| AWS | `aws secretsmanager create-secret --name saf3ai-agent-env --secret-string file://agent.env` | `aws secretsmanager get-secret-value --secret-id saf3ai-agent-env --query SecretString --output text` | `secretsmanager:GetSecretValue` |
| Azure | `az keyvault secret set --vault-name <VAULT> --name saf3ai-agent-env --file agent.env` | `az login --identity >/dev/null && az keyvault secret show --vault-name <VAULT> --name saf3ai-agent-env --query value -o tsv` | Key Vault Secrets User |
| GCP | `gcloud secrets create saf3ai-agent-env --data-file=agent.env` | `gcloud secrets versions access latest --secret=saf3ai-agent-env` | `roles/secretmanager.secretAccessor` |

- The CLI must be installed on the VM. systemd's `PATH` has no `/snap/bin`, so use the CLI's full path if it lives there.
- After editing the unit: `sudo systemctl daemon-reload && sudo systemctl restart saf3ai-agent`

## Firewall

| Cloud | Allow 8080 only from your load balancer / admin CIDR |
|---|---|
| AWS | `aws ec2 authorize-security-group-ingress --group-id <SG_ID> --protocol tcp --port 8080 --cidr <ALLOWED_CIDR>` |
| Azure | `az network nsg rule create -g <RESOURCE_GROUP> --nsg-name <NSG> -n allow-saf3ai-agent --priority 1000 --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 8080 --source-address-prefixes <ALLOWED_CIDR>` |
| GCP | `gcloud compute firewall-rules create allow-saf3ai-agent --network <VPC> --allow tcp:8080 --source-ranges <ALLOWED_CIDR> --target-tags saf3ai-agent` |

- **Egress:** HTTPS 443 to `analyzer.saf3ai.com`, `scanner.saf3ai.com`, your LLM API and your registry, plus DNS.
- **Never open 8080 to `0.0.0.0/0`.** `/chat` has no authentication of its own. Put TLS and auth in front (load balancer, API gateway, or reverse proxy).

## Test

```bash
journalctl -u saf3ai-agent -f            # look for "Saf3AI ready"
curl -s localhost:8080/healthz
curl -s localhost:8080/chat -H "Content-Type: application/json" -d '{"message":"Where is my order?"}'
```

- `200 {"reply", "conversation_id"}` = allowed.
- `403 {"blocked": true, "stage", "reasons"}` = blocked by your Saf3AI policy.

## Operate

- **Settings:** edit `agent.env`, then `sudo systemctl restart saf3ai-agent`.
- **New version:** re-run `install.sh` with the new `IMAGE`, or edit `IMAGE` in the unit and restart.
- **Concurrency:** one agent turn at a time per process. Set `WEB_CONCURRENCY` to about the vCPU count. For HA, run 2+ VMs behind a load balancer.
- **Network hop:** Saf3AI scanning adds a network hop per turn. Benchmark in your environment.

## Teardown

```bash
sudo systemctl disable --now saf3ai-agent
sudo rm -f /etc/systemd/system/saf3ai-agent.service && sudo systemctl daemon-reload
sudo rm -rf /etc/saf3ai-agent
sudo docker image rm <IMAGE>
```

Or delete the VM, then remove the firewall rule and the stored secret.
