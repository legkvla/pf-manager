# PF Manager

This repo installs a managed PF configuration for macOS that keeps SSH and VNC reachable only on `lo0` and `bridge0`.

It does three things:

1. Preserves the existing PF ruleset as a base config.
2. Generates a managed `/var/etc/pf.conf` that loads a dedicated `pf-manager` anchor.
3. Installs a `LaunchDaemon` that reapplies the managed config after boot and if PF is rewritten later.

macOS can rewrite `/etc/pf.conf`, so the managed config is written to `/var/etc/pf.conf` and reloaded from there.

## Managed rules

```pf
# Allow SSH and VNC only on loopback and bridge
pass in quick on { lo0, bridge0 } proto { tcp, udp } from any to any port { 22, 5900, 5901, 5902 } keep state

# Block SSH and VNC everywhere else
block in quick proto { tcp, udp } from any to any port { 22, 5900, 5901, 5902 }
```

## Usage

Install:

```sh
sudo ./pf-manager.sh install
```

Reapply the managed config manually:

```sh
sudo ./pf-manager.sh apply
```

Check status:

```sh
./pf-manager.sh status
```

Uninstall and restore the previous PF config:

```sh
sudo ./pf-manager.sh uninstall
```

## Installed files

- Managed PF config: `/var/etc/pf.conf`
- Preserved base config: `/var/etc/pf-manager/base.pf.conf`
- Managed anchor: `/var/etc/pf-manager/pf-manager.anchor`
- Installed script: `/usr/local/libexec/pf-manager/pf-manager.sh`
- LaunchDaemon: `/Library/LaunchDaemons/com.pf-manager.guardian.plist`

## Notes

- The daemon runs at load and every 15 seconds by default.
- The daemon checks `pfctl -a pf-manager -s rules` first and reloads PF only when the managed rule marker is missing or PF is disabled.
- `uninstall` restores the preserved base config instead of disabling PF entirely.
- For staged local testing without touching the live system, set `PFM_ALLOW_UNPRIVILEGED=1`, `PFM_SKIP_PFCTL=1`, and `PFM_LAUNCHD_BOOTSTRAP=0`, then override the destination paths into a writable temp directory.
