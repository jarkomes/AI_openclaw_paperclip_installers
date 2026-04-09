---
date: 2026-04-09
topic: Hermes Agent installer integration
status: approved
---

# Hermes Agent Installer — Design

## Context

This repository provisions an Ubuntu 24 VPS stack in two stages:

- `scripts/bootstrap-root.sh` — OS hardening, user creation, Tailscale.
- `scripts/install-apps.sh` — toolchain (Homebrew + Node + Codex CLI + Claude Code CLI), OpenClaw, Paperclip.
- `scripts/maintenance.sh` — interactive updater for installed apps.

The user wants to add [Hermes Agent](https://github.com/NousResearch/hermes-agent) as a fourth installable component, running alongside the existing stack.

### What Hermes Agent is

Python-based self-improving AI agent from Nous Research. Two entry points:

- `hermes` — interactive terminal UI.
- `hermes gateway start` — long-running messaging gateway (Telegram, Discord, Slack, WhatsApp, Signal, Email).

Unlike OpenClaw and Paperclip, Hermes has **no HTTP UI**, so it does not need Tailscale Serve publication. It ships an official installer (`scripts/install.sh`) and a built-in `hermes update` command.

### Relevance to the existing stack

OpenClaw is already installed on this box. Hermes can import OpenClaw's SOUL.md, memories, skills, command allowlist, messaging settings, and API keys via `hermes claw migrate`, but the user has chosen **not** to run migration during install — it will remain user-driven after the fact.

## Decisions (from brainstorming)

| # | Decision | Chosen | Rationale |
|---|---|---|---|
| 1 | Install method | Wrap official upstream `curl \| bash` installer | Simplest, tracks upstream, minimal maintenance surface |
| 2 | OpenClaw migration on install | Skip, print hint | Migration is stateful; user runs `hermes claw migrate --dry-run` manually |
| 3 | Gateway systemd unit | Install but leave disabled | Avoids crash-loop on a fresh box with no platforms configured |
| 4a | `maintenance.sh` integration | Add `hermes` target that runs `hermes update` | Matches existing `openclaw` / `paperclip` targets |
| 4b | `install-apps.sh` integration | Standalone target **and** part of `all` and interactive menu | Fresh VPS gets the full stack in one run |

## Scope

### In scope

- New `install_hermes` function inside `scripts/install-apps.sh`.
- New `hermes` case branch in `install-apps.sh` argument parser.
- Hermes added to the `all` target and the interactive menu.
- New `hermes` case branch in `scripts/maintenance.sh`, its interactive menu, and its `all` target.
- `README.md` updated: file list (unchanged — no new files), run order, "what you get", sources.
- Systemd user unit `~/.config/systemd/user/hermes-gateway.service` — installed, **not** enabled.

### Out of scope (YAGNI)

- Tailscale Serve publication (Hermes has no HTTP UI).
- OpenClaw-to-Hermes migration during install.
- Auto-enable of the gateway service.
- Install-time prompts for Hermes configuration (`hermes setup` handles this post-install).
- Version pinning — upstream installer and `hermes update` manage versions.
- A new `scripts/install-hermes.sh` file — Hermes lives inside `install-apps.sh` alongside OpenClaw and Paperclip for cohesion.

## Design

### New configuration surface

All optional, all env-overridable, matching the existing style:

```
HERMES_INSTALL_URL   default: https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh
```

No ports, no database, no secrets. Hermes has no install-time config surface that the installer needs to set — `hermes setup` handles everything interactively after install.

### `install_hermes()` behavior

1. **Preflight.** Call `require_toolchain` (already defined) to guarantee brew/node/npm are present. Hermes's upstream installer needs `git`, `curl`, `python3`, and `python3-venv`. Install them in a single `sudo apt-get update && sudo apt-get install -y ...` block, matching the `install_paperclip` style. Most are already present from the toolchain step, this is belt-and-suspenders.

2. **Run upstream installer.**
   ```bash
   curl -fsSL "${HERMES_INSTALL_URL}" | bash
   ```
   Upstream installer is idempotent (handles re-runs).

3. **Resolve `hermes` binary path.**
   ```bash
   export PATH="$HOME/.local/bin:$PATH"
   if ! command -v hermes >/dev/null 2>&1; then
     echo "Hermes was not found after installation."
     exit 1
   fi
   local hermes_bin
   hermes_bin="$(command -v hermes)"
   ```
   The existing `ensure_shell_path_setup` already adds `$HOME/.local/bin` to user shells, so new login shells inherit it automatically.

4. **Install systemd user unit** at `~/.config/systemd/user/hermes-gateway.service`. Values marked `${...}` are shell-substituted at install time, exactly like the existing `openclaw-gateway.service` and `paperclip.service` heredocs:
   ```
   [Unit]
   Description=Hermes Agent Messaging Gateway
   After=network-online.target
   Wants=network-online.target

   [Service]
   Environment=PATH=${systemd_path_value}
   ExecStart=${hermes_bin} gateway start
   Restart=on-failure
   RestartSec=10

   [Install]
   WantedBy=default.target
   ```
   Run `systemctl --user daemon-reload`. **Do NOT run `enable --now`.** The unit is inert until the user runs `hermes gateway setup` and then enables it.

   `Restart=on-failure` is intentionally weaker than the `Restart=always` used by OpenClaw/Paperclip — if the gateway exits cleanly (e.g. user ran `systemctl --user stop`) we shouldn't fight it, and on a misconfigured platform a crash-loop on `always` would mask the error.

5. **Print post-install hints:**
   - `hermes` — start the interactive TUI
   - `hermes setup` — full setup wizard (configure provider, model, tools)
   - `hermes gateway setup` then `systemctl --user enable --now hermes-gateway` — configure and enable messaging
   - `hermes claw migrate --dry-run` — preview importing your OpenClaw state
   - `hermes doctor` — diagnose issues

### `install-apps.sh` integration

- **New case branch `hermes)`** in the argument parser. Calls `require_toolchain`, then `install_hermes`. No prompts (Hermes has no install-time config).
- **`all` branch:** call `install_hermes` after `install_paperclip`. No new prompts added to the upfront prompt block.
- **Interactive menu:** existing options are `1)` Everything, `2)` Toolchain, `3)` OpenClaw, `4)` Paperclip. Add a new option `5) Hermes only` (requires toolchain). Update option `1)`'s label from `"Everything: toolchain + OpenClaw + Paperclip (default)"` to `"Everything: toolchain + OpenClaw + Paperclip + Hermes (default)"`. Option `1)` invokes `install_hermes` after `install_paperclip`. Default remains `1`.
- **`usage()`:** add `hermes` to the `TARGET` list. Add `HERMES_INSTALL_URL` to the env var overrides list.

### `maintenance.sh` — `hermes` target

- New `hermes)` top-level case that:
  1. Runs `hermes update`.
  2. If `systemctl --user is-active --quiet hermes-gateway.service`, restart it. Otherwise leave it alone.
- **`all` target:** call `update_hermes` after `update_paperclip`. Do **not** add a prompt for it (Hermes has no version/ref prompt).
- **Interactive menu:** existing options are `1)` OpenClaw, `2)` Paperclip, `3)` Both (default). Renumber: `1)` OpenClaw, `2)` Paperclip, `3)` Hermes, `4)` All (default). The default moves from `3` to `4`. Update the `read -r -p "Choice [3]: "` prompt to `"Choice [4]: "` and the `CHOICE="${CHOICE:-3}"` fallback to `"${CHOICE:-4}"`.
- **`show_status`:** add a `hermes` branch that runs `systemctl --user --no-pager --full status hermes-gateway.service || true` when target is `hermes` or `all`.
- **`usage()`:** add `hermes` to the `TARGET` list. No new env var overrides.
- No version/ref prompt — `hermes update` has no equivalent of npm dist-tag or git ref in its public CLI, so we just call it.

### `README.md` updates

- "Files" section: no new files (Hermes lives inside `install-apps.sh`).
- "Run Order" code block: add `./scripts/install-apps.sh hermes` as a separate-install example.
- "What You Get" bullet list: add entries for Hermes Agent CLI and Hermes Gateway user service (installed, dormant).
- New section "Hermes Access" explaining `hermes`, `hermes setup`, `hermes gateway setup`, and the `claw migrate` hint.
- "Maintenance" section: add `./scripts/maintenance.sh hermes` example.
- "Sources Used": add Hermes repo and docs URLs.

## Idempotency

- Upstream `install.sh` is re-run safe.
- The systemd unit file is overwritten on every install (matches OpenClaw/Paperclip).
- The installer never enables the unit, so re-running will not disturb a user's later `enable --now`.
- `apt-get install` for preflight packages is idempotent.

## Failure modes

| Scenario | Behavior |
|---|---|
| Toolchain missing | `require_toolchain` exits with actionable message (existing behavior) |
| `curl` fails (DNS, network) | User sees curl's error; existing `check_dns_health` call at end of `all` flow still fires |
| `hermes` not on PATH after install | Installer exits with "Hermes was not found after installation." |
| `systemctl --user daemon-reload` fails | Installer exits with systemctl's error — same as existing OpenClaw/Paperclip behavior |
| User re-runs installer after configuring a platform and enabling the unit | `daemon-reload` picks up the (identical) unit file; enabled state is preserved because we never `disable` |

## Testing approach

This is an installer script for a remote VPS — there is no automated test harness in this repo. Validation is manual:

1. On a fresh Ubuntu 24 VPS that has already completed `install-apps.sh toolchain`, run `./scripts/install-apps.sh hermes`. Expect: `hermes --version` works, `~/.config/systemd/user/hermes-gateway.service` exists, `systemctl --user is-enabled hermes-gateway.service` reports `disabled`.
2. Run `./scripts/install-apps.sh hermes` again. Expect: clean re-run, no errors, unit file overwritten, still disabled.
3. Run `./scripts/maintenance.sh hermes`. Expect: `hermes update` runs; if the unit is inactive, no restart attempted.
4. Manually `hermes gateway setup` and `systemctl --user enable --now hermes-gateway`, then re-run `./scripts/maintenance.sh hermes`. Expect: `hermes update` runs, then the gateway service is restarted.
5. On a clean VPS, run `./scripts/install-apps.sh all`. Expect: toolchain + OpenClaw + Paperclip + Hermes all install successfully in sequence.

## Open questions

None — all four brainstorming questions answered and approved.
