#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-jarkomes}"
USER_SSH_KEY="${USER_SSH_KEY:-}"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-$(hostnamectl --static 2>/dev/null || hostname)}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

if [[ -z "${TS_AUTHKEY}" ]]; then
  read -r -p "Tailscale auth key (TS_AUTHKEY): " TS_AUTHKEY
fi

if [[ -z "${TS_AUTHKEY}" ]]; then
  echo "TS_AUTHKEY is required so the host can be locked down to Tailscale safely."
  exit 1
fi

if [[ -z "${USER_SSH_KEY}" ]]; then
  read -r -p "SSH public key to install for root and ${USERNAME}: " USER_SSH_KEY
fi

if [[ -z "${USER_SSH_KEY}" ]]; then
  echo "USER_SSH_KEY is required for key-based SSH access."
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

log "Collecting setup values"
HOSTNAME_VALUE="$(prompt_with_default "Hostname for this VPS" "${HOSTNAME_VALUE}")"
USERNAME="$(prompt_with_default "Username to create" "${USERNAME}")"
USER_SSH_KEY="$(prompt_with_default "SSH public key for root and ${USERNAME}" "${USER_SSH_KEY}")"

if [[ -n "${HOSTNAME_VALUE}" ]]; then
  log "Setting hostname to ${HOSTNAME_VALUE}"
  hostnamectl set-hostname "${HOSTNAME_VALUE}"
  if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 ${HOSTNAME_VALUE}/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "${HOSTNAME_VALUE}" >> /etc/hosts
  fi
fi

install_authorized_key() {
  local user="$1"
  local home_dir
  home_dir="$(getent passwd "${user}" | cut -d: -f6)"

  install -d -m 700 -o "${user}" -g "${user}" "${home_dir}/.ssh"
  touch "${home_dir}/.ssh/authorized_keys"
  chmod 600 "${home_dir}/.ssh/authorized_keys"
  chown "${user}:${user}" "${home_dir}/.ssh/authorized_keys"

  if ! grep -Fqx "${USER_SSH_KEY}" "${home_dir}/.ssh/authorized_keys"; then
    printf '%s\n' "${USER_SSH_KEY}" >> "${home_dir}/.ssh/authorized_keys"
  fi
}

log "Updating the base system"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get full-upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

log "Installing base packages"
apt-get install -y \
  ca-certificates \
  curl \
  fail2ban \
  file \
  git \
  gnupg \
  jq \
  lsb-release \
  procps \
  ripgrep \
  unattended-upgrades \
  ufw

log "Enabling unattended upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat >/etc/apt/apt.conf.d/51no-auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

log "Configuring 2G swap file"
if ! swapon --show=NAME --noheadings | grep -q '/swapfile'; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi

if ! grep -q '^/swapfile ' /etc/fstab; then
  printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
fi

log "Creating ${USERNAME} if needed"
if ! id -u "${USERNAME}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${USERNAME}"
fi

usermod -aG sudo "${USERNAME}"

SUDOERS_TMP="$(mktemp)"
cat >"${SUDOERS_TMP}" <<EOF
${USERNAME} ALL=(ALL:ALL) NOPASSWD:ALL
EOF
visudo -cf "${SUDOERS_TMP}"
install -m 440 "${SUDOERS_TMP}" "/etc/sudoers.d/90-${USERNAME}-nopasswd"
rm -f "${SUDOERS_TMP}"

log "Installing SSH keys for root and ${USERNAME}"
install_authorized_key root
install_authorized_key "${USERNAME}"

log "Writing SSH hardening drop-in"
install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-vps-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
PermitRootLogin no
UsePAM yes
X11Forwarding no
AllowUsers ${USERNAME}
EOF

sshd -t
systemctl restart ssh

log "Configuring fail2ban"
cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
EOF
systemctl enable --now fail2ban

log "Installing Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh

log "Bringing Tailscale up"
tailscale up --authkey "${TS_AUTHKEY}" --ssh=false --accept-routes=false --accept-dns=true

log "Verifying Tailscale has an IP before applying firewall rules"
if ! tailscale ip -4 >/dev/null 2>&1; then
  echo "Tailscale did not get an IP address. Not applying UFW lockdown — fix Tailscale first."
  exit 1
fi

log "Locking inbound traffic to Tailscale only"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw --force enable

log "Enabling linger for ${USERNAME} user services"
loginctl enable-linger "${USERNAME}"

log "Done"
tailscale ip -4 || true
echo "Reconnect over Tailscale as ${USERNAME}, then run scripts/install-apps.sh"
