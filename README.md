# Ubuntu 24 VPS Installer

This repository contains an opinionated two-stage setup for a fresh Ubuntu 24 VPS:

- Stage 1, as `root`: fully update the OS, apply basic SSH hardening, create `jarkomes`, install Tailscale, and lock inbound access down to Tailscale only.
- Stage 2, as `jarkomes`: install Homebrew on Linux, install a current Node toolchain, install native Codex CLI and Claude Code CLI, install OpenClaw, install Paperclip from source, provision a dedicated local PostgreSQL database for Paperclip, install Hermes Agent via its official installer, and expose OpenClaw and Paperclip over Tailscale.
- Stage 3 (optional), as `jarkomes`: install Nerve, the OpenClaw web UI, in cloud/Tailscale-Serve mode.
- Maintenance: an interactive updater can later refresh OpenClaw, Paperclip, and Hermes Agent to versions or refs you choose.

Assumptions:

- The target host is a clean Ubuntu 24 VPS.
- You want `jarkomes` to have passwordless `sudo` access.
- You want key-based SSH only.
- You want `root` SSH disabled after bootstrap.
- OpenClaw will be exposed on `https://<tailscale-dns>/`.
- Paperclip will be exposed on `https://<tailscale-dns>:8443/`.

## Files

- `scripts/bootstrap-root.sh` - run once as `root`
- `scripts/install-apps.sh` - run as `jarkomes`
- `scripts/maintenance.sh` - run later as `jarkomes` for app updates
- `scripts/install-nerve.sh` - optional: install Nerve (OpenClaw web UI)
- `scripts/install-netdata.sh` - optional add-on, see `NETDATA.md`

## Required Environment Variables

Before running stage 1:

```bash
export TS_AUTHKEY="tskey-auth-..."
```

`USER_SSH_KEY` is also required. If not set as an env var, the script will prompt for it interactively.

Optional before running stage 2:

```bash
export OPENAI_API_KEY="sk-..."
```

If `OPENAI_API_KEY` is present, the installer wires OpenClaw onboarding to OpenAI using env-backed secret refs. If not, OpenClaw is installed with `auth-choice skip`, which gets the gateway online but leaves model auth for later.

Paperclip onboarding is intentionally not run during the installer. The service is installed and started, and you can complete Paperclip onboarding afterward in your browser over Tailscale.

## Run Order

1. Copy this folder to the new VPS.
2. SSH in as `root`.
3. Run:

```bash
chmod +x scripts/*.sh
TS_AUTHKEY="tskey-auth-..." ./scripts/bootstrap-root.sh
```

4. Disconnect and reconnect through Tailscale as `jarkomes`.
5. Run:

```bash
# Install everything (recommended):
./scripts/install-apps.sh all

# Or run interactively to pick what to install:
./scripts/install-apps.sh

# Or install components separately:
./scripts/install-apps.sh toolchain   # Homebrew + Node + Codex + Claude Code
./scripts/install-apps.sh openclaw   # OpenClaw only (requires toolchain)
./scripts/install-apps.sh paperclip  # Paperclip only (requires toolchain)
./scripts/install-apps.sh hermes     # Hermes Agent only (requires toolchain)
```

## What You Get

- Fully upgraded Ubuntu base
- `jarkomes` user with passwordless `sudo`
- Your SSH key installed for both `root` and `jarkomes`
- Password auth disabled
- Root SSH login disabled
- UFW configured to allow inbound traffic only on `tailscale0`
- Tailscale installed and brought up
- 2G swap file configured
- OpenClaw installed as a user service under `jarkomes`
- Homebrew installed in the supported Linux prefix
- Codex CLI installed natively on the machine
- Claude Code CLI installed natively on the machine
- Paperclip built from source as a user service under `jarkomes`
- Dedicated local PostgreSQL database for Paperclip
- Tailnet-only URLs for both apps
- Hermes Agent installed via the official upstream installer
- Hermes Gateway user service installed but disabled (enable after running `hermes gateway setup`)

## OpenClaw Access

After install, prefer opening OpenClaw at the Tailscale URL:

```text
https://<tailscale-dns>/
```

Use `openclaw dashboard` only as a localhost / SSH-tunnel fallback:

```bash
openclaw dashboard
```

OpenClaw is published separately over Tailscale Serve to `https://<tailscale-dns>/`, while the gateway itself stays bound to loopback. The installer also enables `gateway.auth.allowTailscale = true` so the Control UI can authenticate over Tailscale identity headers instead of needing a pasted token on the Tailscale URL.

The installer also sets:

- `gateway.tailscale.mode = "serve"`
- `gateway.controlUi.allowedOrigins = ["https://<tailscale-dns>"]`

Important:

