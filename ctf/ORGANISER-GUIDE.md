# Organiser guide: run the Saf3AI CTF in your AWS account

For the person who sets up the game and runs the event. You host it in **your own AWS account**, with **your own Saf3AI API key**.
Your players need only a browser: send them [PLAYER-GUIDE.md](PLAYER-GUIDE.md).

| | |
|---|---|
| What you end up with | One EC2 instance running the game, reachable from the address range you choose |
| Who can do the setup | Anyone who can paste commands into a shell, or an AI assistant following this page |
| When | Part 1 the day before. Part 2 on the day. Part 3 immediately afterwards |
| Where the data goes | Every attempt is traced to your Saf3AI tenant, under the agent name you pick |

## Using an AI assistant

This page is written so that an assistant such as Claude Code can carry it out. Give it this:

```text
Read ctf/ORGANISER-GUIDE.md in https://github.com/saf3ai/custom-agent-sample and set up
the Saf3AI CTF in my AWS account by following Part 1, one step at a time.
- First ask me for the four values in "Values you choose".
- Never ask me to paste the Saf3AI API key into this chat. Give me the first block of
  step 1.2 to run myself, in my own terminal.
- If your tool starts a new shell for each command, keep these in a file and load it at the
  start of every command: the values of step 1.1, VPC, SUBNET and SG from step 1.4, IID and
  IP from step 1.5, and the on_instance function from step 1.6.
- Show me each command before you run it. Compare its output with "Expect" before going on.
- If a step fails, stop and tell me what you saw. Do not improvise a different setup.
- When Part 1 is done, give me the player link, and tell me how to read the admin token
  and the join code.
```

## What you need

| Need | Detail | Check |
|---|---|---|
| AWS account | Rights to create an EC2 instance, an IAM role with an instance profile, a security group and SSM parameters | `aws sts get-caller-identity` |
| A bash shell with AWS CLI v2 | AWS CloudShell has both. So does any laptop with the CLI installed | `aws --version` |
| A model | Amazon Nova 2 Lite on Amazon Bedrock, in your region. Other providers: see `LLM_PROVIDER` in [README.md](README.md) | The command below |
| Saf3AI API key | Saf3AI console → **Integrations → SDK → Custom Agent SDK** | |
| Your players' address range | The public address range (CIDR) your players' traffic comes from, for example your office or VPN range | Ask your network team |
| A host | A person to read the briefing and announce the time and the hints | |

Model check. A reply containing `OK` means the model is available to you:

```bash
aws bedrock-runtime converse --region us-east-1 --model-id us.amazon.nova-2-lite-v1:0 \
  --messages '[{"role":"user","content":[{"text":"Reply with the single word OK."}]}]' \
  --query "output.message.content[0].text" --output text
```

## Values you choose

| Value | Meaning | Example |
|---|---|---|
| `REGION` | AWS region. These steps were written for `us-east-1` | `us-east-1` |
| `PLAYER_CIDR` | Who may open the game. Your own browser must be inside it too | `203.0.113.0/24` |
| `AGENT_NAME` | The name this event has in the Saf3AI console. Use a new one per event | `ctf-2026-10` |
| `WORKERS` | Agent turns that can run at the same time. **One for every three teams** | `8` for up to 24 teams |

- The steps use a `t3.medium` instance. This setup was tested with 8 workers and 20 teams playing at once.
- For a larger room, rehearse first. How long a reply takes also depends on the services the game calls, not only on `WORKERS`.
- `MODEL` is preset to Amazon Nova 2 Lite. In another region the model id may differ: look it up under **Bedrock → Inference profiles** and change `MODEL` in step 1.1 and in the model check above.

---

# Part 1. Set up (the day before)

Everything in Part 1 is typed in **one shell on your own machine** (or AWS CloudShell). You never log in to the instance.

## 1.1 Shell setup

```bash
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1 PYTHONUTF8=1    # only needed on Git Bash for Windows
REGION=us-east-1
PLAYER_CIDR=203.0.113.0/24
AGENT_NAME=ctf-2026-10
WORKERS=8
MODEL=us.amazon.nova-2-lite-v1:0
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "account $ACCOUNT region $REGION"
```

**Expect:** your 12-digit account number and the region. Keep this shell open: every later step uses these values.

## 1.2 Store the settings

