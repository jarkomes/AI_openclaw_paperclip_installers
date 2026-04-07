# Netdata Add-On

This is a standalone add-on for the VPS installer stack.

It does not modify the main bootstrap flow yet. Instead, it gives you a separate installer you can run later on a VPS that already has:

- Ubuntu 24
- Tailscale installed and connected
- `jarkomes` with passwordless `sudo`

## What It Does

- Installs Netdata using the official `kickstart.sh` flow
- Uses the `stable` release channel by default
- Disables Netdata auto-updates by default
- Disables Netdata anonymous telemetry by default
- Does not connect the node to Netdata Cloud
- Reconfigures Netdata to listen only on localhost
- Restricts dashboard and management access to localhost
- Publishes Netdata only over Tailscale Serve
- Backs up the previous `/etc/netdata/netdata.conf` once before replacing it

## Run

```bash
chmod +x scripts/install-netdata.sh
./scripts/install-netdata.sh
```

## Defaults

- Netdata release channel: `stable`
- Netdata auto-updates: `disabled`
- Netdata telemetry: `disabled`
- Tailscale HTTPS port: `19999`

## Result

Netdata stays local on:

```text
http://127.0.0.1:19999
```

And is exposed only to your tailnet at:

```text
https://<tailscale-dns>:19999/
```

## Sources

- Netdata Linux install docs: <https://learn.netdata.cloud/docs/netdata-agent/installation/linux>
- Netdata web server/security docs: <https://learn.netdata.cloud/docs/netdata-agent/configuration/securing-agents/web-server-reference>
- Netdata securing agents docs: <https://learn.netdata.cloud/docs/netdata-agent/configuration/securing-agents/>
- Tailscale Serve docs: <https://tailscale.com/kb/1242/tailscale-serve>
