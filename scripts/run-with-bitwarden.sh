#!/usr/bin/env bash
#
# run-with-bitwarden.sh — start the keep-mcp container with the Google master
# token pulled from Bitwarden Secrets Manager into a Podman secret.
#
# Optional startup path for people who manage the master token in Bitwarden:
# the token never touches the disk in plaintext and never appears in
# environment variables or shell history. The Podman secret is refreshed from
# Bitwarden on every invocation, so rotating the token there is enough —
# nothing needs updating on this machine, and no systemd unit is required.
#
# Requirements: podman, bws (Bitwarden Secrets Manager CLI), jq.
#
# Environment (each may be exported, or set in the .env file — see below):
#   GOOGLE_EMAIL      your Google account email (required)
#   BWS_SECRET_ID     Bitwarden Secrets Manager secret ID holding the master token (required)
#   BWS_ACCESS_TOKEN  service-account access token, or...
#   BWS_TOKEN_FILE    ...path to a file containing it, e.g. ~/.config/keep-mcp/bws-token (chmod 600)
#   ENV_FILE          path to the .env file (default: .env in the repo root)
#   SECRET_NAME       Podman secret name (default: google_master_token — matches
#                     the server's default GOOGLE_MASTER_TOKEN_FILE)
#   IMAGE             container image (default: keep-mcp:latest; build it first
#                     with: podman build -t keep-mcp .)
#
# Configuration: put GOOGLE_EMAIL and BWS_SECRET_ID in the repo's .env file
# (see .example.env) — the script reads it for anything not already exported.
# The secret ID is only an identifier, so .env is a fine home for it.
# Keep BWS_ACCESS_TOKEN itself out of .env and out of shell history: store it
# in its own chmod-600 file and point BWS_TOKEN_FILE at it (BWS_TOKEN_FILE
# itself may live in .env).
#
# Any extra arguments are passed through to `podman run` (before the image),
# so this works both for stdio launches and for daemon mode once a network
# transport exists:
#
#   # 1. cp .example.env .env, then fill in GOOGLE_EMAIL, BWS_SECRET_ID,
#   #    and BWS_TOKEN_FILE (pointing at your chmod-600 access-token file).
#   # 2. stdio — have your MCP client run this script:
#   ./scripts/run-with-bitwarden.sh --rm -i
#
#   # daemon (for a future Streamable HTTP transport):
#   ./scripts/run-with-bitwarden.sh -d --name keep-mcp -p 127.0.0.1:8080:8080

set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed" >&2; exit 1; }
}
need podman
need bws
need jq

# Load the repo's .env file for anything not already exported, so GOOGLE_EMAIL
# and BWS_SECRET_ID can live in the same .env the compose flow uses.
# Explicitly exported variables always win over the file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"            # strip leading whitespace
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -z "${!key:-}" ]]; then
      val="${line#*=}"
      if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
      printf -v "$key" '%s' "$val"
      export "$key"
    fi
  done < "$ENV_FILE"
fi

: "${GOOGLE_EMAIL:?Set GOOGLE_EMAIL to your Google account email}"
: "${BWS_SECRET_ID:?Set BWS_SECRET_ID to the Bitwarden Secrets Manager secret ID}"
if [[ -z "${BWS_ACCESS_TOKEN:-}" && -n "${BWS_TOKEN_FILE:-}" ]]; then
  BWS_ACCESS_TOKEN="$(cat "$BWS_TOKEN_FILE")"
fi
: "${BWS_ACCESS_TOKEN:?Set BWS_ACCESS_TOKEN or BWS_TOKEN_FILE}"

SECRET_NAME="${SECRET_NAME:-google_master_token}"
IMAGE="${IMAGE:-keep-mcp:latest}"

export BWS_ACCESS_TOKEN

# Refresh the secret on every start so rotation in Bitwarden takes effect here.
podman secret rm "$SECRET_NAME" >/dev/null 2>&1 || true
bws secret get "$BWS_SECRET_ID" | jq -r '.value // .' \
  | podman secret create "$SECRET_NAME" - >/dev/null

exec podman run --secret "$SECRET_NAME" -e "GOOGLE_EMAIL=${GOOGLE_EMAIL}" "$@" "$IMAGE"