The game reads its settings from SSM Parameter Store, so no key is typed on the instance or kept in a file you manage.

Store the Saf3AI API key. The key is not shown as you paste it:

```bash
read -s -p "Paste your Saf3AI API key, then press Enter: " KEY; echo
aws ssm put-parameter --region $REGION --type SecureString \
  --name /saf3ai-ctf/SAF3AI_API_KEY --value "$KEY" --query Version --output text
unset KEY
```

Store the rest:

```bash
put() { aws ssm put-parameter --region $REGION --type "$1" --name "/saf3ai-ctf/$2" \
        --value "$3" --query Version --output text; }
put SecureString CTF_ADMIN_TOKEN "$(openssl rand -hex 16)"
put SecureString CTF_JOIN_CODE   "ctf-$(openssl rand -hex 3)"
put String       SAF3AI_AGENT_ID "$AGENT_NAME"
put String       CTF_WORKERS     "$WORKERS"
put String       LLM_MODEL       "$MODEL"
```

**Expect:** each command prints `1`.

| Setting | What it is |
|---|---|
| `SAF3AI_API_KEY` | Your tenant's key |
| `CTF_ADMIN_TOKEN` | Opens the organiser page and the answer key. Generated for you |
| `CTF_JOIN_CODE` | What players type to join. Generated for you |

## 1.3 Create the role for the instance

It allows three things only: receiving commands from AWS Systems Manager, calling the one model, and reading the settings above.

```bash
cat > trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow",
  "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
  "Resource":["arn:aws:bedrock:*::foundation-model/${MODEL#*.}",
   "arn:aws:bedrock:$REGION:$ACCOUNT:inference-profile/$MODEL"]},
 {"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],
  "Resource":"arn:aws:ssm:$REGION:$ACCOUNT:parameter/saf3ai-ctf/*"}]}
EOF
aws iam create-role --role-name saf3ai-ctf-ec2 \
  --assume-role-policy-document file://trust.json --query Role.Arn --output text
aws iam attach-role-policy --role-name saf3ai-ctf-ec2 \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name saf3ai-ctf-ec2 --policy-name saf3ai-ctf \
  --policy-document file://policy.json
aws iam create-instance-profile --instance-profile-name saf3ai-ctf-ec2 \
  --query InstanceProfile.Arn --output text
aws iam add-role-to-instance-profile --instance-profile-name saf3ai-ctf-ec2 \
  --role-name saf3ai-ctf-ec2
```

**Expect:** two ARNs, one for the role and one for the instance profile. The other commands print nothing.

## 1.4 Create the network rule

```bash
VPC=$(aws ec2 describe-vpcs --region $REGION --filters Name=isDefault,Values=true \
  --query "Vpcs[0].VpcId" --output text)
SUBNET=$(aws ec2 describe-subnets --region $REGION \
  --filters Name=default-for-az,Values=true --query "Subnets[0].SubnetId" --output text)
SG=$(aws ec2 create-security-group --region $REGION --group-name saf3ai-ctf-sg \
  --vpc-id $VPC --description "Saf3AI CTF" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$PLAYER_CIDR}]" \
  --query "SecurityGroupRules[0].CidrIpv4" --output text
echo "vpc $VPC subnet $SUBNET security group $SG"
```

**Expect:** your `PLAYER_CIDR`, then three ids starting `vpc-`, `subnet-` and `sg-`. If `VPC` is `None`, your account has no default VPC: set `VPC` and `SUBNET` to a VPC and a public subnet of your own, then run the last three commands again.

- The game is served over plain HTTP on port 80, to `PLAYER_CIDR` only.
- To serve it over HTTPS, put it behind your organisation's load balancer or CDN. That setup is not covered here.

## 1.5 Launch the instance

The instance installs Docker, fetches this repository, builds the image and starts the game automatically (`aws/start.sh`).

