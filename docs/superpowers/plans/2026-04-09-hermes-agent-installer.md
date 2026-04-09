# Hermes Agent Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Hermes Agent as a fourth installable component to the VPS installer stack alongside toolchain, OpenClaw, and Paperclip.

**Architecture:** Wrap the official upstream `curl | bash` installer inside a new `install_hermes` function in `scripts/install-apps.sh`, install a dormant `hermes-gateway.service` systemd user unit, add a `hermes` target to both `install-apps.sh` (also wired into `all` and the interactive menu) and `maintenance.sh`, and document the addition in `README.md`. No new files are created — Hermes lives inside the existing scripts for cohesion with OpenClaw and Paperclip.

**Tech Stack:** Bash, systemd user units, upstream Hermes installer script.

**Spec reference:** `docs/superpowers/specs/2026-04-09-hermes-agent-installer-design.md`

**Testing note:** This repo has no automated test harness — it is provisioning scripts for a remote VPS. Per the spec, validation is manual (see "Testing approach" in the spec). Each task in this plan therefore uses `bash -n` for syntax validation and targeted `grep` checks for correctness, and ends in a commit. A final manual VPS test pass is called out as the last task.

---

## File Structure

| File | Change type | Responsibility |
|---|---|---|
| `scripts/install-apps.sh` | Modify | Add `HERMES_INSTALL_URL`, `install_hermes` function, `hermes` case branch, wire into `all` and interactive menu, update `usage()` |
| `scripts/maintenance.sh` | Modify | Add `update_hermes` function, `hermes` case branch, wire into `all` and interactive menu, extend `show_status`, update `usage()` |
| `README.md` | Modify | Document Hermes in run order, "What You Get", new "Hermes Access" section, maintenance examples, sources |

No new files.

---

## Task 1: Add `install_hermes` function and config var to `install-apps.sh`

**Files:**
- Modify: `scripts/install-apps.sh` (add config var near line 22, add function after `install_paperclip` around line 538)

- [ ] **Step 1: Read the current state of install-apps.sh around the config block and end of install functions**

Run: Read `scripts/install-apps.sh` lines 12-23 and 535-545 to confirm insertion points.

- [ ] **Step 2: Add `HERMES_INSTALL_URL` config var**

Insert after the `PAPERCLIP_ENV_FILE` line (currently line 22), matching the existing `${VAR:-default}` style:

```bash
HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"
```

- [ ] **Step 3: Add the `install_hermes` function**

Insert immediately after the closing brace of `install_paperclip` (currently line 538) and before `print_shell_hint`:

Note: the spec lists `require_toolchain` as step 1 of `install_hermes`, but we follow the existing codebase pattern where the caller invokes `require_toolchain` (see the `openclaw)` and `paperclip)` case branches) instead of the install function itself. Task 2 adds the `require_toolchain` call in the `hermes)` branch; the `all)` flow is already guarded because it runs `install_toolchain` first.

```bash
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

  export PATH="$HOME/.local/bin:$PATH"

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
```

- [ ] **Step 4: Syntax-check the script**

Run: `bash -n scripts/install-apps.sh`
Expected: no output (clean parse).

- [ ] **Step 5: Verify the function and var are present**

Run: `grep -n '^install_hermes\|HERMES_INSTALL_URL' scripts/install-apps.sh`
Expected: two matches — the var near the top and `install_hermes() {` further down.

- [ ] **Step 6: Commit**

```bash
git add scripts/install-apps.sh
git commit -m "Add install_hermes function to install-apps.sh

Wraps the official upstream Hermes Agent installer and provisions
a dormant hermes-gateway.service user unit."
```

---

## Task 2: Add `hermes` standalone case branch and `usage()` entries to `install-apps.sh`

**Files:**
- Modify: `scripts/install-apps.sh` (add to `usage()` around lines 38 and 55, add new case around line 586)

- [ ] **Step 0: Update the top-of-file `# Usage:` comment block**

