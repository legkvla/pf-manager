# PF Manager

This repo installs a managed PF configuration for macOS that keeps SSH and VNC reachable only on `lo0` and `bridge0`. It also installs a dedicated `caffeinate` daemon to keep the Mac awake while the PF rules are being guarded.

It does three things:

1. Preserves the existing PF ruleset as a base config.
2. Generates a managed `/var/etc/pf.conf` that loads a dedicated `pf-manager` anchor.
3. Mirrors the same managed rules into `/etc/pf.conf` and `/etc/pf.anchors/pf-manager` for compatibility with default PF activation paths.
4. Installs a `LaunchDaemon` that reapplies the managed config after boot and if PF is rewritten later.
5. Installs a separate `LaunchDaemon` that runs `/usr/bin/caffeinate -dimsu` with `KeepAlive`.

macOS can rewrite `/etc/pf.conf`, so the daemon still reloads PF from `/var/etc/pf.conf` while also keeping `/etc/pf.conf` and `/etc/pf.anchors/pf-manager` in sync.

## Managed rules

```pf
# Allow SSH and VNC only on loopback and bridge
pass in quick on { lo0, bridge0 } proto { tcp, udp } from any to any port { 22, 5900, 5901, 5902 } keep state

# Block SSH and VNC everywhere else
block in quick proto { tcp, udp } from any to any port { 22, 5900, 5901, 5902 }
```

## Usage

Install the PF guardian and caffeinate daemons:

```sh
sudo ./pf-manager.sh install
```

Install only the caffeinate daemon:

```sh
sudo ./pf-manager.sh install-caffeinate
```

Reapply the managed config manually:

```sh
sudo ./pf-manager.sh apply
```

Check status:

```sh
./pf-manager.sh status
```

Check the installed launchd jobs:

```sh
sudo launchctl print system/com.pf-manager.guardian
sudo launchctl print system/com.pf-manager.caffeinate
```

Uninstall and restore the previous PF config:

```sh
sudo ./pf-manager.sh uninstall
```

`uninstall` removes both LaunchDaemons and restores the preserved PF config.

## Installed files

- Managed PF config: `/var/etc/pf.conf`
- Preserved base config: `/var/etc/pf-manager/base.pf.conf`
- Managed anchor: `/var/etc/pf-manager/pf-manager.anchor`
- Mirrored default PF config: `/etc/pf.conf`
- Mirrored default anchor: `/etc/pf.anchors/pf-manager`
- Installed script: `/usr/local/libexec/pf-manager/pf-manager.sh`
- PF guardian LaunchDaemon: `/Library/LaunchDaemons/com.pf-manager.guardian.plist`
- Caffeinate LaunchDaemon: `/Library/LaunchDaemons/com.pf-manager.caffeinate.plist`

## Notes

- The PF guardian daemon runs at load and every 15 seconds by default.
- The PF guardian daemon checks both `pfctl -s rules` for `anchor "pf-manager" all` and `pfctl -a pf-manager -s rules` for the managed rule marker, and reloads PF if either check fails or PF is disabled.
- The caffeinate daemon runs `/usr/bin/caffeinate -dimsu`, starts at load, and uses `KeepAlive` so launchd restarts it if it exits.
- `install-caffeinate` only installs and bootstraps `/Library/LaunchDaemons/com.pf-manager.caffeinate.plist`; it does not install the PF guardian or modify PF config files.
- To change the caffeinate assertion flags at install time, set `PFM_CAFFEINATE_ARGS`, for example `sudo PFM_CAFFEINATE_ARGS=-dis ./pf-manager.sh install`.
- `uninstall` restores the preserved base config instead of disabling PF entirely.
- For staged local testing without touching the live system, set `PFM_ALLOW_UNPRIVILEGED=1`, `PFM_SKIP_PFCTL=1`, and `PFM_LAUNCHD_BOOTSTRAP=0`, then override both the `/var/etc` and `/etc` destination paths into a writable temp directory.

## License

MIT. See `LICENSE`.