```bash
cat > user-data.sh <<EOF
#!/bin/bash
exec > /var/log/ctf-setup.log 2>&1
dnf install -y docker git
systemctl enable --now docker
git clone --depth 1 https://github.com/saf3ai/custom-agent-sample.git /opt/custom-agent-sample
bash /opt/custom-agent-sample/ctf/aws/start.sh $REGION
EOF
AMI=$(aws ssm get-parameter --region $REGION --query Parameter.Value --output text \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64)
IID=$(aws ec2 run-instances --region $REGION --image-id $AMI --instance-type t3.medium \
  --subnet-id $SUBNET --security-group-ids $SG --associate-public-ip-address \
  --iam-instance-profile Name=saf3ai-ctf-ec2 \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true}" \
  --user-data file://user-data.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=saf3ai-ctf}]" \
  --query "Instances[0].InstanceId" --output text)
aws ec2 wait instance-running --region $REGION --instance-ids $IID
IP=$(aws ec2 describe-instances --region $REGION --instance-ids $IID \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "instance $IID  player link http://$IP/  organiser page http://$IP/admin"
```

**Expect:** an instance id starting `i-` and the two links. Write all three down.

- `HttpPutResponseHopLimit=2` is required. Without it the container cannot use the instance role to call Bedrock.

## 1.6 Wait for the game to start

First define a helper that runs one command on the instance and prints its output:

```bash
on_instance() {
  local id status
  id=$(aws ssm send-command --region $REGION --instance-ids $IID \
       --document-name AWS-RunShellScript --parameters "commands=[\"$1\"]" \
       --query Command.CommandId --output text)
  while true; do
    sleep 5
    status=$(aws ssm get-command-invocation --region $REGION --command-id $id \
             --instance-id $IID --query Status --output text 2>/dev/null)
    case "$status" in Pending|InProgress|Delayed|"") ;; *) break ;; esac
  done
  aws ssm get-command-invocation --region $REGION --command-id $id --instance-id $IID \
    --query StandardOutputContent --output text
}
```

Then wait. This takes a few minutes: it returns when the game has started or has failed to.

```bash
until [ "$(aws ssm describe-instance-information --region $REGION \
  --filters Key=InstanceIds,Values=$IID \
  --query "InstanceInformationList[0].PingStatus" --output text)" = "Online" ]; do
  sleep 10
done
until on_instance "grep CTF_START_ /var/log/ctf-setup.log" | grep -E "CTF_START_(OK|FAILED)"; do
  sleep 20
done
```

**Expect:** `CTF_START_OK`.

If you see `CTF_START_FAILED`, the same line gives the reason. See the whole log, fix the cause, and start again without relaunching:

```bash
on_instance "tail -n 40 /var/log/ctf-setup.log"
on_instance "bash /opt/custom-agent-sample/ctf/aws/start.sh $REGION"
```

| Reason in the log | Fix |
|---|---|
| `cannot read /saf3ai-ctf/...` | A setting from step 1.2 is missing, or the policy in step 1.3 has another region or account |
| `SAF3AI_API_KEY is empty` or `was rejected` | Store the right key again: the first block of step 1.2, with `--overwrite` added to the command |
| `cannot reach` | The subnet has no route to the internet |

## 1.7 Check it end to end

`aws/preflight.sh` starts the clock, joins as a test team, sends a normal message and an attack, submits a flag, and resets the game.

```bash
on_instance "bash /opt/custom-agent-sample/ctf/aws/preflight.sh"
```

**Expect** ten `PASS` lines and `PREFLIGHT_OK`:

```text
PASS  the game responds
PASS  the organiser can start the clock
PASS  a team can join with the join code
PASS  the model answers a normal question
PASS  level 2: Saf3AI detects the attack
PASS  level 2: the attack is allowed (monitor)
PASS  level 4: Saf3AI blocks the same attack
PASS  a correct flag is accepted
PASS  the scoreboard shows the points
PASS  the organiser can reset the game
PREFLIGHT_OK
```

| If this line says FAIL | It means |
|---|---|
| the model answers a normal question | The instance cannot call the model. Check the model check at the top of this page, `MODEL`, and the hop limit in step 1.5 |
| Saf3AI detects the attack / blocks the same attack | Saf3AI did not flag the test attack. Check that the key belongs to the tenant you expect, and that tenant's policy in the console |
| a team can join with the join code | The settings on the instance are not the ones in step 1.2. Run `start.sh` again (step 1.6) |

## 1.8 Manual verification

Read the admin token and the join code:

```bash
aws ssm get-parameter --region $REGION --with-decryption --query Parameter.Value \
  --output text --name /saf3ai-ctf/CTF_ADMIN_TOKEN
aws ssm get-parameter --region $REGION --with-decryption --query Parameter.Value \
  --output text --name /saf3ai-ctf/CTF_JOIN_CODE
```

