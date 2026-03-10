#!/usr/bin/env bash
set -euo pipefail

# ── OpenClaw on Northflank — one-command deploy ─────────────────────
#
# Usage:
#   export NF_API_TOKEN="your-northflank-team-api-key"
#   export OPENAI_API_KEY="sk-..."
#   ./deploy.sh [instance-name]
#
# Example:
#   ./deploy.sh my-assistant
#   ./deploy.sh tiktok-bot
#
# This creates a Northflank project "openclaw" (if needed) and deploys
# a combined service that builds the custom Dockerfile from this repo.

NF_API_TOKEN="${NF_API_TOKEN:?Set NF_API_TOKEN to your Northflank team API key}"
OPENAI_API_KEY="${OPENAI_API_KEY:?Set OPENAI_API_KEY to your OpenAI API key}"

INSTANCE_NAME="${1:-openclaw-app}"
PROJECT_NAME="openclaw"
REGION="${NF_REGION:-us-west}"
PLAN="${NF_PLAN:-nf-compute-20}"
MODEL="${OPENCLAW_MODEL:-openai/gpt-5.4}"
REPO_URL="${REPO_URL:-https://github.com/theinfluencecompany/northflank-openclaw}"

NF_API="https://api.northflank.com/v1"
AUTH="Authorization: Bearer ${NF_API_TOKEN}"
CT="Content-Type: application/json"

nf() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sf -X "$method" "${NF_API}${path}" -H "$AUTH" -H "$CT" -d "$body"
  else
    curl -sf -X "$method" "${NF_API}${path}" -H "$AUTH" -H "$CT"
  fi
}

# ── Step 1: Ensure project exists ───────────────────────────────────
echo "==> Checking project '${PROJECT_NAME}'..."
if nf GET "/projects/${PROJECT_NAME}" > /dev/null 2>&1; then
  echo "    Project exists."
else
  echo "    Creating project..."
  nf POST "/projects" "$(cat <<EOF
{"name":"${PROJECT_NAME}","description":"OpenClaw AI assistants","region":"${REGION}","color":"#FF6B35"}
EOF
)" > /dev/null
  echo "    Created."
fi

# ── Step 2: Generate gateway token ──────────────────────────────────
GW_TOKEN=$(openssl rand -hex 32)
echo "==> Gateway token: ${GW_TOKEN}"

# ── Step 3: Create combined service ─────────────────────────────────
echo "==> Creating service '${INSTANCE_NAME}'..."
SERVICE_RESP=$(nf POST "/projects/${PROJECT_NAME}/services/combined" "$(cat <<EOF
{
  "name": "${INSTANCE_NAME}",
  "description": "OpenClaw instance",
  "billing": {"deploymentPlan": "${PLAN}"},
  "deployment": {
    "instances": 1,
    "storage": {"ephemeralStorage": {"storageSize": 2048}, "shmSize": 64}
  },
  "ports": [{"name": "http", "internalPort": 8080, "public": true, "protocol": "HTTP"}],
  "vcsData": {
    "publicRepo": true,
    "projectUrl": "${REPO_URL}",
    "projectType": "github",
    "projectBranch": "main",
    "dockerFilePath": "/Dockerfile",
    "dockerWorkDir": "/"
  },
  "buildSettings": {
    "dockerfile": {
      "buildEngine": "kaniko",
      "dockerFilePath": "/Dockerfile",
      "dockerWorkDir": "/"
    }
  }
}
EOF
)")

SERVICE_ID=$(echo "$SERVICE_RESP" | jq -r '.data.id // .data.name // "unknown"')
echo "    Service: ${SERVICE_ID}"

# ── Step 4: Set environment variables ───────────────────────────────
echo "==> Setting environment variables..."
nf POST "/projects/${PROJECT_NAME}/services/${INSTANCE_NAME}/runtime-environment" "$(cat <<EOF
{"runtimeEnvironment":{"OPENAI_API_KEY":"${OPENAI_API_KEY}","OPENCLAW_GATEWAY_TOKEN":"${GW_TOKEN}","OPENCLAW_PRIMARY_MODEL":"${MODEL}"}}
EOF
)" > /dev/null
echo "    Done."

# ── Step 5: Wait for build ──────────────────────────────────────────
echo "==> Waiting for build..."
for i in $(seq 1 40); do
  sleep 15
  STATUS=$(nf GET "/projects/${PROJECT_NAME}/services/${INSTANCE_NAME}" | jq -r '.data.status.build.status')
  echo "    ${i}. ${STATUS}"
  if [[ "$STATUS" == "SUCCESS" ]]; then break; fi
  if [[ "$STATUS" == "FAILED" ]]; then echo "BUILD FAILED"; exit 1; fi
done

# ── Step 6: Wait for deploy ─────────────────────────────────────────
echo "==> Waiting for deployment..."
for i in $(seq 1 20); do
  sleep 10
  STATUS=$(nf GET "/projects/${PROJECT_NAME}/services/${INSTANCE_NAME}" | jq -r '.data.status.deployment.status')
  if [[ "$STATUS" == "COMPLETED" ]]; then
    echo "    Deployed!"
    break
  fi
  echo "    ${i}. ${STATUS}"
done

# ── Step 7: Get URL ─────────────────────────────────────────────────
sleep 5
DETAILS=$(nf GET "/projects/${PROJECT_NAME}/services/${INSTANCE_NAME}")
URL=$(echo "$DETAILS" | jq -r '.data.ports[0].dns // "pending"')

echo ""
echo "=========================================="
echo "  OpenClaw deployed on Northflank"
echo "=========================================="
echo ""
echo "  Instance:  ${INSTANCE_NAME}"
echo "  URL:       https://${URL}"
echo "  Token:     ${GW_TOKEN}"
echo ""
echo "  Open in browser:"
echo "    https://${URL}?token=${GW_TOKEN}"
echo ""
echo "  Note: Gateway takes ~2 minutes to start."
echo "  If you see 502/503, wait and refresh."
echo "=========================================="
