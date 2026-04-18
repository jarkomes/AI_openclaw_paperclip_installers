#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./install-nerve.sh            # interactive prompts
#   ./install-nerve.sh --help
#
# Installs Nerve (the OpenClaw web UI) in cloud mode — Nerve and the
# OpenClaw gateway run on the same VPS, Nerve is kept on loopback, and
# Tailscale Serve publishes it over a private HTTPS URL.
#
# Prerequisites:
#   - Stage 1 (bootstrap-root.sh) complete  — Tailscale is up
#   - Stage 2 (install-apps.sh toolchain + openclaw) complete — OpenClaw
#     gateway is running as a user service

NERVE_INSTALL_URL="${NERVE_INSTALL_URL:-https://raw.githubusercontent.com/daggerhashimoto/openclaw-nerve/master/install.sh}"
NERVE_REPO_DIR="${NERVE_REPO_DIR:-$HOME/nerve}"
NERVE_PORT="${NERVE_PORT:-3080}"
NERVE_SERVE_PORT="${NERVE_SERVE_PORT:-7443}"
NERVE_ENV_FILE="${NERVE_ENV_FILE:-${NERVE_REPO_DIR}/.env}"
OPENCLAW_ENV_FILE="${OPENCLAW_ENV_FILE:-$HOME/.openclaw/.env}"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_GATEWAY_UNIT="${OPENCLAW_GATEWAY_UNIT:-$HOME/.config/systemd/user/openclaw-gateway.service}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
AGENT_NAME="${AGENT_NAME:-Agent}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as a non-root user, not root."
  exit 1
fi

export PATH="$HOME/.local/bin:$PATH"

# ── Helper functions ──────────────────────────────────────────────────────────

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

ensure_secret() {
  local file="$1"
  local key="$2"
  local existing
  existing="$(current_env_value "${file}" "${key}")"
  if [[ -z "${existing}" ]]; then
    ensure_line "${file}" "${key}" "$(openssl rand -hex 32)"
  fi
}

current_env_value() {
  local file="$1"
  local key="$2"
  if [[ -f "${file}" ]]; then
    awk -F= -v k="${key}" '$1 == k {print substr($0, index($0, "=") + 1)}' "${file}" | tail -n 1
  fi
}

resolve_tailscale_dns() {
  local ts_dns_name
  ts_dns_name="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
  if [[ -z "${ts_dns_name}" ]]; then
    echo "Could not determine Tailscale DNS name. Make sure Tailscale is connected."
    exit 1
  fi
  printf '%s' "${ts_dns_name}"
}

require_toolchain() {
  brew_shellenv
  export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "Node/npm not found. Run './install-apps.sh toolchain' first."
    exit 1
  fi

  local node_version
  node_version="$(node -e 'process.stdout.write(process.version)' | sed 's/^v//')"
  local node_major
  node_major="${node_version%%.*}"
  if [[ "${node_major}" -lt 22 ]]; then
    echo "Nerve requires Node.js 22+. Installed version: ${node_version}."
    echo "Update Node via Homebrew: brew upgrade node"
    exit 1
  fi
}

require_openclaw() {
  if ! command -v openclaw >/dev/null 2>&1; then
    echo "OpenClaw CLI not found. Run './install-apps.sh openclaw' first."
    exit 1
  fi

  if [[ ! -f "${OPENCLAW_CONFIG_FILE}" ]]; then
    echo "OpenClaw config not found at ${OPENCLAW_CONFIG_FILE}."
    echo "Run './install-apps.sh openclaw' to complete OpenClaw setup first."
    exit 1
  fi
}

# Read the gateway token — systemd unit takes priority (same order the Nerve
# setup wizard uses), then falls back to the openclaw .env file.
read_gateway_token() {
  local token=""

  # 1. systemd unit env var (most reliable source — avoids the known onboard
  #    token mismatch between the unit and openclaw.json)
  if [[ -f "${OPENCLAW_GATEWAY_UNIT}" ]]; then
    token="$(grep -oP '(?<=OPENCLAW_GATEWAY_TOKEN=)\S+' "${OPENCLAW_GATEWAY_UNIT}" | tail -n 1 || true)"
  fi

  # 2. openclaw .env file
  if [[ -z "${token}" && -f "${OPENCLAW_ENV_FILE}" ]]; then
    token="$(current_env_value "${OPENCLAW_ENV_FILE}" "OPENCLAW_GATEWAY_TOKEN")"
  fi

  if [[ -z "${token}" ]]; then
    echo "Could not locate OPENCLAW_GATEWAY_TOKEN in ${OPENCLAW_GATEWAY_UNIT} or ${OPENCLAW_ENV_FILE}."
    echo "Make sure OpenClaw is installed and the gateway service exists."
    exit 1
  fi

  printf '%s' "${token}"
}