The file has a `# Usage:` block in lines 4-10 listing one-liner examples. Add a new line after the `paperclip` example:

```
#   ./install-apps.sh hermes       # Hermes Agent only (requires toolchain)
```

- [ ] **Step 1: Update `usage()` TARGET list**

Find the `TARGET:` block in `usage()` (currently ends with the `paperclip` line). Add a new line after `paperclip`:

```
  hermes       Hermes Agent only (requires toolchain already installed)
```

Update the `all` description line to read:

```
  all          Install everything: toolchain, OpenClaw, Paperclip, Hermes (default)
```

- [ ] **Step 2: Update `usage()` env var overrides list**

Add after the `PAPERCLIP_REPO_URL` line:

```
  HERMES_INSTALL_URL        Override Hermes installer URL
```

- [ ] **Step 3: Add the `hermes)` case branch**

Insert immediately before the `all)` branch (currently around line 588). This matches the `paperclip)` pattern but without prompts (Hermes has no install-time config):

```bash
  hermes)
    require_toolchain
    install_hermes
    log "Done"
    print_shell_hint
    ;;

```

- [ ] **Step 4: Syntax-check**

Run: `bash -n scripts/install-apps.sh`
Expected: no output.

- [ ] **Step 5: Verify the new case is wired up**

Run: `grep -n 'hermes)' scripts/install-apps.sh`
Expected: at least one match on the new case line.

Run: `./scripts/install-apps.sh --help`
Expected: the help output now lists `hermes` as a TARGET and `HERMES_INSTALL_URL` as an env override.

- [ ] **Step 6: Commit**

```bash
git add scripts/install-apps.sh
git commit -m "Add hermes target and help entries to install-apps.sh"
```

---

## Task 3: Wire Hermes into `all` target and interactive menu in `install-apps.sh`

**Files:**
- Modify: `scripts/install-apps.sh` (`all)` branch around lines 588-607, interactive menu around lines 609-674)

- [ ] **Step 1: Add `install_hermes` to the `all)` branch**

In the `all)` case, add `install_hermes` immediately after the existing `install_paperclip` call (currently line 601). Result:

```bash
    install_toolchain
    brew_shellenv
    export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
    install_openclaw
    install_paperclip
    install_hermes
    log "Done"
```

No new prompts are added to the upfront prompt block — Hermes has no install-time config.

- [ ] **Step 2: Update the interactive menu header lines**

Change:

```bash
    echo "  1) Everything: toolchain + OpenClaw + Paperclip (default)"
```

to:

```bash
    echo "  1) Everything: toolchain + OpenClaw + Paperclip + Hermes (default)"
```

And add, after the `4) Paperclip only` line:

```bash
    echo "  5) Hermes only     (requires toolchain already installed)"
```

- [ ] **Step 3: Add `install_hermes` to interactive option `1)`**

In the `1)` sub-case (currently around lines 622-640), add `install_hermes` immediately after `install_paperclip`. Result:

```bash
        install_toolchain
        brew_shellenv
        export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
        install_openclaw
        install_paperclip
        install_hermes
        log "Done"
```

- [ ] **Step 4: Add new interactive sub-case `5)`**

Insert immediately after the `4)` sub-case and before the `*)` invalid-choice catchall:

```bash
      5)
        require_toolchain
        install_hermes
        log "Done"
        print_shell_hint
        ;;
```

- [ ] **Step 5: Syntax-check**

Run: `bash -n scripts/install-apps.sh`
Expected: no output.

- [ ] **Step 6: Verify wiring**

Run: `grep -c 'install_hermes' scripts/install-apps.sh`
Expected: `5` (function definition + `hermes)` case + `all)` branch + interactive `1)` + interactive `5)`).

Run: `grep -n '5) Hermes only' scripts/install-apps.sh`
Expected: one match in the interactive menu block.

- [ ] **Step 7: Commit**

