#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./install-second-brain.sh            # interactive prompts
#   ./install-second-brain.sh --help
#
# Sets up the "second brain" workspace described by seintun.dev:
#
#   • Workspace directory tree (docs, memory, projects, scripts, config, tmp, assets)
#   • OpenClaw gateway patched for per-channel-peer session scope
#   • Telegram channel configured with DM-pairing and mention-gating
#   • OpenRouter added as a fallback provider (optional)
#   • Three-layer memory directory scaffold
#   • Minimal Node.js monitoring dashboard at ~/brain/projects/openclaw-monitor
#   • Tailscale Serve publishes the monitor dashboard on a private HTTPS port
#
# Prerequisites:
#   - Stage 1 (bootstrap-root.sh) complete  — Tailscale is up
#   - Stage 2 (install-apps.sh toolchain + openclaw) complete — OpenClaw
#     gateway is running as a user service

BRAIN_DIR="${BRAIN_DIR:-$HOME/brain}"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_ENV_FILE="${OPENCLAW_ENV_FILE:-$HOME/.openclaw/.env}"
OPENCLAW_GATEWAY_UNIT="${OPENCLAW_GATEWAY_UNIT:-$HOME/.config/systemd/user/openclaw-gateway.service}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
MONITOR_PORT="${MONITOR_PORT:-3090}"
MONITOR_SERVE_PORT="${MONITOR_SERVE_PORT:-7444}"
MONITOR_DIR="${MONITOR_DIR:-${BRAIN_DIR}/projects/openclaw-monitor}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as a non-root user, not root."
  exit 1
fi

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

# ── Helper functions ──────────────────────────────────────────────────────────

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