- If you use the Tailscale URL, you normally should not need to paste a token.
- If you use `openclaw dashboard`, SSH tunnel access, or localhost access, the CLI may say token auto-auth is disabled because the gateway token is SecretRef-managed. That is expected.

If you access OpenClaw over an SSH tunnel or localhost and need the gateway token manually, retrieve it with:

```bash
grep '^OPENCLAW_GATEWAY_TOKEN=' ~/.openclaw/.env
```

To print only the token value:

```bash
awk -F= '/^OPENCLAW_GATEWAY_TOKEN=/{print substr($0, index($0,"=")+1)}' ~/.openclaw/.env
```

## Nerve (OpenClaw Web UI)

Nerve is the browser-based cockpit for OpenClaw — chat, voice, file browser, kanban task board, session tree, agent context, and TTS all in one place.

Run after Stage 2 (OpenClaw must be installed and the gateway service running):

```bash
./scripts/install-nerve.sh
```

Nerve is installed in cloud mode: bound to loopback, published over Tailscale Serve on HTTPS. Access it at:

```text
https://<tailscale-dns>:7443/
```

The default password is your OpenClaw gateway token. To retrieve it:

```bash
grep '^GATEWAY_TOKEN=' ~/nerve/.env
```

To update Nerve later:

```bash
cd ~/nerve && npm run update -- --yes
```

Service management:

```bash
systemctl --user status  nerve.service
journalctl --user -u nerve.service -f
```

## Hermes Agent

Hermes Agent is installed via the official upstream installer. Unlike OpenClaw and Paperclip, Hermes has no HTTP UI — it is a terminal application plus an optional messaging gateway daemon.

Start the interactive terminal UI:

```bash
hermes
```

Run the full setup wizard to choose a model provider and configure tools:

```bash
hermes setup
```

The Hermes messaging gateway user service is installed but **not enabled**. To use Telegram, Discord, Slack, WhatsApp, Signal, or Email, first configure a platform and then enable the service:

```bash
hermes gateway setup
systemctl --user enable --now hermes-gateway.service
systemctl --user status hermes-gateway.service
```

If you are migrating from OpenClaw, you can import your SOUL.md, memories, skills, command allowlist, platform configs, and API keys:

```bash
hermes claw migrate --dry-run   # preview
hermes claw migrate             # perform the import
```

Diagnose issues:

```bash
hermes doctor
```

## Maintenance

To update the installed apps later:

```bash
# Update everything (interactive menu):
./scripts/maintenance.sh

# Or target a specific app directly:
./scripts/maintenance.sh openclaw    # update OpenClaw only
./scripts/maintenance.sh paperclip  # update Paperclip only
./scripts/maintenance.sh hermes     # update Hermes Agent only
./scripts/maintenance.sh all        # update all apps without the menu
```

Each target prompts only for its relevant version or ref (OpenClaw npm dist-tag, default `latest`; Paperclip git ref, branch, or tag, default `master`), then updates and restarts only the affected service.

After install, you can run the Paperclip CLI from anywhere with:

```bash
/usr/local/bin/paperclipai-local auth bootstrap-ceo
```

You should also complete first-run onboarding/auth for the locally installed coding CLIs:

```bash
claude
codex
```

Run each once and follow its login/onboarding flow.

If a newly installed command is not found in your current shell yet, run:

```bash
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
```

If `claude` or `codex` fail with a connection or auth URL error on first run, the VPS resolver may be having a temporary hiccup. Try:

```bash
getent hosts platform.claude.com
getent hosts auth.openai.com
sudo systemctl restart systemd-resolved
```

Then rerun:

```bash
claude
codex
```

## Sources Used

- OpenClaw install docs: <https://docs.openclaw.ai/install>
- OpenClaw CLI onboarding docs: <https://docs.openclaw.ai/cli/onboard>
- OpenClaw Tailscale docs: <https://docs.openclaw.ai/gateway/tailscale>
- OpenClaw Linux service docs: <https://docs.openclaw.ai/linux>
- OpenClaw repo: <https://github.com/openclaw/openclaw>
- Paperclip repo: <https://github.com/paperclipai/paperclip>
- Paperclip Docker docs: <https://github.com/paperclipai/paperclip/blob/master/doc/DOCKER.md>
- Hermes Agent repo: <https://github.com/NousResearch/hermes-agent>
- Hermes Agent docs: <https://hermes-agent.nousresearch.com/docs/>
- Homebrew on Linux docs: <https://docs.brew.sh/Homebrew-on-Linux>
- Homebrew install docs: <https://docs.brew.sh/Installation>
- OpenAI Codex CLI help article: <https://help.openai.com/en/articles/11096431>
- Anthropic Claude Code setup docs: <https://docs.anthropic.com/en/docs/claude-code/getting-started>
- Tailscale Serve docs: <https://tailscale.com/kb/1242/tailscale-serve>