# Append Nerve's origin to gateway.controlUi.allowedOrigins without
# disturbing any origins already in the list (e.g. the Tailscale DNS name
# that openclaw onboarding wrote there earlier).
patch_openclaw_allowed_origins() {
  local origin="${1}"

  if [[ ! -f "${OPENCLAW_CONFIG_FILE}" ]]; then
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg origin "${origin}" '
    .gateway = (.gateway // {}) |
    .gateway.controlUi = (.gateway.controlUi // {}) |
    .gateway.controlUi.allowedOrigins = (
      (.gateway.controlUi.allowedOrigins // []) + [$origin]
      | unique
    )
  ' "${OPENCLAW_CONFIG_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${OPENCLAW_CONFIG_FILE}"
}

# ── Usage ─────────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
Usage: $(basename "$0")

Installs Nerve — the OpenClaw web UI — in cloud/Tailscale-Serve mode.
Nerve is kept on loopback (127.0.0.1) and published over a private
Tailscale HTTPS URL.

Requires: toolchain (install-apps.sh toolchain) and OpenClaw
          (install-apps.sh openclaw) already installed.

Environment variable overrides:
  NERVE_PORT           Nerve local HTTP port              (default: 3080)
  NERVE_SERVE_PORT     Tailscale Serve HTTPS port         (default: 7443)
  NERVE_REPO_DIR       Nerve install directory            (default: ~/nerve)
  AGENT_NAME           Agent display name in the UI       (default: Agent)
  OPENCLAW_PORT        OpenClaw gateway local port        (default: 18789)
  NERVE_INSTALL_URL    Override Nerve installer URL
  OPENCLAW_ENV_FILE    Override OpenClaw .env path
  OPENCLAW_CONFIG_FILE Override OpenClaw config path
  OPENAI_API_KEY       OpenAI key for TTS + transcription (optional)
EOF
  exit 0
fi

# ── Collect prompts upfront ───────────────────────────────────────────────────

log "Collecting setup values"

NERVE_PORT="$(prompt_with_default "Nerve local port" "${NERVE_PORT}")"
NERVE_SERVE_PORT="$(prompt_with_default "Nerve Tailscale Serve HTTPS port" "${NERVE_SERVE_PORT}")"
AGENT_NAME="$(prompt_with_default "Agent display name" "${AGENT_NAME}")"
OPENAI_API_KEY="$(prompt_optional_secret "OpenAI API key for TTS and transcription" "${OPENAI_API_KEY:-}")"

# ── Pre-flight ────────────────────────────────────────────────────────────────

require_toolchain
require_openclaw

NERVE_ENV_FILE="${NERVE_REPO_DIR}/.env"

TS_DNS_NAME="$(resolve_tailscale_dns)"
NERVE_ORIGIN="https://${TS_DNS_NAME}:${NERVE_SERVE_PORT}"

log "Installing apt packages for Nerve"
sudo apt-get update
sudo apt-get install -y ffmpeg

# ── Install Nerve ─────────────────────────────────────────────────────────────

log "Running Nerve installer (skipping interactive setup)"
curl -fsSL "${NERVE_INSTALL_URL}" | bash -s -- --dir "${NERVE_REPO_DIR}" --skip-setup

if [[ ! -d "${NERVE_REPO_DIR}" ]]; then
  echo "Nerve install directory not found at ${NERVE_REPO_DIR} after install."
  exit 1
fi

log "Installing Nerve dependencies"
cd "${NERVE_REPO_DIR}"
npm install

log "Building Nerve (frontend + server)"
npm run build

if [[ ! -f "${NERVE_REPO_DIR}/server-dist/index.js" ]]; then
  echo "Nerve build did not produce server-dist/index.js — build may have failed."
  exit 1
fi

# ── Configure Nerve .env ──────────────────────────────────────────────────────

log "Reading OpenClaw gateway token"
GATEWAY_TOKEN="$(read_gateway_token)"

log "Writing Nerve .env"
chmod 600 "${NERVE_ENV_FILE}" 2>/dev/null || touch "${NERVE_ENV_FILE}"
chmod 600 "${NERVE_ENV_FILE}"

ensure_line "${NERVE_ENV_FILE}" "HOST"               "127.0.0.1"
ensure_line "${NERVE_ENV_FILE}" "PORT"               "${NERVE_PORT}"
ensure_line "${NERVE_ENV_FILE}" "AGENT_NAME"         "${AGENT_NAME}"
ensure_line "${NERVE_ENV_FILE}" "GATEWAY_URL"        "http://127.0.0.1:${OPENCLAW_PORT}"
ensure_line "${NERVE_ENV_FILE}" "GATEWAY_TOKEN"      "${GATEWAY_TOKEN}"
ensure_line "${NERVE_ENV_FILE}" "NERVE_AUTH"         "true"
ensure_line "${NERVE_ENV_FILE}" "NERVE_PUBLIC_ORIGIN" "${NERVE_ORIGIN}"
ensure_line "${NERVE_ENV_FILE}" "ALLOWED_ORIGINS"    "${NERVE_ORIGIN}"
ensure_line "${NERVE_ENV_FILE}" "CSP_CONNECT_EXTRA"  "${NERVE_ORIGIN} wss://${TS_DNS_NAME}:${NERVE_SERVE_PORT}"
# WS connections arrive from 127.0.0.1 through Tailscale Serve — no extra
# WS_ALLOWED_HOSTS entry is needed for this mode.
ensure_secret "${NERVE_ENV_FILE}" "NERVE_SESSION_SECRET"
ensure_if_set "${NERVE_ENV_FILE}" "OPENAI_API_KEY"   "${OPENAI_API_KEY:-}"

# ── Patch OpenClaw allowedOrigins ─────────────────────────────────────────────

log "Adding Nerve origin to OpenClaw gateway allowedOrigins"
patch_openclaw_allowed_origins "${NERVE_ORIGIN}"

# ── Systemd user service ──────────────────────────────────────────────────────

log "Installing Nerve user service"
NODE_BIN="$(command -v node)"

mkdir -p "$HOME/.config/systemd/user"
cat >"$HOME/.config/systemd/user/nerve.service" <<EOF
[Unit]
Description=Nerve (OpenClaw web UI)
After=network-online.target openclaw-gateway.service
Wants=network-online.target
BindsTo=openclaw-gateway.service

[Service]
EnvironmentFile=${NERVE_ENV_FILE}
WorkingDirectory=${NERVE_REPO_DIR}
Environment=PATH=$(systemd_path)
ExecStart=${NODE_BIN} ${NERVE_REPO_DIR}/server-dist/index.js
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now nerve.service

# ── Restart OpenClaw so it picks up the new allowedOrigins ───────────────────

log "Restarting OpenClaw gateway to apply updated allowedOrigins"
systemctl --user restart openclaw-gateway.service

# ── Tailscale Serve ───────────────────────────────────────────────────────────

log "Publishing Nerve over Tailscale Serve on port ${NERVE_SERVE_PORT}"
sudo tailscale serve --https="${NERVE_SERVE_PORT}" off 2>/dev/null || true
sudo tailscale serve --https="${NERVE_SERVE_PORT}" --bg "http://127.0.0.1:${NERVE_PORT}"
sudo tailscale serve status || true

# ── Health check ──────────────────────────────────────────────────────────────

log "Waiting for Nerve to come up"
ATTEMPTS=0
until curl -fsS "http://127.0.0.1:${NERVE_PORT}/health" >/dev/null 2>&1; do
  ATTEMPTS=$(( ATTEMPTS + 1 ))
  if [[ "${ATTEMPTS}" -ge 20 ]]; then
    echo "Nerve did not respond at http://127.0.0.1:${NERVE_PORT}/health after ${ATTEMPTS} attempts."
    echo "Check service logs: journalctl --user -u nerve.service -n 50"
    exit 1
  fi
  sleep 2
done

log "Done"
echo ""
echo "Nerve:   ${NERVE_ORIGIN}/"
echo ""
echo "Login with your gateway token as the password (or the one you set during setup):"
echo "  grep '^GATEWAY_TOKEN=' ${NERVE_ENV_FILE}"
echo ""
echo "Service management:"
echo "  systemctl --user status  nerve.service"
echo "  journalctl --user -u nerve.service -f"
echo ""
echo "To update Nerve later:"
echo "  cd ${NERVE_REPO_DIR} && npm run update -- --yes"
