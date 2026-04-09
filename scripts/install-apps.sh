#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./install-apps.sh              # interactive menu
#   ./install-apps.sh all          # install everything
#   ./install-apps.sh toolchain    # Homebrew + Node + Codex + Claude Code
#   ./install-apps.sh openclaw     # OpenClaw only     (requires toolchain)
#   ./install-apps.sh paperclip    # Paperclip only    (requires toolchain)
#   ./install-apps.sh hermes       # Hermes Agent only (requires toolchain)
#   ./install-apps.sh --help

OPENCLAW_INSTALL_URL="${OPENCLAW_INSTALL_URL:-https://openclaw.ai/install.sh}"
HOMEBREW_INSTALL_URL="${HOMEBREW_INSTALL_URL:-https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
PAPERCLIP_APP_PORT="${PAPERCLIP_APP_PORT:-3100}"
PAPERCLIP_SERVE_PORT="${PAPERCLIP_SERVE_PORT:-8443}"
PAPERCLIP_DB_NAME="${PAPERCLIP_DB_NAME:-paperclip}"
PAPERCLIP_DB_USER="${PAPERCLIP_DB_USER:-paperclip}"
PAPERCLIP_REPO_URL="${PAPERCLIP_REPO_URL:-https://github.com/paperclipai/paperclip.git}"
PAPERCLIP_REPO_DIR="${PAPERCLIP_REPO_DIR:-$HOME/apps/paperclip}"
OPENCLAW_ENV_FILE="${OPENCLAW_ENV_FILE:-$HOME/.openclaw/.env}"
PAPERCLIP_ENV_FILE="${PAPERCLIP_ENV_FILE:-$HOME/.config/paperclip/paperclip.env}"
HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as a non-root user, not root."
  exit 1
fi

export PATH="$HOME/.local/bin:$PATH"

# ── Helper functions ──────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [TARGET]

TARGET:
  all          Install everything: toolchain, OpenClaw, Paperclip, Hermes (default)
  toolchain    Homebrew + Node + Codex CLI + Claude Code CLI
  openclaw     OpenClaw only (requires toolchain already installed)
  paperclip    Paperclip only (requires toolchain already installed)
  hermes       Hermes Agent only (requires toolchain already installed)
  (none)       Interactive menu

Environment variable overrides:
  OPENCLAW_PORT             OpenClaw local port          (default: 18789)
  PAPERCLIP_APP_PORT        Paperclip local port         (default: 3100)
  PAPERCLIP_SERVE_PORT      Paperclip Tailscale port     (default: 8443)
  PAPERCLIP_DB_NAME         PostgreSQL database name     (default: paperclip)
  PAPERCLIP_DB_USER         PostgreSQL role name         (default: paperclip)
  PAPERCLIP_REPO_DIR        Path to Paperclip repo       (default: ~/apps/paperclip)
  OPENAI_API_KEY            OpenAI key for OpenClaw auth (optional)
  OPENCLAW_INSTALL_URL      Override OpenClaw install URL
  HOMEBREW_INSTALL_URL      Override Homebrew install URL
  PAPERCLIP_REPO_URL        Override Paperclip git URL
  HERMES_INSTALL_URL        Override Hermes installer URL
EOF
}

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

prompt_with_default() {
  local prompt="$1"
  local current="$2"
  local reply

  read -r -p "${prompt} [${current}]: " reply
  if [[ -n "${reply}" ]]; then
    printf '%s' "${reply}"
  else
    printf '%s' "${current}"
  fi
}

prompt_optional_secret() {
  local prompt="$1"
  local current="${2:-}"
  local reply

  if [[ -n "${current}" ]]; then
    read -r -s -p "${prompt} [press Enter to keep current value]: " reply
  else
    read -r -s -p "${prompt} [optional, press Enter to skip]: " reply
  fi
  printf '\n' >&2

  if [[ -n "${reply}" ]]; then
    printf '%s' "${reply}"
  else
    printf '%s' "${current}"
  fi
}

