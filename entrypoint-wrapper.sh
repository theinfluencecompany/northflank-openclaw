#!/bin/bash
set -e

# Generate proxychains config from env vars (if proxy is configured)
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
  echo ">> Proxychains configured: ${PROXY_HOST}:${PROXY_PORT:-12321}"
  exec proxychains4 -q /app/scripts/entrypoint-orig.sh "$@"
else
  echo ">> No proxy configured, running directly"
  exec /app/scripts/entrypoint-orig.sh "$@"
fi