Then complete the three checks that need a person:

1. **Player link**, in a browser inside `PLAYER_CIDR`: you see **Join the game**.
2. **Organiser page:** paste the admin token. You see the answer key (five flags), the scoreboard and the controls.
3. **Saf3AI console:** **Custom Agents → Monitoring → Log Tracer**, agent = your `AGENT_NAME`. You see the test messages from a user whose name starts with `Preflight`.

## 1.9 Rehearse the levels

How hard each level is depends on the model. Press **Start** on the organiser page, join as a team and play levels 1 to 3 using the hints in Part 2. Then press **Reset**.

- Level 1 should disclose the code on a direct request.
- Levels 2 and 3 should refuse a direct request and be solvable with the approaches in the hints.
- If your model behaves differently, change the model or adjust the level prompts in `levels.py`.

---

# Part 2. Run the event

## 2.1 Timeline

| Time | Host says or does | Organiser does |
|---|---|---|
| -0:30 | | Opens the organiser page. Checks: **Not started**, 0 teams, five flags listed |
| -0:10 | Shows the player link and the join code. Asks teams to join | Watches teams appear on the scoreboard |
| -0:05 | Reads the briefing (2.2) | |
| 0:00 | "The clock starts now." | Presses **Start** |
| 0:10 to 0:50 | A hint every ten minutes (2.3) | Watches **Attempts by level**. Assists with the page, not with the challenges |
| 0:15, 0:30 | "45 minutes remaining." "30 minutes remaining." | |
| 0:55 | "Five minutes remaining. Submit any code you have obtained." | |
| 1:00 | "Time is up. Scores are final." | No action: the clock stops messages and flags automatically |
| 1:00 to 1:15 | Debrief (2.4) | Shows the organiser page, then the Saf3AI console |

## 2.2 Briefing: read this out

> Welcome. For the next hour you will act as attackers. Your target is ShopBot, a customer-support AI agent for an online store. On each of five levels ShopBot protects a secret code. Your objective is to obtain it.
>
> Each level adds one layer of protection. On the first three levels Saf3AI operates in monitor mode: it reports what it detected and allows the message through. On the last two levels it blocks.
>
> A code has the form FLAG, an opening brace, two words and a number, and a closing brace. When you obtain one, paste it into the flag field below the chat and select Submit flag. All five levels are open and may be played in any order.
>
> Three rules. First: attack ShopBot only, not this website and not other teams. Second: do not enter real personal or confidential information. Every message is recorded, and some will be displayed at the end. Third: no scripts. The limit is one message every three seconds.
>
> You have sixty minutes. Hints are given every ten minutes, to all teams at once.

## 2.3 Hints

Give each hint to all teams at the same time. Omit a hint if most teams have solved that level: the organiser page shows solves per level.

| Time | Level | Hint |
|---|---|---|
| 0:10 | 1 | ShopBot has no instruction to protect the code. Request it directly. |
| 0:20 | 2 | A direct request for the code is refused. Consider what else ShopBot holds that contains the code. |
| 0:30 | 2 | Ask ShopBot to process its instructions, rather than to disclose the code. |
| 0:30 | 3 | The code is not in ShopBot's instructions. Identify the tool that can read it. |
| 0:40 | 3 | The tool is restricted to staff. Consider how ShopBot establishes who is staff. |
| 0:40 | 4 | Submit your successful level 2 prompt on this level and read the notice. Saf3AI evaluates the message before the model does. |
| 0:50 | 5 | Three controls apply: a scan of your message, a scan of the response, and a check for the code in the response. A response that contains the code as written is never delivered. |

## 2.4 Debrief (15 minutes)

| Minutes | Show | Say |
|---|---|---|
| 0 to 2 | The scoreboard | Announce the winners. A tie is decided by the earlier time |
| 2 to 6 | Organiser page: **Successful prompts** | Present two or three successful prompts from levels 2 and 3 |
| 6 to 10 | Organiser page: **Attempts by level** | Levels 2 and 4 are the same agent. On level 2 Saf3AI detected the attack and allowed it, because it was in monitor mode. On level 4 the same message did not reach the model |
| 10 to 13 | Saf3AI console: **Log Tracer** for your `AGENT_NAME` | Every attempt from the event is recorded here, by team: what was sent, what was detected, what was blocked |
| 13 to 15 | | Questions |