brew_shellenv() {
  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
    eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
  fi
}

systemd_path() {
  if [[ -d /home/linuxbrew/.linuxbrew/bin ]]; then
    printf '%s' "/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${HOME}/.npm-global/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"
  else
    printf '%s' "${HOME}/.linuxbrew/bin:${HOME}/.linuxbrew/sbin:${HOME}/.npm-global/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"
  fi
}

ensure_pnpm() {
  if command -v corepack >/dev/null 2>&1; then
    corepack enable
    corepack prepare pnpm@9.15.4 --activate
  else
    npm install -g pnpm@9.15.4
  fi
}

check_dns_health() {
  local target="${1:-platform.claude.com}"

  if getent hosts "${target}" >/dev/null 2>&1; then
    return 0
  fi

  printf '\nDNS warning: failed to resolve %s\n' "${target}" >&2
  printf 'Try: sudo systemctl restart systemd-resolved\n' >&2
  printf 'Then test again with: getent hosts %s\n\n' "${target}" >&2
  return 1
}

ensure_line() {
  local file="$1"
  local key="$2"
  local value="$3"

  mkdir -p "$(dirname "${file}")"
  touch "${file}"

  if grep -q "^${key}=" "${file}"; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

ensure_if_set() {
  local file="$1"
  local key="$2"
  local value="${3:-}"
  if [[ -n "${value}" ]]; then
    ensure_line "${file}" "${key}" "${value}"
  fi
}

random_hex() {
  openssl rand -hex 32
}

ensure_contains_line() {
  local file="$1"
  local line="$2"

  mkdir -p "$(dirname "${file}")"
  touch "${file}"

  if ! grep -Fqx "${line}" "${file}"; then
    printf '%s\n' "${line}" >> "${file}"
  fi
}

ensure_shell_path_setup() {
  local file="$1"
  ensure_contains_line "${file}" 'export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"'
  ensure_contains_line "${file}" 'if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"; elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"; fi'
}

current_env_value() {
  local file="$1"
  local key="$2"
  if [[ -f "${file}" ]]; then
    awk -F= -v k="${key}" '$1 == k {print substr($0, index($0, "=") + 1)}' "${file}" | tail -n 1
  fi
}

ensure_secret() {
  local file="$1"
  local key="$2"
  local existing
  existing="$(current_env_value "${file}" "${key}")"
  if [[ -z "${existing}" ]]; then
    ensure_line "${file}" "${key}" "$(random_hex)"
  fi
}

configure_openclaw_tailscale_auth() {
  local config_file="${HOME}/.openclaw/openclaw.json"
  local tmp_file
  local origin="${1:-}"

  if [[ ! -f "${config_file}" ]]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  jq --arg origin "${origin}" '
    .gateway = (.gateway // {}) |
    .gateway.bind = "loopback" |
    .gateway.tailscale = (.gateway.tailscale // {}) |
    .gateway.tailscale.mode = "serve" |
    .gateway.auth = (.gateway.auth // {}) |
    .gateway.auth.allowTailscale = true |
    .gateway.controlUi = (.gateway.controlUi // {}) |
    .gateway.controlUi.allowedOrigins = (
      if ($origin | length) > 0 then [$origin] else (.gateway.controlUi.allowedOrigins // []) end
    )
  ' "${config_file}" > "${tmp_file}"
  mv "${tmp_file}" "${config_file}"
}

configure_paperclip_instance_config() {
  local config_file="${HOME}/.paperclip/instances/default/config.json"
  local tmp_file
  local public_url="${1:-}"
  local allowed_hostnames="${2:-}"
  local database_url="${3:-}"

  if [[ ! -f "${config_file}" ]]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  jq \
    --arg public_url "${public_url}" \
    --arg allowed_hostnames "${allowed_hostnames}" \
    --arg database_url "${database_url}" '
    .deploymentMode = "authenticated" |
    .database = (.database // {}) |
    .database.mode = "external" |
    .database.url = $database_url |
    .server = (.server // {}) |
    .server.deploymentMode = "authenticated" |
    .server.exposure = "private" |
    .server.host = "127.0.0.1" |
    .server.port = (.server.port // 3100) |
    .server.serveUi = true |
    .server.allowedHostnames = (
      ($allowed_hostnames | split(",") | map(select(length > 0)))
    ) |
    .auth = (.auth // {}) |
    .auth.baseUrlMode = (.auth.baseUrlMode // "auto") |
    .auth.disableSignUp = (.auth.disableSignUp // false)
  ' "${config_file}" > "${tmp_file}"
  mv "${tmp_file}" "${config_file}"
}

# Resolve the Tailscale DNS name, or exit with a clear message.
resolve_tailscale_dns() {
  local ts_dns_name
  ts_dns_name="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
  if [[ -z "${ts_dns_name}" ]]; then
    echo "Could not determine Tailscale DNS name. Make sure Tailscale is connected."
    exit 1
  fi
  printf '%s' "${ts_dns_name}"
}

# Guard: ensure the toolchain (brew + node + npm) is present before running
# openclaw or paperclip targets standalone.
require_toolchain() {
  brew_shellenv
  export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "Node/npm not found. Run './install-apps.sh toolchain' first."
    exit 1
  fi
}

# ── Install functions ─────────────────────────────────────────────────────────

install_toolchain() {
  log "Installing apt packages for toolchain"
  sudo apt-get update
  sudo apt-get install -y \
    build-essential \
    file \
    openssl \
    pkg-config \
    procps \
    python3

  log "Installing Homebrew on Linux"
  if [[ ! -x /home/linuxbrew/.linuxbrew/bin/brew && ! -x "$HOME/.linuxbrew/bin/brew" ]]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "${HOMEBREW_INSTALL_URL}")"
  fi

  brew_shellenv

  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew was not found after installation."
    exit 1
  fi

  ensure_contains_line "$HOME/.bashrc"  'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
  ensure_contains_line "$HOME/.zshrc"   'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
  ensure_contains_line "$HOME/.profile" 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
  ensure_shell_path_setup "$HOME/.bashrc"
  ensure_shell_path_setup "$HOME/.zshrc"
  ensure_shell_path_setup "$HOME/.profile"

  log "Installing Node via Homebrew"
  brew install node

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "Node or npm was not found after installation."
    exit 1
  fi

  mkdir -p "$HOME/.npm-global/bin"
  npm config set prefix "$HOME/.npm-global"
  export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

  log "Installing Codex CLI"
  npm install -g @openai/codex

  log "Installing Claude Code CLI"
  npm install -g @anthropic-ai/claude-code
}

install_openclaw() {
  local ts_dns_name
  ts_dns_name="$(resolve_tailscale_dns)"

  log "Installing OpenClaw without starting onboarding yet"
  if ! command -v openclaw >/dev/null 2>&1; then
    curl -fsSL "${OPENCLAW_INSTALL_URL}" | bash -s -- --no-onboard
  fi

  if ! command -v openclaw >/dev/null 2>&1; then
    echo "OpenClaw was not found after installation."
    exit 1
  fi

  log "Preparing OpenClaw environment"
  mkdir -p "$HOME/.openclaw"
  touch "${OPENCLAW_ENV_FILE}"
  ensure_secret "${OPENCLAW_ENV_FILE}" "OPENCLAW_GATEWAY_TOKEN"
  ensure_if_set "${OPENCLAW_ENV_FILE}" "OPENAI_API_KEY" "${OPENAI_API_KEY:-}"

  log "Running OpenClaw onboarding"
  local openclaw_auth_choice="skip"
  local openclaw_extra_args=(--accept-risk)

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    openclaw_auth_choice="openai-api-key"
    openclaw_extra_args=(--secret-input-mode ref --accept-risk)
  fi

  set -a
  source "${OPENCLAW_ENV_FILE}"
  set +a

  if [[ ! -f "${HOME}/.openclaw/openclaw.json" || "${FORCE_OPENCLAW_ONBOARD:-0}" == "1" ]]; then
    openclaw onboard --non-interactive \
      --mode local \
      --auth-choice "${openclaw_auth_choice}" \
      --gateway-port "${OPENCLAW_PORT}" \
      --gateway-bind loopback \
      --gateway-auth token \
      --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
      --install-daemon \
      --daemon-runtime node \
      --skip-skills \
      "${openclaw_extra_args[@]}"
  fi

  local openclaw_bin
  openclaw_bin="$(command -v openclaw)"

  log "Configuring OpenClaw for Tailscale Serve auth and allowed origin"
  configure_openclaw_tailscale_auth "https://${ts_dns_name}"

  mkdir -p "$HOME/.config/systemd/user"

  log "Installing OpenClaw user service"
  cat >"$HOME/.config/systemd/user/openclaw-gateway.service" <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=-%h/.openclaw/.env
Environment=PATH=$(systemd_path)
ExecStart=${openclaw_bin} gateway --port ${OPENCLAW_PORT} --bind loopback
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now openclaw-gateway.service

  log "Publishing OpenClaw over Tailscale Serve on port 443"
  sudo tailscale serve --https=443 off 2>/dev/null || true
  sudo tailscale serve --https=443 --bg "http://127.0.0.1:${OPENCLAW_PORT}"

  echo "OpenClaw:  https://${ts_dns_name}/"
  echo "OpenClaw dashboard: run 'openclaw dashboard' for the correct first-access link."
  echo "OpenClaw local token fallback: grep '^OPENCLAW_GATEWAY_TOKEN=' ~/.openclaw/.env"
}

install_paperclip() {
  local ts_dns_name
  ts_dns_name="$(resolve_tailscale_dns)"

  log "Installing apt packages for Paperclip"
  sudo apt-get update
  sudo apt-get install -y postgresql postgresql-contrib

  log "Enabling pnpm"
  ensure_pnpm

  log "Installing global Paperclip CLI wrapper"
  sudo tee /usr/local/bin/paperclipai-local >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:\$PATH"
if [[ -f "${PAPERCLIP_ENV_FILE}" ]]; then
  set -a
  source "${PAPERCLIP_ENV_FILE}"
  set +a
fi
cd "${PAPERCLIP_REPO_DIR}"
exec "${HOME}/.npm-global/bin/pnpm" paperclipai "\$@"
EOF
  sudo chmod 755 /usr/local/bin/paperclipai-local

  log "Preparing Paperclip environment"
  mkdir -p "$(dirname "${PAPERCLIP_ENV_FILE}")"
  touch "${PAPERCLIP_ENV_FILE}"

  ensure_secret "${PAPERCLIP_ENV_FILE}" "PAPERCLIP_DB_PASSWORD"
  ensure_secret "${PAPERCLIP_ENV_FILE}" "BETTER_AUTH_SECRET"
  ensure_line "${PAPERCLIP_ENV_FILE}" "HOST" "127.0.0.1"
  ensure_line "${PAPERCLIP_ENV_FILE}" "PORT" "${PAPERCLIP_APP_PORT}"
  ensure_line "${PAPERCLIP_ENV_FILE}" "SERVE_UI" "true"
  ensure_line "${PAPERCLIP_ENV_FILE}" "PAPERCLIP_HOME" "${HOME}/.paperclip"
  ensure_line "${PAPERCLIP_ENV_FILE}" "PAPERCLIP_INSTANCE_ID" "default"
  ensure_line "${PAPERCLIP_ENV_FILE}" "PAPERCLIP_DEPLOYMENT_MODE" "authenticated"
  ensure_line "${PAPERCLIP_ENV_FILE}" "PAPERCLIP_DEPLOYMENT_EXPOSURE" "private"
  ensure_line "${PAPERCLIP_ENV_FILE}" "PAPERCLIP_PUBLIC_URL" "https://${ts_dns_name}:${PAPERCLIP_SERVE_PORT}"
  ensure_line "${PAPERCLIP_ENV_FILE}" "PAPERCLIP_ALLOWED_HOSTNAMES" "${ts_dns_name},$(hostname --short)"
  ensure_line "${PAPERCLIP_ENV_FILE}" "PATH" "$(systemd_path)"

  local paperclip_db_password
  paperclip_db_password="$(current_env_value "${PAPERCLIP_ENV_FILE}" "PAPERCLIP_DB_PASSWORD")"
  local database_url="postgres://${PAPERCLIP_DB_USER}:${paperclip_db_password}@localhost:5432/${PAPERCLIP_DB_NAME}"
  ensure_line "${PAPERCLIP_ENV_FILE}" "DATABASE_URL" "${database_url}"

  log "Creating dedicated PostgreSQL role and database for Paperclip"
  sudo systemctl enable --now postgresql
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PAPERCLIP_DB_USER}') THEN
    CREATE ROLE ${PAPERCLIP_DB_USER} LOGIN PASSWORD '${paperclip_db_password}';
  ELSE
    ALTER ROLE ${PAPERCLIP_DB_USER} WITH LOGIN PASSWORD '${paperclip_db_password}';
  END IF;
END
\$\$;
EOF

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PAPERCLIP_DB_NAME}'" | grep -q 1; then
    sudo -u postgres createdb -O "${PAPERCLIP_DB_USER}" "${PAPERCLIP_DB_NAME}"
  fi

  log "Cloning or updating Paperclip"
  mkdir -p "$(dirname "${PAPERCLIP_REPO_DIR}")"
  if [[ ! -d "${PAPERCLIP_REPO_DIR}/.git" ]]; then
    git clone "${PAPERCLIP_REPO_URL}" "${PAPERCLIP_REPO_DIR}"
  else
    git -C "${PAPERCLIP_REPO_DIR}" fetch --all --prune
    git -C "${PAPERCLIP_REPO_DIR}" pull --ff-only
  fi

  log "Installing and building Paperclip"
  cd "${PAPERCLIP_REPO_DIR}"
  pnpm install --frozen-lockfile
  pnpm --filter @paperclipai/db generate
  pnpm build
  ./scripts/prepare-server-ui-dist.sh
  pnpm --filter @paperclipai/server build

  log "Preparing Paperclip home directories"
  mkdir -p "${HOME}/.paperclip/instances/default"

  log "Installing Paperclip user service"
  cat >"$HOME/.config/systemd/user/paperclip.service" <<EOF
[Unit]
Description=Paperclip
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=%h/.config/paperclip/paperclip.env
WorkingDirectory=${PAPERCLIP_REPO_DIR}
Environment=PATH=$(systemd_path)
ExecStart=/usr/bin/env bash -lc 'node --import ./server/node_modules/tsx/dist/loader.mjs packages/db/dist/migrate.js && exec node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js'
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now paperclip.service

  log "Aligning persisted Paperclip config with authenticated/private deployment"
  configure_paperclip_instance_config \
    "https://${ts_dns_name}:${PAPERCLIP_SERVE_PORT}" \
    "${ts_dns_name},$(hostname --short)" \
    "${database_url}"
  systemctl --user restart paperclip.service

  log "Publishing Paperclip over Tailscale Serve on port ${PAPERCLIP_SERVE_PORT}"
  sudo tailscale serve --https="${PAPERCLIP_SERVE_PORT}" off 2>/dev/null || true
  sudo tailscale serve --https="${PAPERCLIP_SERVE_PORT}" --bg "http://127.0.0.1:${PAPERCLIP_APP_PORT}"

  echo "Paperclip: https://${ts_dns_name}:${PAPERCLIP_SERVE_PORT}/"
  echo "Paperclip onboarding: open the Paperclip URL in your browser and complete onboarding there."
  echo "Paperclip CEO bootstrap: /usr/local/bin/paperclipai-local auth bootstrap-ceo"
}

install_hermes() {
  log "Installing apt packages for Hermes Agent"
  sudo apt-get update
  sudo apt-get install -y \
    git \
    curl \
    python3 \
    python3-venv

  log "Running upstream Hermes Agent installer"
  curl -fsSL "${HERMES_INSTALL_URL}" | bash

  if ! command -v hermes >/dev/null 2>&1; then
    echo "Hermes was not found after installation."
    exit 1
  fi

  local hermes_bin
  hermes_bin="$(command -v hermes)"

  log "Installing Hermes gateway user service (disabled by default)"
  mkdir -p "$HOME/.config/systemd/user"
  cat >"$HOME/.config/systemd/user/hermes-gateway.service" <<EOF
[Unit]
Description=Hermes Agent Messaging Gateway
After=network-online.target
Wants=network-online.target

[Service]
Environment=PATH=$(systemd_path)
ExecStart=${hermes_bin} gateway start
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload

  echo "Hermes Agent installed."
  echo "Next steps:"
  echo "  hermes                                                      # start interactive TUI"
  echo "  hermes setup                                                # run the full setup wizard"
  echo "  hermes gateway setup                                        # configure messaging platforms"
  echo "  systemctl --user enable --now hermes-gateway.service        # start the messaging gateway daemon"
  echo "  hermes claw migrate --dry-run                               # optional: preview OpenClaw import"
  echo "  hermes doctor                                               # diagnose issues"
}

print_shell_hint() {
  echo ""
  echo "If newly installed commands are not found in this shell yet, run:"
  echo '  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"'
}

# ── Argument parsing ──────────────────────────────────────────────────────────

TARGET="${1:-}"

case "${TARGET}" in
  --help|-h)
    usage
    exit 0
    ;;

  toolchain)
    log "Collecting setup values"
    # No app-specific prompts for toolchain — all values are env-overridable.
    install_toolchain
    log "Done"
    echo "Codex onboarding:  codex"
    echo "Claude onboarding: claude"
    print_shell_hint
    ;;

  openclaw)
    require_toolchain
    log "Collecting setup values"
    OPENCLAW_PORT="$(prompt_with_default "OpenClaw local port" "${OPENCLAW_PORT}")"
    OPENAI_API_KEY="$(prompt_optional_secret "OpenAI API key for OpenClaw onboarding" "${OPENAI_API_KEY:-}")"
    install_openclaw
    log "Done"
    print_shell_hint
    ;;

  paperclip)
    require_toolchain
    log "Collecting setup values"
    PAPERCLIP_APP_PORT="$(prompt_with_default "Paperclip local port" "${PAPERCLIP_APP_PORT}")"
    PAPERCLIP_SERVE_PORT="$(prompt_with_default "Paperclip Tailscale Serve HTTPS port" "${PAPERCLIP_SERVE_PORT}")"
    PAPERCLIP_DB_NAME="$(prompt_with_default "Paperclip PostgreSQL database name" "${PAPERCLIP_DB_NAME}")"
    PAPERCLIP_DB_USER="$(prompt_with_default "Paperclip PostgreSQL role name" "${PAPERCLIP_DB_USER}")"
    install_paperclip
    log "Done"
    print_shell_hint
    ;;

  hermes)
    require_toolchain
    install_hermes
    log "Done"
    print_shell_hint
    ;;

  all)
    # Collect all prompts upfront before any work begins.
    log "Collecting setup values"
    OPENCLAW_PORT="$(prompt_with_default "OpenClaw local port" "${OPENCLAW_PORT}")"
    PAPERCLIP_APP_PORT="$(prompt_with_default "Paperclip local port" "${PAPERCLIP_APP_PORT}")"
    PAPERCLIP_SERVE_PORT="$(prompt_with_default "Paperclip Tailscale Serve HTTPS port" "${PAPERCLIP_SERVE_PORT}")"
    PAPERCLIP_DB_NAME="$(prompt_with_default "Paperclip PostgreSQL database name" "${PAPERCLIP_DB_NAME}")"
    PAPERCLIP_DB_USER="$(prompt_with_default "Paperclip PostgreSQL role name" "${PAPERCLIP_DB_USER}")"
    OPENAI_API_KEY="$(prompt_optional_secret "OpenAI API key for OpenClaw onboarding" "${OPENAI_API_KEY:-}")"
    install_toolchain
    brew_shellenv
    export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
    install_openclaw
    install_paperclip
    log "Done"
    check_dns_health "platform.claude.com" || true
    echo "Codex onboarding:  codex"
    echo "Claude onboarding: claude"
    print_shell_hint
    ;;

  "")
    # No arg — interactive picker.
    echo ""
    echo "What would you like to install?"
    echo "  1) Everything: toolchain + OpenClaw + Paperclip (default)"
    echo "  2) Toolchain only  (Homebrew, Node, Codex, Claude Code)"
    echo "  3) OpenClaw only   (requires toolchain already installed)"
    echo "  4) Paperclip only  (requires toolchain already installed)"
    echo ""
    read -r -p "Choice [1]: " CHOICE
    CHOICE="${CHOICE:-1}"

    case "${CHOICE}" in
      1)
        log "Collecting setup values"
        OPENCLAW_PORT="$(prompt_with_default "OpenClaw local port" "${OPENCLAW_PORT}")"
        PAPERCLIP_APP_PORT="$(prompt_with_default "Paperclip local port" "${PAPERCLIP_APP_PORT}")"
        PAPERCLIP_SERVE_PORT="$(prompt_with_default "Paperclip Tailscale Serve HTTPS port" "${PAPERCLIP_SERVE_PORT}")"
        PAPERCLIP_DB_NAME="$(prompt_with_default "Paperclip PostgreSQL database name" "${PAPERCLIP_DB_NAME}")"
        PAPERCLIP_DB_USER="$(prompt_with_default "Paperclip PostgreSQL role name" "${PAPERCLIP_DB_USER}")"
        OPENAI_API_KEY="$(prompt_optional_secret "OpenAI API key for OpenClaw onboarding" "${OPENAI_API_KEY:-}")"
        install_toolchain
        brew_shellenv
        export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
        install_openclaw
        install_paperclip
        log "Done"
        check_dns_health "platform.claude.com" || true
        echo "Codex onboarding:  codex"
        echo "Claude onboarding: claude"
        print_shell_hint
        ;;
      2)
        install_toolchain
        log "Done"
        echo "Codex onboarding:  codex"
        echo "Claude onboarding: claude"
        print_shell_hint
        ;;
      3)
        require_toolchain
        log "Collecting setup values"
        OPENCLAW_PORT="$(prompt_with_default "OpenClaw local port" "${OPENCLAW_PORT}")"
        OPENAI_API_KEY="$(prompt_optional_secret "OpenAI API key for OpenClaw onboarding" "${OPENAI_API_KEY:-}")"
        install_openclaw
        log "Done"
        print_shell_hint
        ;;
      4)
        require_toolchain
        log "Collecting setup values"
        PAPERCLIP_APP_PORT="$(prompt_with_default "Paperclip local port" "${PAPERCLIP_APP_PORT}")"
        PAPERCLIP_SERVE_PORT="$(prompt_with_default "Paperclip Tailscale Serve HTTPS port" "${PAPERCLIP_SERVE_PORT}")"
        PAPERCLIP_DB_NAME="$(prompt_with_default "Paperclip PostgreSQL database name" "${PAPERCLIP_DB_NAME}")"
        PAPERCLIP_DB_USER="$(prompt_with_default "Paperclip PostgreSQL role name" "${PAPERCLIP_DB_USER}")"
        install_paperclip
        log "Done"
        print_shell_hint
        ;;
      *)
        echo "Invalid choice: ${CHOICE}"
        usage
        exit 1
        ;;
    esac
    ;;

  *)
    echo "Unknown target: ${TARGET}"
    usage
    exit 1
    ;;
esac
