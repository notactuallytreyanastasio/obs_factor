#!/bin/sh
# Runs the builder (OBS_ROLE=builder) on the laptop, for the lab: git, the
# Docker CLI pointed at the lab's Docker (Colima), and an LLM over a chat
# completions API for the recipe agent. The observer container reaches it at
# http://host.docker.internal:14100 (lab/compose.yml).
#
# The LLM is DeepSeek unless BUILDER_LLM_URL/_MODEL say otherwise. Its key is
# BUILDER_LLM_KEY, or DEEPSEEK_API_KEY read from $BUILDER_ENV_FILE (default
# ~/code/blog/.env, where the blog keeps it). The key is never printed.
cd "$(dirname "$0")/.." || exit 1
export OBS_ROLE=builder PORT=14100 \
  BUILDER_TOKEN=obslab-builder \
  BUILDER_STATE_DIR="$PWD/lab/built" \
  BUILDER_DOMAIN=lab.test \
  BUILDER_A_RECORD=127.0.0.1 \
  BUILDER_DNS_SERVER=127.0.0.1:15353 \
  BUILDER_CADDY_CONTAINER=obslab-caddy-1 \
  BUILDER_CADDY_HTTP=http://127.0.0.1:18080 \
  BUILDER_SITE_PREFIX=http:// \
  BUILDER_NETWORK=obslab_default \
  BUILDER_LLM_URL="${BUILDER_LLM_URL:-https://api.deepseek.com}" \
  BUILDER_LLM_MODEL="${BUILDER_LLM_MODEL:-deepseek-flash}"
if [ -z "$BUILDER_LLM_KEY" ]; then
  env_file="${BUILDER_ENV_FILE:-$HOME/code/blog/.env}"
  BUILDER_LLM_KEY=$(grep '^DEEPSEEK_API_KEY=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")
  [ -z "$BUILDER_LLM_KEY" ] && { echo "builder: no BUILDER_LLM_KEY, and no DEEPSEEK_API_KEY in $env_file" >&2; exit 1; }
  export BUILDER_LLM_KEY
fi
# Homebrew's buildx plugin, called directly: the Docker CLI does not look
# where Homebrew puts it unless ~/.docker/config.json says so.
for b in /opt/homebrew/lib/docker/cli-plugins/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx; do
  [ -z "$BUILDER_BUILDX" ] && [ -x "$b" ] && export BUILDER_BUILDX="$b"
done
exec mix phx.server
