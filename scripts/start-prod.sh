#!/bin/bash
# =============================================================================
# Production Startup Script
# =============================================================================
#
# Verifies that Ollama is running and required models are available, then
# starts the production Docker Compose stack.
#
# Usage:
#   ./scripts/start-prod.sh                        # defaults to .env.production
#   ./scripts/start-prod.sh --env-file .env.staging
#   ./scripts/start-prod.sh --skip-pull             # skip Ollama model pull check
#   ./scripts/start-prod.sh --build                 # rebuild from source (rare —
#                                                  # default pulls signed images
#                                                  # from ghcr.io/opuspopuli/*)
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ENV_FILE=".env.production"
SKIP_PULL=false
BUILD_FLAG=""
VERIFY_IMAGES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --skip-pull)
      SKIP_PULL=true
      shift
      ;;
    --build)
      BUILD_FLAG="--build"
      shift
      ;;
    --verify)
      VERIFY_IMAGES=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--env-file <file>] [--skip-pull] [--build] [--verify]"
      exit 1
      ;;
  esac
done

echo "============================================"
echo "  Opus Populi -- Production Startup"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Check Ollama is installed
# ---------------------------------------------------------------------------
echo "[1/6] Checking Ollama installation..."
if ! command -v ollama &> /dev/null; then
  echo "ERROR: Ollama is not installed."
  echo ""
  echo "Install with:  brew install ollama"
  echo "Or download:   https://ollama.com/download"
  exit 1
fi
echo "      Ollama installed: $(ollama --version 2>/dev/null || echo 'unknown version')"

# ---------------------------------------------------------------------------
# 2. Check Ollama is running
# ---------------------------------------------------------------------------
echo "[2/6] Checking Ollama is running..."
if curl -sf http://localhost:11434/ > /dev/null 2>&1; then
  echo "      Ollama is running on port 11434"
else
  echo "      Ollama is not running. Attempting to start..."

  # Try macOS app first, then brew services
  if [[ "$(uname)" == "Darwin" ]]; then
    if open -Ra "Ollama" 2>/dev/null; then
      open -a "Ollama"
      echo "      Started Ollama.app -- waiting for it to be ready..."
    else
      brew services start ollama 2>/dev/null || true
      echo "      Started via brew services -- waiting for it to be ready..."
    fi
  else
    # Linux: start ollama serve in background
    ollama serve &>/dev/null &
    echo "      Started ollama serve -- waiting for it to be ready..."
  fi

  # Wait up to 30 seconds for Ollama to respond
  for i in $(seq 1 30); do
    if curl -sf http://localhost:11434/ > /dev/null 2>&1; then
      echo "      Ollama is ready (took ${i}s)"
      break
    fi
    if [[ $i -eq 30 ]]; then
      echo "ERROR: Ollama failed to start within 30 seconds."
      echo "       Try starting it manually: open -a Ollama (macOS) or ollama serve (Linux)"
      exit 1
    fi
    sleep 1
  done
fi

# ---------------------------------------------------------------------------
# 3. Check required models
# ---------------------------------------------------------------------------
echo "[3/6] Checking required models..."

# Read LLM_MODEL from env file, default to qwen3.5:35b
LLM_MODEL="qwen3.5:35b"
if [[ -f "$ENV_FILE" ]]; then
  PARSED_MODEL=$(grep -E '^LLM_MODEL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  if [[ -n "$PARSED_MODEL" ]]; then
    LLM_MODEL="$PARSED_MODEL"
  fi
fi

INSTALLED_MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || true)

if echo "$INSTALLED_MODELS" | grep -q "^${LLM_MODEL}"; then
  echo "      Model '$LLM_MODEL' is available"
elif [[ "$SKIP_PULL" == "true" ]]; then
  echo "      WARNING: Model '$LLM_MODEL' not found (skipping pull due to --skip-pull)"
else
  echo "      Model '$LLM_MODEL' not found. Pulling..."
  ollama pull "$LLM_MODEL"
  echo "      Model '$LLM_MODEL' pulled successfully"
fi

# ---------------------------------------------------------------------------
# 4. Health check
# ---------------------------------------------------------------------------
echo "[4/6] Running Ollama health check..."
if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
  MODEL_COUNT=$(curl -sf http://localhost:11434/api/tags | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo "?")
  echo "      Ollama API healthy ($MODEL_COUNT model(s) loaded)"
else
  echo "ERROR: Ollama API is not responding at http://localhost:11434/api/tags"
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Verify container image signatures (optional)
# ---------------------------------------------------------------------------
if [[ "$VERIFY_IMAGES" == "true" ]]; then
  echo "[5/6] Verifying container image signatures..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "${SCRIPT_DIR}/verify-images.sh" ]]; then
    "${SCRIPT_DIR}/verify-images.sh"
  else
    echo "ERROR: verify-images.sh not found or not executable."
    echo "       Expected at: ${SCRIPT_DIR}/verify-images.sh"
    exit 1
  fi
else
  echo "[5/6] Skipping image verification (use --verify to enable)"
fi

# ---------------------------------------------------------------------------
# 6. Start Docker Compose
# ---------------------------------------------------------------------------
echo "[6/6] Starting production stack..."
echo ""

if [[ ! -f "$ENV_FILE" ]]; then
  echo "WARNING: Environment file '$ENV_FILE' not found."
  echo "         Copy the template:  cp .env.production.example .env.production"
  echo "         Then fill in your values and re-run this script."
  exit 1
fi

docker compose -f docker-compose-prod.yml --env-file "$ENV_FILE" pull
docker compose -f docker-compose-prod.yml --env-file "$ENV_FILE" up -d --remove-orphans $BUILD_FLAG

echo ""
echo "============================================"
echo "  Production stack started"
echo "============================================"
echo ""

# Post-start verification
echo "Verifying services..."
sleep 5

# Check container health
UNHEALTHY=$(docker compose -f docker-compose-prod.yml ps --format json 2>/dev/null \
  | python3 -c "
import sys, json
lines = sys.stdin.read().strip().split('\n')
for line in lines:
    c = json.loads(line)
    if c.get('Health','') == 'unhealthy':
        print(f\"  - {c['Service']}: unhealthy\")
" 2>/dev/null || true)

if [[ -n "$UNHEALTHY" ]]; then
  echo "WARNING: Some services are unhealthy:"
  echo "$UNHEALTHY"
  echo ""
  echo "Check logs:  docker compose -f docker-compose-prod.yml logs <service>"
else
  echo "All services running."
fi

# Verify containers can reach Ollama
echo ""
echo "Verifying LLM connectivity from containers..."
if docker exec opuspopuli-prod-knowledge \
  node -e "require('http').get('http://host.docker.internal:11434/', r => { process.exit(r.statusCode === 200 ? 0 : 1) }).on('error', () => process.exit(1))" 2>/dev/null; then
  echo "  Containers can reach Ollama via host.docker.internal:11434"
else
  echo "  WARNING: Containers cannot reach Ollama. Check Docker Desktop network settings."
fi

echo ""
echo "Done. Verify externally:  curl https://api.opuspopuli.org/health"