prompt_with_default() {
  local prompt="$1"
  local current="$2"
  local reply
  read -r -p "${prompt} [${current}]: " reply
  printf '%s' "${reply:-${current}}"
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
  printf '%s' "${reply:-${current}}"
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
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  if grep -q "^${key}=" "${file}"; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

current_env_value() {
  local file="$1" key="$2"
  if [[ -f "${file}" ]]; then
    awk -F= -v k="${key}" '$1 == k {print substr($0, index($0, "=") + 1)}' "${file}" | tail -n 1
  fi
}

ensure_secret() {
  local file="$1" key="$2"
  local existing
  existing="$(current_env_value "${file}" "${key}")"
  if [[ -z "${existing}" ]]; then
    ensure_line "${file}" "${key}" "$(openssl rand -hex 32)"
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

require_node() {
  brew_shellenv
  export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
  if ! command -v node >/dev/null 2>&1; then
    echo "Node not found. Run './install-apps.sh toolchain' first."
    exit 1
  fi
}

# ── Usage ─────────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
Usage: $(basename "$0")

Sets up a "second brain" workspace around OpenClaw on a Tailscale-connected VPS.

Requires: toolchain + OpenClaw already installed (install-apps.sh).

Environment variable overrides:
  BRAIN_DIR            Workspace root           (default: ~/brain)
  MONITOR_PORT         Monitor local HTTP port  (default: 3090)
  MONITOR_SERVE_PORT   Tailscale Serve HTTPS    (default: 7444)
  OPENCLAW_PORT        OpenClaw gateway port    (default: 18789)
  OPENCLAW_CONFIG_FILE Override OpenClaw config path
  OPENCLAW_ENV_FILE    Override OpenClaw .env path
  TELEGRAM_BOT_TOKEN   Skip the prompt for the Telegram bot token
  OPENROUTER_API_KEY   Skip the prompt for the OpenRouter API key
EOF
  exit 0
fi

# ── Collect prompts upfront ───────────────────────────────────────────────────

log "Collecting setup values"

BRAIN_DIR="$(prompt_with_default "Workspace root directory" "${BRAIN_DIR}")"
MONITOR_PORT="$(prompt_with_default "Monitor local port" "${MONITOR_PORT}")"
MONITOR_SERVE_PORT="$(prompt_with_default "Monitor Tailscale Serve HTTPS port" "${MONITOR_SERVE_PORT}")"
MONITOR_DIR="${MONITOR_DIR:-${BRAIN_DIR}/projects/openclaw-monitor}"
TELEGRAM_BOT_TOKEN="$(prompt_optional_secret "Telegram bot token (from @BotFather)" "${TELEGRAM_BOT_TOKEN:-}")"
OPENROUTER_API_KEY="$(prompt_optional_secret "OpenRouter API key (fallback provider)" "${OPENROUTER_API_KEY:-}")"

# ── Pre-flight ────────────────────────────────────────────────────────────────

require_openclaw
require_node

TS_DNS_NAME="$(resolve_tailscale_dns)"
MONITOR_ORIGIN="https://${TS_DNS_NAME}:${MONITOR_SERVE_PORT}"

# ── Workspace directory structure ─────────────────────────────────────────────

log "Creating workspace directory tree at ${BRAIN_DIR}"

mkdir -p \
  "${BRAIN_DIR}/docs" \
  "${BRAIN_DIR}/docs/security" \
  "${BRAIN_DIR}/memory/context" \
  "${BRAIN_DIR}/memory/layers" \
  "${BRAIN_DIR}/memory/sessions" \
  "${BRAIN_DIR}/projects/openclaw-monitor" \
  "${BRAIN_DIR}/scripts" \
  "${BRAIN_DIR}/config/patches" \
  "${BRAIN_DIR}/tmp" \
  "${BRAIN_DIR}/assets"

# Gitignore tmp and session dumps so they never accidentally get committed.
cat > "${BRAIN_DIR}/.gitignore" <<'EOF'
tmp/
memory/sessions/
*.env
EOF

echo "Workspace created at ${BRAIN_DIR}"

# ── Patch OpenClaw config ─────────────────────────────────────────────────────

log "Patching OpenClaw config for second-brain settings"

TMP_CONFIG="$(mktemp)"

jq '
  .gateway = (.gateway // {}) |
  .gateway.bind = "loopback" |
  .gateway.session = (.gateway.session // {}) |
  .gateway.session.scope = "per-channel-peer" |
  .gateway.auth = (.gateway.auth // {}) |
  .gateway.auth.mode = "token"
' "${OPENCLAW_CONFIG_FILE}" > "${TMP_CONFIG}"

# Add Telegram channel if a bot token was provided.
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  jq \
    --arg token "${TELEGRAM_BOT_TOKEN}" \
    '
      .channels = (.channels // {}) |
      .channels.telegram = (.channels.telegram // {}) |
      .channels.telegram.botToken = $token |
      .channels.telegram.pairing = "dm-only" |
      .channels.telegram.groups = (.channels.telegram.groups // {}) |
      .channels.telegram.groups.mentionGating = true
    ' "${TMP_CONFIG}" > "${TMP_CONFIG}.2"
  mv "${TMP_CONFIG}.2" "${TMP_CONFIG}"
  echo "Telegram channel configured (DM pairing, mention-gating for groups)."
else
  echo "No Telegram bot token provided — skipping Telegram channel config."
  echo "To add it later, set channels.telegram.botToken in ${OPENCLAW_CONFIG_FILE}"
fi

# Add OpenRouter as a fallback provider if a key was provided.
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  jq \
    --arg key "${OPENROUTER_API_KEY}" \
    '
      .providers = (.providers // {}) |
      .providers.fallback = (.providers.fallback // {}) |
      .providers.fallback.type = "openrouter" |
      .providers.fallback.apiKey = $key |
      .providers.fallback.rotateProfiles = true
    ' "${TMP_CONFIG}" > "${TMP_CONFIG}.2"
  mv "${TMP_CONFIG}.2" "${TMP_CONFIG}"

  # Also write the key into the OpenClaw .env so the service picks it up.
  ensure_line "${OPENCLAW_ENV_FILE}" "OPENROUTER_API_KEY" "${OPENROUTER_API_KEY}"
  echo "OpenRouter fallback provider configured."
else
  echo "No OpenRouter API key provided — skipping fallback provider config."
fi

mv "${TMP_CONFIG}" "${OPENCLAW_CONFIG_FILE}"

log "Restarting OpenClaw gateway to apply updated config"
systemctl --user restart openclaw-gateway.service

# ── Monitor dashboard ─────────────────────────────────────────────────────────
#
# Lightweight Node.js + Express server that proxies OpenClaw session data and
# reports basic system stats. Designed to be read-only and served privately
# over Tailscale Serve.

log "Scaffolding monitor dashboard at ${MONITOR_DIR}"

MONITOR_ENV_FILE="${MONITOR_DIR}/.env"
GATEWAY_TOKEN=""

# Read the gateway token — same precedence order as install-nerve.sh.
if [[ -f "${OPENCLAW_GATEWAY_UNIT}" ]]; then
  GATEWAY_TOKEN="$(grep -oP '(?<=OPENCLAW_GATEWAY_TOKEN=)\S+' "${OPENCLAW_GATEWAY_UNIT}" | tail -n 1 || true)"
fi
if [[ -z "${GATEWAY_TOKEN}" && -f "${OPENCLAW_ENV_FILE}" ]]; then
  GATEWAY_TOKEN="$(current_env_value "${OPENCLAW_ENV_FILE}" "OPENCLAW_GATEWAY_TOKEN")"
fi
if [[ -z "${GATEWAY_TOKEN}" ]]; then
  echo "Could not locate OPENCLAW_GATEWAY_TOKEN — monitor will need GATEWAY_TOKEN set manually in ${MONITOR_ENV_FILE}."
fi

mkdir -p "${MONITOR_DIR}"

# .env
touch "${MONITOR_ENV_FILE}"
chmod 600 "${MONITOR_ENV_FILE}"
ensure_line "${MONITOR_ENV_FILE}" "HOST"          "127.0.0.1"
ensure_line "${MONITOR_ENV_FILE}" "PORT"          "${MONITOR_PORT}"
ensure_line "${MONITOR_ENV_FILE}" "GATEWAY_URL"   "http://127.0.0.1:${OPENCLAW_PORT}"
ensure_line "${MONITOR_ENV_FILE}" "GATEWAY_TOKEN" "${GATEWAY_TOKEN}"
ensure_secret "${MONITOR_ENV_FILE}" "SESSION_SECRET"

# package.json
cat > "${MONITOR_DIR}/package.json" <<'EOF'
{
  "name": "openclaw-monitor",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.19.2"
  }
}
EOF

# server.js — minimal dashboard backend
cat > "${MONITOR_DIR}/server.js" <<'JSEOF'
import express from "express";
import { execSync } from "child_process";
import { createServer } from "http";

const {
  HOST = "127.0.0.1",
  PORT = "3090",
  GATEWAY_URL = "http://127.0.0.1:18789",
  GATEWAY_TOKEN = "",
} = process.env;

const app = express();

function sysStats() {
  try {
    const uptime = Number(execSync("cat /proc/uptime", { encoding: "utf8" }).split(" ")[0]);
    const loadavg = execSync("cat /proc/loadavg", { encoding: "utf8" }).trim().split(" ").slice(0, 3);
    const memRaw = execSync("free -m", { encoding: "utf8" }).split("\n")[1].split(/\s+/);
    return {
      uptimeSeconds: Math.round(uptime),
      load: loadavg.map(Number),
      memTotalMB: Number(memRaw[1]),
      memUsedMB: Number(memRaw[2]),
    };
  } catch {
    return null;
  }
}

async function gatewayStatus() {
  if (!GATEWAY_TOKEN) return { error: "no token configured" };
  try {
    const res = await fetch(`${GATEWAY_URL}/api/status`, {
      headers: { Authorization: `Bearer ${GATEWAY_TOKEN}` },
      signal: AbortSignal.timeout(3000),
    });
    if (!res.ok) return { error: `gateway returned ${res.status}` };
    return res.json();
  } catch (err) {
    return { error: String(err.message ?? err) };
  }
}

app.get("/health", (_req, res) => res.json({ ok: true }));

app.get("/api/stats", async (_req, res) => {
  const [sys, gateway] = await Promise.all([sysStats(), gatewayStatus()]);
  res.json({ timestamp: new Date().toISOString(), system: sys, gateway });
});

// Minimal HTML dashboard — no build step needed.
app.get("/", (_req, res) => {
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.end(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpenClaw Monitor</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: ui-monospace, monospace; background: #0d0d0d; color: #e2e8f0; padding: 2rem; }
    h1 { font-size: 1.25rem; color: #94a3b8; margin-bottom: 1.5rem; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; }
    .card { background: #1e1e2e; border: 1px solid #2e2e3e; border-radius: 8px; padding: 1rem; }
    .card h2 { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: #64748b; margin-bottom: 0.75rem; }
    pre { font-size: 0.8rem; line-height: 1.6; white-space: pre-wrap; word-break: break-all; }
    .ok { color: #4ade80; }
    .err { color: #f87171; }
    footer { margin-top: 2rem; font-size: 0.7rem; color: #475569; }
  </style>
</head>
<body>
  <h1>OpenClaw Monitor</h1>
  <div class="grid" id="grid"><p style="color:#475569">Loading…</p></div>
  <footer id="ts"></footer>
  <script>
    async function refresh() {
      const data = await fetch('/api/stats').then(r => r.json()).catch(e => ({ error: String(e) }));
      const ts = new Date(data.timestamp ?? Date.now()).toLocaleTimeString();
      document.getElementById('ts').textContent = 'Last updated: ' + ts;
      const g = document.getElementById('grid');
      g.innerHTML = '';
      const sys = data.system;
      if (sys) {
        const h = Math.floor(sys.uptimeSeconds / 3600);
        const m = Math.floor((sys.uptimeSeconds % 3600) / 60);
        g.innerHTML += '<div class="card"><h2>System</h2><pre>'
          + 'Uptime : ' + h + 'h ' + m + 'm\n'
          + 'Load   : ' + sys.load.join(' / ') + '\n'
          + 'Memory : ' + sys.memUsedMB + ' / ' + sys.memTotalMB + ' MB'
          + '</pre></div>';
      }
      const gw = data.gateway;
      const cls = gw && !gw.error ? 'ok' : 'err';
      g.innerHTML += '<div class="card"><h2>Gateway</h2><pre class="' + cls + '">'
        + JSON.stringify(gw, null, 2)
        + '</pre></div>';
    }
    refresh();
    setInterval(refresh, 10000);
  </script>
</body>
</html>`);
});

const server = createServer(app);
server.listen(Number(PORT), HOST, () => {
  console.log(`openclaw-monitor listening on http://${HOST}:${PORT}`);
});
JSEOF

log "Installing monitor dependencies"
cd "${MONITOR_DIR}"
npm install

# ── Systemd user service ──────────────────────────────────────────────────────

log "Installing monitor user service"
NODE_BIN="$(command -v node)"

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/openclaw-monitor.service" <<EOF
[Unit]
Description=OpenClaw Monitor Dashboard
After=network-online.target openclaw-gateway.service
Wants=network-online.target

[Service]
EnvironmentFile=${MONITOR_ENV_FILE}
WorkingDirectory=${MONITOR_DIR}
Environment=PATH=$(systemd_path)
ExecStart=${NODE_BIN} ${MONITOR_DIR}/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now openclaw-monitor.service

# ── Tailscale Serve ───────────────────────────────────────────────────────────

log "Publishing monitor over Tailscale Serve on port ${MONITOR_SERVE_PORT}"
sudo tailscale serve --https="${MONITOR_SERVE_PORT}" off 2>/dev/null || true
sudo tailscale serve --https="${MONITOR_SERVE_PORT}" --bg "http://127.0.0.1:${MONITOR_PORT}"
sudo tailscale serve status || true

# ── Health check ──────────────────────────────────────────────────────────────

log "Waiting for monitor to come up"
ATTEMPTS=0
until curl -fsS "http://127.0.0.1:${MONITOR_PORT}/health" >/dev/null 2>&1; do
  ATTEMPTS=$(( ATTEMPTS + 1 ))
  if [[ "${ATTEMPTS}" -ge 20 ]]; then
    echo "Monitor did not respond at http://127.0.0.1:${MONITOR_PORT}/health after ${ATTEMPTS} attempts."
    echo "Check service logs: journalctl --user -u openclaw-monitor.service -n 50"
    exit 1
  fi
  sleep 2
done

# ── Done ──────────────────────────────────────────────────────────────────────

log "Done"
echo ""
echo "Workspace:  ${BRAIN_DIR}/"
echo ""
echo "  docs/               plans, articles, reference"
echo "  docs/security/      hardening notes"
echo "  memory/context/     rolling conversation context"
echo "  memory/layers/      persistent OpenClaw memory layers"
echo "  memory/sessions/    session transcript dumps (git-ignored)"
echo "  projects/           working artifacts"
echo "  scripts/            maintenance tasks"
echo "  config/patches/     reusable config overlays"
echo "  tmp/                disposable output (git-ignored)"
echo "  assets/             static files"
echo ""
echo "Monitor:    ${MONITOR_ORIGIN}/"
echo ""
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "Telegram:   start a DM with your bot to pair a session."
fi
echo ""
echo "Service management:"
echo "  systemctl --user status  openclaw-monitor.service"
echo "  journalctl --user -u openclaw-monitor.service -f"
echo ""
echo "To add Telegram later, set channels.telegram.botToken in:"
echo "  ${OPENCLAW_CONFIG_FILE}"
echo "Then: systemctl --user restart openclaw-gateway.service"
