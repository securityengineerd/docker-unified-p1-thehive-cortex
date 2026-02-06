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
die()  { printf "\n[X] %s\n" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_file() {
  [[ -f "$1" ]] || die "Missing required file: $1"
}

# -----------------------------
# Config (customize via .env)
# -----------------------------
ENV_FILE=".env"

# Default cert filenames if not set in .env
THEHIVE_CERT_DEFAULT="thehive.crt"
THEHIVE_KEY_DEFAULT="thehive.key"
CORTEX_CERT_DEFAULT="cortex.crt"
CORTEX_KEY_DEFAULT="cortex.key"

# -----------------------------
# Preflight checks
# -----------------------------
preflight() {
  log "Preflight checks..."

  need_cmd docker
  need_cmd awk
  need_cmd grep
  need_cmd sed

  # Docker daemon reachable?
  docker info >/dev/null 2>&1 || die "Docker daemon not reachable. Is docker running?"

  # Compose plugin present?
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not available (docker compose)."

  require_file "docker-compose.yml"

  log "Preflight OK."
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    die "Missing .env file. Create one (or copy from your template) and re-run."
  fi

  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
}

validate_env() {
  log "Validating required .env variables..."

  # Required for nginx routing
  : "${THEHIVE_FQDN:?Missing THEHIVE_FQDN in .env (e.g. thehive.example.com)}"
  : "${CORTEX_FQDN:?Missing CORTEX_FQDN in .env (e.g. cortex.example.com)}"

  # Required app secrets and integration
  : "${THEHIVE_SECRET:?Missing THEHIVE_SECRET in .env}"
  : "${MINIO_ROOT_USER:?Missing MINIO_ROOT_USER in .env}"
  : "${MINIO_ROOT_PASSWORD:?Missing MINIO_ROOT_PASSWORD in .env}"
  : "${CORTEX_API_KEY:?Missing CORTEX_API_KEY in .env}"

  log "Env validation OK."
}

ensure_kernel_tuning() {
  # Elasticsearch commonly requires vm.max_map_count=262144
  # We'll apply it if needed and persist it.
  log "Checking vm.max_map_count for Elasticsearch tuning..."
  local current
  current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"

  if [[ "$current" -lt 262144 ]]; then
    warn "vm.max_map_count is $current (<262144). Updating (requires sudo)."
    $SUDO sysctl -w vm.max_map_count=262144 >/dev/null

    # Persist
    $SUDO mkdir -p /etc/sysctl.d
    echo "vm.max_map_count=262144" | $SUDO tee /etc/sysctl.d/99-elasticsearch.conf >/dev/null
    $SUDO sysctl --system >/dev/null || true

    log "vm.max_map_count set to 262144 and persisted."
  else
    log "vm.max_map_count is already $current (OK)."
  fi
}

ensure_dirs() {
  log "Ensuring directory structure..."
  mkdir -p nginx/conf.d nginx/certs nginx/log scripts
  log "Directories present."
}

generate_nginx_confs() {
  # Generates nginx vhosts if they don't exist, using THEHIVE_FQDN / CORTEX_FQDN
  # Force HTTPS always (HTTP -> HTTPS redirect).
  local thehive_conf="nginx/conf.d/thehive.conf"
  local cortex_conf="nginx/conf.d/cortex.conf"

  local thehive_cert="${THEHIVE_CERT:-$THEHIVE_CERT_DEFAULT}"
  local thehive_key="${THEHIVE_KEY:-$THEHIVE_KEY_DEFAULT}"
  local cortex_cert="${CORTEX_CERT:-$CORTEX_CERT_DEFAULT}"
  local cortex_key="${CORTEX_KEY:-$CORTEX_KEY_DEFAULT}"

  if [[ ! -f "$thehive_conf" ]]; then
    log "Generating $thehive_conf"
    cat > "$thehive_conf" <<EOF
server {
  listen 80;
  server_name ${THEHIVE_FQDN};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name ${THEHIVE_FQDN};

  ssl_certificate     /etc/nginx/certs/${thehive_cert};
  ssl_certificate_key /etc/nginx/certs/${thehive_key};

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;

  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  client_max_body_size 50m;

  location / {
    proxy_pass http://thehive:9000;

    proxy_http_version 1.1;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
  }
}
EOF
  else
    log "Found existing $thehive_conf (leaving as-is)."
  fi

  if [[ ! -f "$cortex_conf" ]]; then
    log "Generating $cortex_conf"
    cat > "$cortex_conf" <<EOF
server {
  listen 80;
  server_name ${CORTEX_FQDN};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name ${CORTEX_FQDN};

  ssl_certificate     /etc/nginx/certs/${cortex_cert};
  ssl_certificate_key /etc/nginx/certs/${cortex_key};

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;

  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  client_max_body_size 50m;

  location / {
    proxy_pass http://cortex:9001;

    proxy_http_version 1.1;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
  }
}
EOF
  else
    log "Found existing $cortex_conf (leaving as-is)."
  fi
}

validate_certs() {
  log "Validating TLS certificate/key files exist..."

  local thehive_cert="nginx/certs/${THEHIVE_CERT:-$THEHIVE_CERT_DEFAULT}"
  local thehive_key="nginx/certs/${THEHIVE_KEY:-$THEHIVE_KEY_DEFAULT}"
  local cortex_cert="nginx/certs/${CORTEX_CERT:-$CORTEX_CERT_DEFAULT}"
  local cortex_key="nginx/certs/${CORTEX_KEY:-$CORTEX_KEY_DEFAULT}"

  [[ -f "$thehive_cert" ]] || die "Missing TLS cert: $thehive_cert"
  [[ -f "$thehive_key"  ]] || die "Missing TLS key : $thehive_key"
  [[ -f "$cortex_cert"  ]] || die "Missing TLS cert: $cortex_cert"
  [[ -f "$cortex_key"   ]] || die "Missing TLS key : $cortex_key"

  log "TLS files OK."
}

run_permissions() {
  log "Running permissions script..."
  bash ./scripts/check_permissions.sh
}

compose_up() {
  log "Pulling images..."
  docker compose pull

  log "Starting stack..."
  docker compose up -d

  log "Stack started."
}

post_checks() {
  log "Post-start checks..."

  docker compose ps

  # Validate nginx config inside container
  if docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
    log "Validating nginx config (nginx -t)..."
    docker exec nginx nginx -t
  else
    warn "nginx container not found for config test."
  fi

  log "Local-only port checks (should succeed on host):"
  curl -fsSI http://127.0.0.1:9000 >/dev/null && log "TheHive local port OK (127.0.0.1:9000)" || warn "TheHive local port check failed"
  curl -fsSI http://127.0.0.1:9001 >/dev/null && log "Cortex local port OK (127.0.0.1:9001)" || warn "Cortex local port check failed"

  log "Done."
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/init.sh [--no-generate-nginx] [--no-sysctl] [--no-pull]

Options:
  --no-generate-nginx   Do not auto-generate nginx vhost configs.
  --no-sysctl           Do not adjust vm.max_map_count.
  --no-pull             Skip docker compose pull.
EOF
}

main() {
  local gen_nginx=1
  local do_sysctl=1
  local do_pull=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-generate-nginx) gen_nginx=0; shift ;;
      --no-sysctl)         do_sysctl=0; shift ;;
      --no-pull)           do_pull=0; shift ;;
      -h|--help)           usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  preflight
  ensure_dirs
  load_env
  validate_env

  if [[ $gen_nginx -eq 1 ]]; then
    generate_nginx_confs
  fi

  validate_certs
  run_permissions

  if [[ $do_sysctl -eq 1 ]]; then
    ensure_kernel_tuning
  fi

  if [[ $do_pull -eq 1 ]]; then
    log "Pulling images..."
    docker compose pull
  fi

  compose_up
  post_checks

  log "Init complete."
}

main "$@"
``
