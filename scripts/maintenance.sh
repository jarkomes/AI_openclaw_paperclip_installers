#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./maintenance.sh                  # update everything (interactive)
#   ./maintenance.sh openclaw         # update OpenClaw only
#   ./maintenance.sh paperclip        # update Paperclip only
#   ./maintenance.sh all              # update everything (non-interactive if env vars set)
#   ./maintenance.sh --help

OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
PAPERCLIP_REPO_DIR="${PAPERCLIP_REPO_DIR:-$HOME/apps/paperclip}"
PAPERCLIP_REF="${PAPERCLIP_REF:-master}"
PAPERCLIP_ENV_FILE="${PAPERCLIP_ENV_FILE:-$HOME/.config/paperclip/paperclip.env}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as a non-root user, not root."
  exit 1
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [TARGET]

TARGET:
  openclaw    Update OpenClaw only
  paperclip   Update Paperclip only
  hermes      Update Hermes Agent only
  all         Update OpenClaw, Paperclip, and Hermes
  (none)      Interactive — prompts for what to update (default)

Environment variable overrides:
  OPENCLAW_VERSION     npm version or dist-tag  (default: latest)
  PAPERCLIP_REF        git ref, branch, or tag  (default: master)
  PAPERCLIP_REPO_DIR   path to Paperclip repo   (default: ~/apps/paperclip)
  PAPERCLIP_ENV_FILE   path to Paperclip env    (default: ~/.config/paperclip/paperclip.env)
EOF
}

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

brew_shellenv() {
  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
    eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
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

update_openclaw() {
  log "Updating OpenClaw to ${OPENCLAW_VERSION}"
  npm install -g "openclaw@${OPENCLAW_VERSION}"

  log "Restarting OpenClaw user service"
  systemctl --user daemon-reload
  systemctl --user restart openclaw-gateway.service
}

update_paperclip() {
  log "Updating Paperclip to ${PAPERCLIP_REF}"
  if [[ ! -d "${PAPERCLIP_REPO_DIR}/.git" ]]; then
    echo "Paperclip repo not found at ${PAPERCLIP_REPO_DIR}"
    exit 1
  fi

  git -C "${PAPERCLIP_REPO_DIR}" fetch --tags --all --prune
  git -C "${PAPERCLIP_REPO_DIR}" checkout "${PAPERCLIP_REF}"
  if git -C "${PAPERCLIP_REPO_DIR}" show-ref --verify --quiet "refs/heads/${PAPERCLIP_REF}"; then
    git -C "${PAPERCLIP_REPO_DIR}" pull --ff-only
  fi

  cd "${PAPERCLIP_REPO_DIR}"
  ensure_pnpm
  pnpm install --frozen-lockfile
  pnpm --filter @paperclipai/db generate
  pnpm build
  ./scripts/prepare-server-ui-dist.sh
  pnpm --filter @paperclipai/server build

  if [[ -f "${PAPERCLIP_ENV_FILE}" ]]; then
    set -a
    source "${PAPERCLIP_ENV_FILE}"
    set +a
  fi

  log "Restarting Paperclip user service"
  systemctl --user daemon-reload
  systemctl --user restart paperclip.service
}

update_hermes() {
  log "Updating Hermes Agent"

  if ! command -v hermes >/dev/null 2>&1; then
    echo "Hermes not found on PATH. Install it first with ./scripts/install-apps.sh hermes"
    exit 1
  fi

  hermes update

  if systemctl --user is-active --quiet hermes-gateway.service; then
    log "Restarting Hermes gateway user service"
    systemctl --user daemon-reload
    systemctl --user restart hermes-gateway.service
  else
    log "Hermes gateway user service is not active — skipping restart"
  fi
}

show_status() {
  local target="${1:-all}"
  if [[ "${target}" == "openclaw" || "${target}" == "all" ]]; then
    systemctl --user --no-pager --full status openclaw-gateway.service || true
  fi
  if [[ "${target}" == "paperclip" || "${target}" == "all" ]]; then
    systemctl --user --no-pager --full status paperclip.service || true
  fi
  if [[ "${target}" == "hermes" || "${target}" == "all" ]]; then
    systemctl --user --no-pager --full status hermes-gateway.service || true
  fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────

TARGET="${1:-}"

case "${TARGET}" in
  --help|-h)
    usage
    exit 0
    ;;
  openclaw)
    brew_shellenv
    OPENCLAW_VERSION="$(prompt_with_default "OpenClaw npm version or dist-tag" "${OPENCLAW_VERSION}")"
    update_openclaw
    log "Done"
    show_status openclaw
    ;;
  paperclip)
    brew_shellenv
    PAPERCLIP_REF="$(prompt_with_default "Paperclip git ref, branch, or tag" "${PAPERCLIP_REF}")"
    update_paperclip
    log "Done"
    show_status paperclip
    ;;
  hermes)
    brew_shellenv
    update_hermes
    log "Done"
    show_status hermes
    ;;
  all)
    brew_shellenv
    OPENCLAW_VERSION="$(prompt_with_default "OpenClaw npm version or dist-tag" "${OPENCLAW_VERSION}")"
    PAPERCLIP_REF="$(prompt_with_default "Paperclip git ref, branch, or tag" "${PAPERCLIP_REF}")"
    update_openclaw
    update_paperclip
    update_hermes
    log "Done"
    show_status all
    ;;
  "")
    # No arg — interactive picker
    brew_shellenv
    echo ""
    echo "What would you like to update?"
    echo "  1) OpenClaw only"
    echo "  2) Paperclip only"
    echo "  3) Hermes only"
    echo "  4) All (default)"
    echo ""
    read -r -p "Choice [4]: " CHOICE
    CHOICE="${CHOICE:-4}"

    case "${CHOICE}" in
      1)
        OPENCLAW_VERSION="$(prompt_with_default "OpenClaw npm version or dist-tag" "${OPENCLAW_VERSION}")"
        update_openclaw
        log "Done"
        show_status openclaw
        ;;
      2)
        PAPERCLIP_REF="$(prompt_with_default "Paperclip git ref, branch, or tag" "${PAPERCLIP_REF}")"
        update_paperclip
        log "Done"
        show_status paperclip
        ;;
      3)
        update_hermes
        log "Done"
        show_status hermes
        ;;
      4)
        OPENCLAW_VERSION="$(prompt_with_default "OpenClaw npm version or dist-tag" "${OPENCLAW_VERSION}")"
        PAPERCLIP_REF="$(prompt_with_default "Paperclip git ref, branch, or tag" "${PAPERCLIP_REF}")"
        update_openclaw
        update_paperclip
        update_hermes
        log "Done"
        show_status all
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