```bash
git add scripts/install-apps.sh
git commit -m "Wire Hermes into install-apps.sh all target and interactive menu"
```

---

## Task 4: Add `update_hermes` function and `hermes` case to `maintenance.sh`

**Files:**
- Modify: `scripts/maintenance.sh` (add function after `update_paperclip` around line 114, update `show_status` around lines 116-124, add case branch around line 148)

- [ ] **Step 1: Add `update_hermes` function**

Insert immediately after the closing brace of `update_paperclip` (currently line 114) and before `show_status`:

```bash
update_hermes() {
  log "Updating Hermes Agent"
  export PATH="$HOME/.local/bin:$PATH"

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
```

- [ ] **Step 2: Extend `show_status` with a hermes branch**

Find `show_status()` (currently lines 116-124). Add a new `if` block after the paperclip block:

```bash
  if [[ "${target}" == "hermes" || "${target}" == "all" ]]; then
    systemctl --user --no-pager --full status hermes-gateway.service || true
  fi
```

- [ ] **Step 3: Add the `hermes)` case branch**

Insert immediately after the `paperclip)` case (currently ends at line 148) and before `all)`:

```bash
  hermes)
    brew_shellenv
    update_hermes
    log "Done"
    show_status hermes
    ;;
```

- [ ] **Step 4: Update `usage()` TARGET list**

Add after the `paperclip` line:

```
  hermes      Update Hermes Agent only
```

And update the `all` description to:

```
  all         Update OpenClaw, Paperclip, and Hermes
```

- [ ] **Step 5: Syntax-check**

Run: `bash -n scripts/maintenance.sh`
Expected: no output.

- [ ] **Step 6: Verify wiring**

Run: `grep -n 'update_hermes\|hermes)' scripts/maintenance.sh`
Expected: function definition, `hermes)` case, and eventually the `all` invocation (in the next task).

- [ ] **Step 7: Commit**

```bash
git add scripts/maintenance.sh
git commit -m "Add update_hermes and hermes target to maintenance.sh"
```

---

## Task 5: Wire Hermes into `all` target and renumbered interactive menu in `maintenance.sh`

**Files:**
- Modify: `scripts/maintenance.sh` (`all)` branch around lines 149-157, interactive menu around lines 158-197)

- [ ] **Step 1: Add `update_hermes` to the `all)` branch**

In the `all)` case, add `update_hermes` after `update_paperclip`:

```bash
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
```

- [ ] **Step 2: Renumber the interactive menu**

Current menu:

```bash
    echo "  1) OpenClaw only"
    echo "  2) Paperclip only"
    echo "  3) Both (default)"
    echo ""
    read -r -p "Choice [3]: " CHOICE
    CHOICE="${CHOICE:-3}"
```

New menu:

```bash
    echo "  1) OpenClaw only"
    echo "  2) Paperclip only"
    echo "  3) Hermes only"
    echo "  4) All (default)"
    echo ""
    read -r -p "Choice [4]: " CHOICE
    CHOICE="${CHOICE:-4}"
```

- [ ] **Step 3: Rewrite the interactive sub-cases**

The inner `case "${CHOICE}"` block currently has `1)`, `2)`, `3)`, `*)`. Replace it with `1)`, `2)`, `3)`, `4)`, `*)`:

```bash
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
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n scripts/maintenance.sh`
Expected: no output.

- [ ] **Step 5: Verify wiring**

Run: `grep -c 'update_hermes' scripts/maintenance.sh`
Expected: `5` (function definition + `hermes)` case + `all)` case + interactive `3)` + interactive `4)`).

Run: `grep -n 'Choice \[4\]' scripts/maintenance.sh`
Expected: one match.

Run: `./scripts/maintenance.sh --help`
Expected: help output now lists `hermes` as a TARGET.

- [ ] **Step 6: Commit**

