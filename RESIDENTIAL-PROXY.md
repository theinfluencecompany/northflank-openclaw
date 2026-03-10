# Residential Proxy Setup for Discord Selfbot on Northflank

## Problem

Discord blocks user token (selfbot) connections from datacenter IPs. Northflank runs on cloud infrastructure, so Discord rejects WebSocket gateway connections and REST API calls originating from these IPs.

OpenClaw has a built-in `channels.discord.proxy` config option, but it has a known bug (GitHub issues #28788, #30221): only the WebSocket gateway connection uses the proxy, while REST API calls (sending messages, fetching channels) bypass it entirely and go through the datacenter IP.

## Solution: proxychains4

Wrap the entire OpenClaw process with `proxychains4` so ALL outbound TCP traffic routes through a residential SOCKS5 proxy. This bypasses OpenClaw's proxy bug since the proxy is applied at the OS/libc level.

### Architecture

```
OpenClaw process
  └─ proxychains4 (LD_PRELOAD intercept)
       ├─ localhost/private → DIRECT (localnet exclusions)
       └─ everything else → SOCKS5 residential proxy → internet
```

### Key files

- `services/openclaw-discord/Dockerfile` — installs proxychains4, sets up entrypoint wrapper
- `services/openclaw-discord/entrypoint-wrapper.sh` — generates proxychains config from env vars at runtime, then exec's the original entrypoint through proxychains

### Dockerfile changes

```dockerfile
# Install proxychains4 alongside other deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    ... \
    proxychains4 \
    && rm -rf /var/lib/apt/lists/*

# Rename original entrypoint and COPY wrapper
RUN mv /app/scripts/entrypoint.sh /app/scripts/entrypoint-orig.sh
COPY services/openclaw-discord/entrypoint-wrapper.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh
```

### Entrypoint wrapper (entrypoint-wrapper.sh)

```bash
#!/bin/bash
set -e

if [ -n "$PROXY_HOST" ]; then
  cat > /etc/proxychains4.conf <<EOF
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
localnet 127.0.0.0/255.0.0.0
localnet 10.0.0.0/255.0.0.0
localnet 172.16.0.0/255.240.0.0
localnet 192.168.0.0/255.255.0.0

[ProxyList]
socks5 ${PROXY_HOST} ${PROXY_PORT:-12321} ${PROXY_USER} ${PROXY_PASS}
EOF
  exec proxychains4 -q /app/scripts/entrypoint-orig.sh "$@"
else
  exec /app/scripts/entrypoint-orig.sh "$@"
fi
```

### Critical: localnet exclusions

Without `localnet` directives, proxychains routes ALL TCP connections through the proxy — including localhost. This breaks:
- nginx → gateway communication (localhost:8080)
- Internal service health checks
- Any container-internal networking

The four localnet lines exclude localhost (127.0.0.0/8) and all RFC 1918 private ranges so internal traffic stays direct.

### Environment variables

Set these on the Northflank service:

| Variable | Value | Description |
|---|---|---|
| `PROXY_HOST` | `geo.iproyal.com` | SOCKS5 proxy hostname |
| `PROXY_PORT` | `12321` | SOCKS5 proxy port |
| `PROXY_USER` | (from provider) | Proxy auth username |
| `PROXY_PASS` | (from provider) | Proxy auth password |
| `DISCORD_BOT_TOKEN` | (user token) | Discord personal account token |

If `PROXY_HOST` is not set, the wrapper falls back to running OpenClaw directly without proxy.

### Proxy provider

IPRoyal residential proxies:
- Protocol: SOCKS5
- Endpoint: `geo.iproyal.com:12321`
- Pricing: $1.75/GB, non-expiring traffic
- Estimated cost for 10k Discord messages/month: ~$0.10-$0.18

### Important: env var ordering on Northflank

Northflank's `POST /runtime-environment` endpoint **replaces** all env vars (not merges). Always include ALL env vars in a single POST request, or you'll wipe existing ones.

### Gotchas encountered

1. **Heredoc in Dockerfile RUN fails** — Docker executes RUN with `/bin/sh -c` which doesn't handle nested heredocs. Solution: use a separate script file with COPY.

2. **DISCORD_BOT_TOKEN without proxy crashes gateway** — If you set the Discord token but don't have the proxy configured, Discord rejects the connection from the datacenter IP and the gateway crashes into a restart loop (503). Always set proxy vars and Discord token together.

3. **proxy_dns + localnet** — The `proxy_dns` directive routes DNS through the proxy, but `localnet` exclusions ensure local connections still resolve normally.

### Verification

After deployment, the service should:
1. Return HTTP 200 on the root URL (gateway Control UI)
2. Discord WebSocket connects through residential IP
3. Discord REST API calls route through residential IP
4. OpenAI API calls also route through residential IP (harmless, works fine)
