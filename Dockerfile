FROM coollabsio/openclaw:latest

# System dependencies for headless Chromium (Playwright browser automation)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libpango-1.0-0 libcairo2 libasound2 libatspi2.0-0 \
    libxshmfence1 fonts-liberation xdg-utils wget ca-certificates sudo \
    && rm -rf /var/lib/apt/lists/*

# Gateway config: allow all origins, disable device auth, full exec permissions
RUN mkdir -p /app/config && \
    echo '{"gateway":{"controlUi":{"allowedOrigins":["*"],"dangerouslyAllowHostHeaderOriginFallback":true,"allowInsecureAuth":true,"dangerouslyDisableDeviceAuth":true,"enabled":true}},"agents":{"defaults":{"session":{"elevatedLevel":"full","execSecurity":"full","execAsk":"off","execHost":"gateway"}}}}' \
    > /app/config/openclaw.json

# Patch: remove browser sidecar proxy (no browser container in this setup)
RUN sed -i 's|proxy_pass http://browser:3000/;|return 404;|' /app/scripts/entrypoint.sh

EXPOSE 8080
