#!/usr/bin/env bash
set -euo pipefail

NETDATA_KICKSTART_URL="${NETDATA_KICKSTART_URL:-https://get.netdata.cloud/kickstart.sh}"
NETDATA_RELEASE_CHANNEL="${NETDATA_RELEASE_CHANNEL:-stable}"
NETDATA_AUTO_UPDATES="${NETDATA_AUTO_UPDATES:-no}"
NETDATA_TELEMETRY="${NETDATA_TELEMETRY:-no}"
NETDATA_LISTEN_PORT="${NETDATA_LISTEN_PORT:-19999}"
NETDATA_TAILSCALE_PORT="${NETDATA_TAILSCALE_PORT:-19999}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as a non-root user, not root."
  exit 1
fi

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

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Required command not found: ${cmd}"
    exit 1
  fi
}

log "Collecting Netdata setup values"
NETDATA_RELEASE_CHANNEL="$(prompt_with_default "Netdata release channel (stable/nightly)" "${NETDATA_RELEASE_CHANNEL}")"
NETDATA_AUTO_UPDATES="$(prompt_with_default "Enable Netdata auto-updates (yes/no)" "${NETDATA_AUTO_UPDATES}")"
NETDATA_TELEMETRY="$(prompt_with_default "Enable Netdata anonymous telemetry (yes/no)" "${NETDATA_TELEMETRY}")"
NETDATA_TAILSCALE_PORT="$(prompt_with_default "Tailscale HTTPS port for Netdata" "${NETDATA_TAILSCALE_PORT}")"

require_command curl
require_command sudo
require_command tailscale
require_command systemctl

log "Installing packages Netdata may need"
sudo apt-get update
sudo apt-get install -y curl ca-certificates jq

log "Checking Tailscale status"
TS_DNS_NAME="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
if [[ -z "${TS_DNS_NAME}" ]]; then
  echo "Could not determine Tailscale DNS name. Make sure Tailscale is connected first."
  exit 1
fi

log "Downloading Netdata kickstart"
TMP_SCRIPT="$(mktemp)"
trap 'rm -f "${TMP_SCRIPT}"' EXIT
curl -fsSL "${NETDATA_KICKSTART_URL}" -o "${TMP_SCRIPT}"

INSTALL_ARGS=(--non-interactive --release-channel "${NETDATA_RELEASE_CHANNEL}")

if [[ "${NETDATA_AUTO_UPDATES}" == "yes" ]]; then
  INSTALL_ARGS+=(--auto-update)
else
  INSTALL_ARGS+=(--no-updates)
fi

if [[ "${NETDATA_TELEMETRY}" == "yes" ]]; then
  sudo env DISABLE_TELEMETRY=0 sh "${TMP_SCRIPT}" "${INSTALL_ARGS[@]}"
else
  sudo env DISABLE_TELEMETRY=1 sh "${TMP_SCRIPT}" "${INSTALL_ARGS[@]}"
fi

log "Configuring Netdata for localhost-only access"
sudo mkdir -p /etc/netdata
if [[ -f /etc/netdata/netdata.conf && ! -f /etc/netdata/netdata.conf.bak ]]; then
  sudo cp /etc/netdata/netdata.conf /etc/netdata/netdata.conf.bak
fi

sudo tee /etc/netdata/netdata.conf >/dev/null <<EOF
[web]
    bind to = 127.0.0.1 ::1
    default port = ${NETDATA_LISTEN_PORT}
    allow connections from = localhost
    allow dashboard from = localhost
    allow management from = localhost
EOF

log "Restarting Netdata"
sudo systemctl enable --now netdata
sudo systemctl restart netdata

log "Publishing Netdata over Tailscale Serve on port ${NETDATA_TAILSCALE_PORT}"
sudo tailscale serve --https="${NETDATA_TAILSCALE_PORT}" off 2>/dev/null || true
sudo tailscale serve --https="${NETDATA_TAILSCALE_PORT}" --bg "http://127.0.0.1:${NETDATA_LISTEN_PORT}"

log "Done"
echo "Netdata local:    http://127.0.0.1:${NETDATA_LISTEN_PORT}"
echo "Netdata Tailscale: https://${TS_DNS_NAME}:${NETDATA_TAILSCALE_PORT}/"
echo "Verify service:    sudo systemctl status netdata --no-pager"
echo "Verify serve:      sudo tailscale serve status"
