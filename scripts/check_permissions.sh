#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

SUDO=""
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
fi

log()  { printf "\n[+] %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*" >&2; }

# Create expected directories if missing
ensure_dirs() {
  local dirs=(
    "nginx/conf.d"
    "nginx/certs"
    "nginx/log"
    "scripts"
  )

  for d in "${dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
      log "Creating directory: $d"
      $SUDO mkdir -p "$d"
    fi
  done
}

set_perms() {
  log "Setting permissions..."

  # Top-level files
  [[ -f docker-compose.yml ]] && $SUDO chmod 0644 docker-compose.yml || warn "docker-compose.yml not found"
  [[ -f .env ]] && $SUDO chmod 0600 .env || warn ".env not found (recommended to create one)"

  # Scripts should be executable
  if compgen -G "scripts/*.sh" > /dev/null; then
    $SUDO chmod 0755 scripts/*.sh
  fi

  # Nginx config files
  if compgen -G "nginx/conf.d/*.conf" > /dev/null; then
    $SUDO chmod 0644 nginx/conf.d/*.conf
  fi

  # TLS certs/keys
  # - certs can be world-readable (inside container it’s fine either way)
  # - private keys should be restricted
  if compgen -G "nginx/certs/*.crt" > /dev/null; then
    $SUDO chmod 0644 nginx/certs/*.crt
  fi
  if compgen -G "nginx/certs/*.pem" > /dev/null; then
    $SUDO chmod 0644 nginx/certs/*.pem
  fi
  if compgen -G "nginx/certs/*.key" > /dev/null; then
    $SUDO chmod 0600 nginx/certs/*.key
  fi

  # Logs dir (files will be created by container; keep dir writable by root)
  $SUDO chmod 0755 nginx/log

  log "Permissions applied."
}

ownership_hint() {
  cat <<'EOF'

Notes:
- .env is set to 0600 because it contains secrets.
- nginx/certs/*.key is set to 0600 to protect private keys.
- If you need non-root ownership (CI/CD), set it manually after this script.

EOF
}

ensure_dirs
set_perms
ownership_hint
