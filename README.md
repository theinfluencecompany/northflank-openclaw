# OpenClaw on Northflank

Deploy [OpenClaw](https://openclaw.ai) AI assistants on [Northflank](https://northflank.com) with one command.

## What you get

- OpenClaw instance with full browser automation (Playwright/Chromium)
- GPT-5.4 by default (configurable)
- No approval prompts — full exec permissions out of the box
- Web-accessible Control UI with token auth
- Each instance is isolated with its own gateway token

## Prerequisites

- A [Northflank](https://app.northflank.com) account with a team API key
- An [OpenAI](https://platform.openai.com) API key
- `curl`, `jq`, and `openssl` on your machine

## Quick start

```bash
git clone https://github.com/theinfluencecompany/northflank-openclaw.git
cd northflank-openclaw

export NF_API_TOKEN="your-northflank-team-api-key"
export OPENAI_API_KEY="sk-..."

./deploy.sh my-assistant
```

The script will:
1. Create a `openclaw` project on Northflank (if it doesn't exist)
2. Build the custom Docker image from this repo
3. Deploy it as a combined service
4. Print the URL and gateway token

## Deploy multiple instances

```bash
./deploy.sh tiktok-bot
./deploy.sh discord-bot
./deploy.sh research-agent
```

Each gets its own URL, gateway token, and isolated workspace.

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `NF_API_TOKEN` | (required) | Northflank team API key |
| `OPENAI_API_KEY` | (required) | OpenAI API key |
| `NF_REGION` | `us-west` | Northflank deployment region |
| `NF_PLAN` | `nf-compute-20` | Compute plan (`nf-compute-20`, `nf-compute-50`, etc.) |
| `OPENCLAW_MODEL` | `openai/gpt-5.4` | Default LLM model |
| `REPO_URL` | this repo | Git repo URL for the Dockerfile |

## Use a different LLM

```bash
# Anthropic Claude
export OPENAI_API_KEY="not-used"  # still required by script, can be dummy
OPENCLAW_MODEL="anthropic/claude-sonnet-4-6" ./deploy.sh my-agent

# Then set the real key in Northflank:
curl -X POST "https://api.northflank.com/v1/projects/openclaw/services/my-agent/runtime-environment" \
  -H "Authorization: Bearer $NF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"runtimeEnvironment":{"ANTHROPIC_API_KEY":"sk-ant-..."}}'
```

## Access the Control UI

Open in your browser:

```
https://<your-service-url>?token=<gateway-token>
```

Both the URL and token are printed by the deploy script.

## What the Dockerfile does

1. Installs Chromium system libraries (for Playwright browser automation)
2. Installs `sudo` (so the agent can install additional packages at runtime)
3. Configures the gateway:
   - Allow all CORS origins (for remote access)
   - Disable device auth (no pairing required)
   - Full exec permissions (no approval prompts)
4. Patches the nginx entrypoint to remove the browser sidecar proxy

## Discord with personal accounts (not bots)

OpenClaw's Discord integration normally requires bot tokens. This repo includes a patched Dockerfile (`Dockerfile.discord`) that removes the `Bot ` auth prefix so **personal Discord account tokens** work instead.

### Deploy a Discord instance

```bash
DOCKERFILE=Dockerfile.discord ./deploy.sh discord-agent
```

Or manually set the Dockerfile path to `/Dockerfile.discord` when creating the service on Northflank.

### Get your Discord user token

1. Open Discord in a web browser (not the desktop app)
2. Open DevTools (F12) → Network tab
3. Send any message or navigate to a channel
4. Find any request to `discord.com/api` → click it
5. In the Headers tab, copy the `Authorization` value (it will NOT start with `Bot`)

### Connect accounts via the Control UI

Open the OpenClaw Control UI and go to **Settings → Config**. Add your Discord accounts:

```json
{
  "channels": {
    "discord": {
      "accounts": {
        "main": {
          "token": "your-discord-user-token-here",
          "groupPolicy": "open",
          "dm": { "enabled": true, "policy": "open" }
        },
        "alt": {
          "token": "second-account-token",
          "groupPolicy": "open"
        }
      },
      "defaultAccount": "main"
    }
  }
}
```

Or tell the OpenClaw chat directly:

> Configure Discord with my personal account token. The token is stored in environment variable DISCORD_TOKEN_1. Use groupPolicy "open" and enable DMs.

### Multi-account capabilities

Each account gets:
- Independent guild/channel configuration
- Separate DM policies and allowlists
- Per-account tool policies and exec approval routing
- Individual streaming and message formatting settings

### Per-guild and per-channel config

```json
{
  "channels": {
    "discord": {
      "accounts": {
        "main": {
          "token": "...",
          "guilds": {
            "SERVER_ID": {
              "requireMention": false,
              "channels": {
                "CHANNEL_ID": {
                  "enabled": true,
                  "systemPrompt": "You are a helpful assistant in this channel."
                }
              }
            }
          }
        }
      }
    }
  }
}
```

### What the Discord patch does

OpenClaw and its `@buape/carbon` Discord library hardcode `Authorization: Bot ${token}` in 5 places. The `Dockerfile.discord` patches all of them to use `Authorization: ${token}` instead, which is the format personal tokens use.

Patched files:
- `/opt/openclaw/app/dist/channels/plugins/actions/discord.js` (2 occurrences)
- `/opt/openclaw/app/node_modules/@buape/carbon/dist/src/plugins/sharding/ShardingPlugin.js`
- `/opt/openclaw/app/node_modules/@buape/carbon/dist/src/plugins/gateway/GatewayPlugin.js`
- `/opt/openclaw/app/node_modules/@buape/carbon/dist/src/plugins/linked-roles/LinkedRoles.js`

### Residential proxy (required for cloud hosting)

Discord blocks selfbot connections from datacenter IPs. The `Dockerfile.discord` includes `proxychains4` to route all traffic through a residential SOCKS5 proxy.

**Setup:**

1. Get a residential SOCKS5 proxy (e.g., [IPRoyal](https://iproyal.com/residential-proxies/) — $1.75/GB, ~$0.10/month for 10k messages)

2. Set these env vars on your Northflank service:

```bash
PROXY_HOST=geo.iproyal.com
PROXY_PORT=12321
PROXY_USER=your_username
PROXY_PASS=your_password
DISCORD_BOT_TOKEN=your_discord_user_token
```

3. If `PROXY_HOST` is not set, the proxy is skipped and OpenClaw runs directly (useful for non-Discord instances)

**How it works:** The entrypoint wrapper (`entrypoint-wrapper.sh`) generates a proxychains4 config at runtime from env vars, with `localnet` exclusions for localhost/private networks so internal container communication isn't proxied. Then it wraps the original OpenClaw entrypoint with `proxychains4 -q`.

**Why not OpenClaw's built-in proxy?** OpenClaw has a `channels.discord.proxy` config option, but it only proxies the WebSocket gateway connection. REST API calls (sending messages) bypass it and go through the datacenter IP, which Discord blocks. `proxychains4` intercepts ALL outbound TCP at the libc level, so everything goes through the proxy.

See [RESIDENTIAL-PROXY.md](RESIDENTIAL-PROXY.md) for the full technical writeup.

### Important

Using personal tokens for automation violates Discord's Terms of Service. Accounts may be suspended if detected. Use at your own risk.

## Security notes

This setup is designed for **personal/team use**, not public-facing deployments:

- `dangerouslyDisableDeviceAuth: true` — skips device pairing
- `execSecurity: full` — agent can run any command
- `allowedOrigins: ["*"]` — any origin can connect to the Control UI
- Gateway token is the only auth barrier

For production use, consider restricting origins and enabling device auth.

## Troubleshooting

| Issue | Fix |
|---|---|
| 502/503 after deploy | Wait 2 minutes for the gateway to start |
| "origin not allowed" | Already fixed in the Dockerfile config |
| "device identity required" | Already fixed with `dangerouslyDisableDeviceAuth` |
| "sudo: not found" | Already fixed — sudo is installed in the image |
| Chromium won't launch | Already fixed — all system libs are installed |
| Build fails | Check that the repo URL is accessible (public) |
| Discord 503 / gateway crash | Discord token set without proxy — set PROXY_HOST or remove DISCORD_BOT_TOKEN |
| Discord rejects connection | Datacenter IP detected — ensure proxychains is working (check PROXY_* env vars) |
