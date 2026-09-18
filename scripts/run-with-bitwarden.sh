#!/usr/bin/env bash
#
# run-with-bitwarden.sh — start the keep-mcp container with the Google master
# token pulled from Bitwarden Secrets Manager, without the token touching
# persistent disk, environment variables, or shell history.
#
# Optional startup path for people who manage the master token in Bitwarden:
# on every invocation the token is fetched into a RAM-backed temporary file
# (/dev/shm where available) and bind-mounted into the container at the
# server's default secret path (/run/secrets/google_master_token). Rotating
# the token in Bitwarden is enough — nothing needs updating on this machine,
# and no systemd unit is required. The temp file is removed when the
# container (or this script) exits.
#
# Works with Podman or Docker: the first runtime found on PATH wins; override
# with CONTAINER_RUNTIME=podman (or =docker).
#
# Requirements: podman or docker, bws (Bitwarden Secrets Manager CLI), jq.
#
# Environment (each may be exported, or set in the .env file — see below):
#   GOOGLE_EMAIL      your Google account email (required)
#   BWS_SECRET_ID     Bitwarden Secrets Manager secret ID holding the master token (required)
#   BWS_ACCESS_TOKEN  service-account access token, or...
#   BWS_TOKEN_FILE    ...path to a file containing it, e.g. ~/.config/keep-mcp/bws-token (chmod 600)
#   ENV_FILE          path to the .env file (default: .env in the repo root)
#   CONTAINER_RUNTIME container runtime: podman or docker
#                     (default: first one found on PATH)
#   IMAGE             container image (default: keep-mcp:latest; build it first,
#                     e.g.: podman build -t keep-mcp .  or  docker build -t keep-mcp .)
#
# Configuration: put GOOGLE_EMAIL and BWS_SECRET_ID in the repo's .env file
# (see .example.env) — the script reads it for anything not already exported.
# The secret ID is only an identifier, so .env is a fine home for it.
# Keep BWS_ACCESS_TOKEN itself out of .env and out of shell history: store it
# in its own chmod-600 file and point BWS_TOKEN_FILE at it (BWS_TOKEN_FILE
# itself may live in .env).
#
# Any extra arguments are passed through to `<runtime> run` (before the image),
# so this works both for stdio launches and for daemon mode once a network
# transport exists:
#
#   # 1. cp .example.env .env, then fill in GOOGLE_EMAIL, BWS_SECRET_ID,
#   #    and BWS_TOKEN_FILE (pointing at your chmod-600 access-token file).
#   # 2. Build the image from the repo root, e.g.: podman build -t keep-mcp .
#   # 3. stdio — have your MCP client run this script:
#   ./scripts/run-with-bitwarden.sh --rm -i
#
#   # daemon (for a future Streamable HTTP transport):
#   ./scripts/run-with-bitwarden.sh -d --name keep-mcp -p 127.0.0.1:8080:8080

set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed" >&2; exit 1; }
}

# Pick a container runtime: an explicit CONTAINER_RUNTIME wins, otherwise the
# first one found on PATH.
if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME=docker
  else
    echo "error: neither 'podman' nor 'docker' found on PATH" >&2
    echo "Install one of them or set CONTAINER_RUNTIME=podman|docker." >&2
    exit 1
  fi
fi
need "$CONTAINER_RUNTIME"
need bws
need jq

# Preflight: fail fast with a useful message if the runtime itself can't start.
# Without this, a broken rootless setup only surfaces later as a cryptic
# `jq: Broken pipe` when the token-fetch pipeline collapses.
if ! "$CONTAINER_RUNTIME" info >/dev/null 2>&1; then
  echo "error: '$CONTAINER_RUNTIME info' failed — $CONTAINER_RUNTIME isn't usable here." >&2
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    cat >&2 <<EOF
The usual cause is missing subordinate UID/GID ranges (newuidmap: Operation not permitted):
  check: grep -E '^$USER:' /etc/subuid /etc/subgid
  fix (as root): usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
Inside a Proxmox LXC container you may also need 'features: nesting=1',
/dev/net/tun, and idmap entries for the subuid range in the container config
on the Proxmox host.
EOF
  else
    echo "Is the Docker daemon running and is your user allowed to talk to it?" >&2
  fi
  exit 1
fi

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

IMAGE="${IMAGE:-keep-mcp:latest}"

# Preflight: the image must be built locally first.
if ! "$CONTAINER_RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "error: container image '$IMAGE' not found locally." >&2
  echo "Build it first from the repo root: $CONTAINER_RUNTIME build -t $IMAGE ." >&2
  exit 1
fi

export BWS_ACCESS_TOKEN

# Fetch the token into a RAM-backed temp file (/dev/shm where available, so it
# never touches persistent disk) and bind-mount it where the server expects
# its secret file. The server reads it once at first use.
token_file="$(mktemp /dev/shm/keep-mcp-token.XXXXXX 2>/dev/null || mktemp "${TMPDIR:-/tmp}/keep-mcp-token.XXXXXX")"
chmod 600 "$token_file"
bws secret get "$BWS_SECRET_ID" | jq -r '.value // .' > "$token_file"

# Run the container in the background so this script can forward signals to it
# and always remove the temp token file afterwards. (A plain `exec` would skip
# the EXIT trap and leak the file.)
cleanup() { rm -f "$token_file"; }
trap cleanup EXIT
"$CONTAINER_RUNTIME" run \
  -v "$token_file:/run/secrets/google_master_token:ro" \
  -e "GOOGLE_EMAIL=${GOOGLE_EMAIL}" \
  "$@" "$IMAGE" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null' INT TERM
wait "$child"