```bash
git add scripts/maintenance.sh
git commit -m "Wire Hermes into maintenance.sh all target and interactive menu

Renumbers the interactive menu: 1) OpenClaw, 2) Paperclip,
3) Hermes, 4) All (default). Default choice moves from 3 to 4."
```

---

## Task 6: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the "Run Order" code block**

Find the "Or install components separately" block (around line 66). Add after the `paperclip` line:

```bash
./scripts/install-apps.sh hermes     # Hermes Agent only (requires toolchain)
```

- [ ] **Step 2: Update "What You Get"**

Find the bullet list under "## What You Get" (around lines 74-89). Add two bullets after the Paperclip-related entries:

```markdown
- Hermes Agent installed via the official upstream installer
- Hermes Gateway user service installed but disabled (enable after running `hermes gateway setup`)
```

- [ ] **Step 3: Add new "Hermes Access" section**

Insert a new section after the "Paperclip" content and before "## Maintenance" (the section ordering in the README already groups per-app notes before Maintenance — place this alongside the OpenClaw Access section):

```markdown
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
```

- [ ] **Step 4: Update the "Maintenance" section**

Find the maintenance code block (around lines 131-140). Add after the `paperclip` example:

```bash
./scripts/maintenance.sh hermes    # update Hermes Agent only
```

Update the `all` description line just below it to mention Hermes.

- [ ] **Step 5: Add Hermes to "Sources Used"**

Add after the Paperclip lines:

```markdown
- Hermes Agent repo: <https://github.com/NousResearch/hermes-agent>
- Hermes Agent docs: <https://hermes-agent.nousresearch.com/docs/>
```

- [ ] **Step 6: Verify the README still renders as valid markdown**

Run: `grep -n '^## ' README.md`
Expected: the new "## Hermes Agent" section appears in sensible order relative to "## OpenClaw Access" and "## Maintenance".

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "Document Hermes Agent in README"
```

---

## Task 7: Final sanity pass

**Files:** none (validation only)

- [ ] **Step 1: Final syntax check both scripts**

Run: `bash -n scripts/install-apps.sh && bash -n scripts/maintenance.sh && echo OK`
Expected: `OK`

- [ ] **Step 2: Confirm help output is clean for both scripts**

Run: `./scripts/install-apps.sh --help` and `./scripts/maintenance.sh --help`
Expected: both show `hermes` as a target, `install-apps.sh` shows `HERMES_INSTALL_URL` in env overrides, no stray text.

- [ ] **Step 3: Review the full diff against main**

Run: `git log --oneline main..HEAD` and `git diff main -- scripts README.md | wc -l`
Expected: 6 new commits, a diff of reasonable size (a few hundred lines).

- [ ] **Step 4: Manual VPS validation (out of band)**

This cannot be scripted in CI because there is no CI. On a fresh Ubuntu 24 VPS that has already run `./scripts/install-apps.sh toolchain`:

1. `./scripts/install-apps.sh hermes` — expect `hermes --version` to work, `~/.config/systemd/user/hermes-gateway.service` to exist, and `systemctl --user is-enabled hermes-gateway.service` to print `disabled`.
2. `./scripts/install-apps.sh hermes` again — expect a clean re-run.
3. `./scripts/maintenance.sh hermes` — expect `hermes update` to run and no gateway restart (service inactive).
4. `hermes gateway setup` then `systemctl --user enable --now hermes-gateway`, then `./scripts/maintenance.sh hermes` — expect the gateway to be restarted.
5. On a clean VPS, `./scripts/install-apps.sh all` — expect toolchain + OpenClaw + Paperclip + Hermes to install in sequence.

Note any discrepancies and file follow-up fixes as a new plan.

---

## Done criteria

- All 7 tasks complete.
- Every sub-step checkbox ticked.
- 6 commits on the branch (one per task 1–6; task 7 is validation only).
- `bash -n` clean on both scripts.
- Manual VPS validation (task 7 step 4) either performed or explicitly deferred by the user.
