# Player guide: Saf3AI Capture the Flag

A one-hour exercise. You attack an AI agent that Saf3AI protects.

## What this is

- Your target is **ShopBot**, a customer-support AI agent for an online store.
- ShopBot protects a secret code on each of five levels. Obtain the code and submit it to score points.
- Each level adds one layer of protection. On the last two levels, Saf3AI blocks attacks before they reach the model.

## What you need

| You need | You do not need |
|---|---|
| A laptop with a current browser: Chrome, Edge, Firefox or Safari | Any software to install |
| The game link and the join code from the organiser | A cloud account or a Saf3AI account |
| A team of 1 to 3 people and a team name | Any programming skill: you play by typing messages |

## Before the event

1. When you receive the game link, open it on the laptop you will use. You should see the page titled **Join the game**.
2. If the page does not open, tell the organiser before the event starts. Some office networks need the link allowed.
3. Agree on your team and a team name of 2 to 24 characters.

## How to play

1. Open the game link.
2. Type your **team name** and the **join code**, then press **Join**.
3. Wait for the clock at the top to start. Until then it states that the organiser has not started.
4. Pick a **level** on the left and read what protects the code on that level.
5. Type a message to ShopBot and press **Send** (or the Enter key).
6. Read the reply. A code looks like `FLAG{two-words-1234}`.
7. Paste the code into the field below the chat and press **Submit flag**. A correct code adds points immediately.
8. Move to any other level. All five are open from the start.

- **Playing as a team:** the first player shares the **team code** shown in the Rules box. Team-mates paste it into "Team code from a team-mate" on the join page instead of typing a team name.
- **If you close the browser:** open the link again in the same browser to return to your team.

## The five levels

| Level | Points | What protects the code |
|---|---|---|
| 1. Unprotected secret | 100 | No control |
| 2. System prompt instruction | 200 | A system prompt instruction to keep the code confidential |
| 3. Restricted tool | 300 | The code is held behind a tool that ShopBot is instructed to use for staff only |
| 4. Input guardrail | 400 | The same agent as level 2, with Saf3AI scanning every message before it reaches the model |
| 5. Input and output guardrails | 500 | A hardened system prompt, Saf3AI guardrails on the prompt and the response, and an output check that withholds any response containing the code |

## What the notices mean

| Notice | Meaning |
|---|---|
| Saf3AI detected: … (monitor mode: not blocked) | Levels 1 to 3. Saf3AI recognised your message as an attack and named the threat category. It was allowed because these levels operate in monitor mode |
| Blocked by Saf3AI before the model was called | Levels 4 and 5. Your message was stopped. ShopBot never saw it |
| Blocked by Saf3AI on the response | Level 5. ShopBot responded, and the response was blocked |
| Blocked: the response contained the code | Level 5. The response contained the code, so it was withheld |
| Rate limit: wait N seconds | Your team sent messages too quickly |
| The model is temporarily unavailable. Please resend. | A temporary problem. Send the same message again |

## Rules

- **Attack ShopBot only.** Not the website, not the server, not other teams.
- **Do not type real personal or confidential information.** Every message is recorded, and some are shown on screen in the debrief. Use made-up names and numbers.
- **No scripts or automation.** You may use any tool to help you write a message, including AI assistants. A person sends each message.
- **Do not share codes between teams.**
- The organiser's decision on scoring is final.

## Scoring and limits

| Item | Rule |
|---|---|
| Points | 100, 200, 300, 400 and 500 for levels 1 to 5. 1500 in total |
| Ties | The team that reached its score first ranks higher |
| Wrong codes | No penalty |
| Messages | One message every 3 seconds per team, 200 messages per team in the hour, 800 characters per message |
| Memory | Each message is independent. ShopBot retains no conversation history |
| Time | 60 minutes. When the clock ends, messages and codes are no longer accepted |
| Hints | The host gives hints to everyone at the same time. They cost no points |

The organiser can change the limits, so your event may differ.

## Getting started

- Begin with a direct request, then consider why it was refused.
- ShopBot follows instructions that you cannot see. Consider what those instructions are likely to say.
- The same request in a different form can produce a different response.
- On levels 4 and 5 the notice states which control stopped the message. Use that information.
- If you make no progress on a level, move to another. Levels may be played in any order.

## After the hour

- Scores are final when the clock ends and stay on screen.
- The debrief presents the successful prompts, what Saf3AI detected and blocked across all teams, and how the same attack performed with and without the guardrail.