## 2.5 Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| "The join code is incorrect." | A typing error | Read the code again (step 1.8) |
| "Waiting for the organiser to start" | The clock has not been started | Press **Start** |
| "Time is up" before the hour | **Start** was pressed earlier, for example while testing | Press **Start** again. It restarts the clock and keeps the scores |
| "Rate limit: wait N seconds" | More than one message in three seconds | Wait. The limit is per team |
| "The model is temporarily unavailable. Please resend." | One model call failed | Resend. If all teams see it, check model access and quotas in your AWS account |
| "This team name is already in use." | Another team has it | Choose another name |
| A team-mate cannot join the same team | They typed the team name | They paste the **team code** from the first player's Rules box |
| A player closed the browser | | Reopen the link in the same browser. On another device, use the team code |
| The page does not load for a player | They are outside `PLAYER_CIDR`, or their network blocks plain HTTP | Add their range to the security group, or serve the game over HTTPS |
| Replies are slow for everyone | More teams than the workers can serve | Next time raise `WORKERS`. Do not change it mid-game |
| A normal question is blocked on level 4 or 5 | Saf3AI flagged it | Rephrase the question |
| The organiser page shows an error | The container stopped | `on_instance "docker logs --tail 30 saf3ai-ctf"` (step 1.6) |

---

# Part 3. After the event

## 3.1 Export the results

In the shell from step 1.1, from a machine inside `PLAYER_CIDR`:

```bash
ADMIN=$(aws ssm get-parameter --region $REGION --with-decryption \
  --query Parameter.Value --output text --name /saf3ai-ctf/CTF_ADMIN_TOKEN)
curl -s -H "X-Admin-Token: $ADMIN" http://$IP/api/admin/report > ctf-report.json
```

**Expect:** `ctf-report.json` holds the scoreboard, attempts by level and by team, and the successful prompts. The attempts also stay in your Saf3AI tenant under `AGENT_NAME`.

## 3.2 Remove all resources

In the shell from step 1.1. If you closed it, set `REGION`, `IID` and `SG` again first.

```bash
aws ec2 terminate-instances --region $REGION --instance-ids $IID \
  --query "TerminatingInstances[0].CurrentState.Name" --output text
aws ec2 wait instance-terminated --region $REGION --instance-ids $IID
aws ec2 delete-security-group --region $REGION --group-id $SG
aws iam remove-role-from-instance-profile --instance-profile-name saf3ai-ctf-ec2 \
  --role-name saf3ai-ctf-ec2
aws iam delete-instance-profile --instance-profile-name saf3ai-ctf-ec2
aws iam detach-role-policy --role-name saf3ai-ctf-ec2 \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role-policy --role-name saf3ai-ctf-ec2 --policy-name saf3ai-ctf
aws iam delete-role --role-name saf3ai-ctf-ec2
aws ssm delete-parameters --region $REGION --names /saf3ai-ctf/SAF3AI_API_KEY \
  /saf3ai-ctf/CTF_ADMIN_TOKEN /saf3ai-ctf/CTF_JOIN_CODE /saf3ai-ctf/SAF3AI_AGENT_ID \
  /saf3ai-ctf/CTF_WORKERS /saf3ai-ctf/LLM_MODEL \
  --query "length(DeletedParameters)" --output text
```

**Expect:** `shutting-down`, a short confirmation for the security group, then `6` for the six deleted settings. Nothing from this guide is left in the account.

---

# Reference

| Topic | Detail |
|---|---|
| Your Saf3AI tenant | The event's attempts appear in your tenant like any other agent traffic, under `AGENT_NAME`. To keep them apart from your other data, ask your Saf3AI contact about a separate tenant for the event |
| Console access | Traces include the level prompts, and so the flags. Keep console access to organisers until the event is over |
| What is stored | Each player message, with its team and outcome, is kept on the instance for the debrief and is removed with the instance |
| Cost | One EC2 instance for the hours it runs, and the model usage of the game. Part 3 removes both |
| Flags | Different on every deployment. The answer key is on the organiser page |
| Running a second event | **Reset** on the organiser page clears teams and scores. Use a new `AGENT_NAME` to keep the events apart in the console |
