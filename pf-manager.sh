#!/bin/sh

set -eu

LABEL="${PFM_LABEL:-com.pf-manager.guardian}"
INTERVAL="${PFM_INTERVAL:-15}"
ALLOW_UNPRIVILEGED="${PFM_ALLOW_UNPRIVILEGED:-0}"
SKIP_PFCTL="${PFM_SKIP_PFCTL:-0}"
LAUNCHD_BOOTSTRAP="${PFM_LAUNCHD_BOOTSTRAP:-1}"
ANCHOR_NAME="${PFM_ANCHOR_NAME:-pf-manager}"

VAR_ETC_DIR="${PFM_VAR_ETC_DIR:-/var/etc}"
STATE_DIR="${PFM_STATE_DIR:-$VAR_ETC_DIR/pf-manager}"
MAIN_CONF="${PFM_MAIN_CONF:-$VAR_ETC_DIR/pf.conf}"
BASE_BACKUP="${PFM_BASE_BACKUP:-$STATE_DIR/base.pf.conf}"
ANCHOR_CONF="${PFM_ANCHOR_CONF:-$STATE_DIR/pf-manager.anchor}"
ETC_MAIN_CONF="${PFM_ETC_MAIN_CONF:-/etc/pf.conf}"
ETC_MAIN_BACKUP="${PFM_ETC_MAIN_BACKUP:-$STATE_DIR/etc.pf.conf.backup}"
ETC_ANCHOR_CONF="${PFM_ETC_ANCHOR_CONF:-/etc/pf.anchors/$ANCHOR_NAME}"
ETC_ANCHOR_BACKUP="${PFM_ETC_ANCHOR_BACKUP:-$STATE_DIR/etc.pf.anchors.$ANCHOR_NAME.backup}"

INSTALL_DIR="${PFM_INSTALL_DIR:-/usr/local/libexec/pf-manager}"
INSTALLED_SCRIPT="${PFM_INSTALLED_SCRIPT:-$INSTALL_DIR/pf-manager.sh}"
LAUNCHD_DIR="${PFM_LAUNCHD_DIR:-/Library/LaunchDaemons}"
PLIST_PATH="${PFM_PLIST_PATH:-$LAUNCHD_DIR/$LABEL.plist}"

MARKER_BEGIN="# BEGIN pf-manager"
MARKER_END="# END pf-manager"
MAIN_RULE_MARKER='anchor "pf-manager" all'
LIVE_RULE_MARKER='block drop in quick proto tcp from any to any port = 22'

SELF_PATH="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/$(basename "$0")"

log() {
  printf '%s\n' "$*" >&2
}

warn() {
  log "warning: $*"
}

die() {
  log "error: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  install         Install the managed PF config and LaunchDaemon
  uninstall       Remove the LaunchDaemon and restore the previous PF config
  apply           Regenerate the managed PF config and load it into PF
  daemon          LaunchDaemon entrypoint; equivalent to apply
  status          Print the current configuration status
  render-anchor   Print the anchor rules to stdout
  render-main     Print the generated main PF config to stdout
  render-plist    Print the generated LaunchDaemon plist to stdout
  help            Show this help text

Important environment overrides:
  PFM_ALLOW_UNPRIVILEGED=1  Allow staged installs without root
  PFM_SKIP_PFCTL=1          Skip live pfctl validation and reloads
  PFM_LAUNCHD_BOOTSTRAP=0   Skip launchctl bootstrap/bootout operations
EOF
}

require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if [ "$ALLOW_UNPRIVILEGED" = "1" ]; then
    return 0
  fi

  die "root privileges are required; use sudo or set PFM_ALLOW_UNPRIVILEGED=1 for a staged test install"
}

ensure_dir() {
  mkdir -p "$1"
}

make_tmp() {
  mktemp "${TMPDIR:-/tmp}/pf-manager.XXXXXX"
}

write_file() {
  target="$1"
  tmp="$(make_tmp)"
  cat >"$tmp"
  chmod "${2:-644}" "$tmp"
  mv "$tmp" "$target"
}

write_if_changed() {
  target="$1"
  mode="${2:-644}"
  tmp="$(make_tmp)"
  cat >"$tmp"
  chmod "$mode" "$tmp"

  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$target"
}

managed_file() {
  file="$1"
  [ -f "$file" ] && grep -Fq "$MARKER_BEGIN" "$file"
}

strip_managed_section() {
  file="$1"
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$file"
}

render_anchor() {
  cat <<'EOF'
# Allow SSH and VNC only on loopback and bridge
pass in quick on { lo0, bridge0 } proto { tcp, udp } from any to any port { 22, 5900, 5901, 5902 } keep state

# Block SSH and VNC everywhere else
block in quick proto { tcp, udp } from any to any port { 22, 5900, 5901, 5902 }
EOF
}

ensure_base_backup() {
  ensure_main_backup "$MAIN_CONF" "$BASE_BACKUP" "$ETC_MAIN_CONF"
}

ensure_main_backup() {
  main_file="$1"
  backup_file="$2"
  fallback_file="${3:-}"

  ensure_dir "$STATE_DIR"

  if [ -f "$backup_file" ]; then
    return 0
  fi

  if [ -f "$main_file" ]; then
    if managed_file "$main_file"; then
      strip_managed_section "$main_file" | write_file "$backup_file" 600
      return 0
    fi

    cp "$main_file" "$backup_file"
    chmod 600 "$backup_file"
    return 0
  fi

  if [ -n "$fallback_file" ] && [ -f "$fallback_file" ]; then
    cp "$fallback_file" "$backup_file"
    chmod 600 "$backup_file"
    return 0
  fi

  die "unable to find a base PF configuration to preserve"
}

ensure_system_backups() {
  ensure_main_backup "$ETC_MAIN_CONF" "$ETC_MAIN_BACKUP" "$MAIN_CONF"

  if [ -f "$ETC_ANCHOR_BACKUP" ]; then
    return 0
  fi

  ensure_dir "$STATE_DIR"

  if [ -f "$ETC_ANCHOR_CONF" ]; then
    cp "$ETC_ANCHOR_CONF" "$ETC_ANCHOR_BACKUP"
    chmod 600 "$ETC_ANCHOR_BACKUP"
    return 0
  fi

  : >"$ETC_ANCHOR_BACKUP"
  chmod 000 "$ETC_ANCHOR_BACKUP"
}

base_conf_source() {
  backup_file="$1"
  main_file="$2"
  fallback_file="${3:-}"

  if [ -f "$backup_file" ]; then
    printf '%s\n' "$backup_file"
    return 0
  fi

  if [ -f "$main_file" ]; then
    printf '%s\n' "$main_file"
    return 0
  fi

  if [ -n "$fallback_file" ] && [ -f "$fallback_file" ]; then
    printf '%s\n' "$fallback_file"
    return 0
  fi

  die "unable to find a PF configuration to render from"
}

installed_script_needs_update() {
  if [ ! -f "$INSTALLED_SCRIPT" ]; then
    return 0
  fi

  if cmp -s "$SELF_PATH" "$INSTALLED_SCRIPT"; then
    return 1
  fi

  return 0
}

write_anchor() {
  ensure_dir "$STATE_DIR"
  render_anchor | write_if_changed "$ANCHOR_CONF" 600
}

write_system_anchor() {
  ensure_dir "$(dirname "$ETC_ANCHOR_CONF")"
  render_anchor | write_if_changed "$ETC_ANCHOR_CONF" 600
}

render_main_with_paths() {
  base_source="$1"
  anchor_path="$2"

  strip_managed_section "$base_source"
  cat <<EOF

$MARKER_BEGIN
anchor "$ANCHOR_NAME"
load anchor "$ANCHOR_NAME" from "$anchor_path"
$MARKER_END
EOF
}

render_main() {
  render_main_with_paths "$(base_conf_source "$BASE_BACKUP" "$MAIN_CONF" "$ETC_MAIN_CONF")" "$ANCHOR_CONF"
}

pf_enabled() {
  /sbin/pfctl -si | grep -q '^Status: Enabled'
}

validate_main_conf() {
  file="$1"

  if [ "$SKIP_PFCTL" = "1" ]; then
    return 0
  fi

  /sbin/pfctl -nf "$file" >/dev/null
}

managed_rules_loaded() {
  if [ "$SKIP_PFCTL" = "1" ]; then
    return 1
  fi

  /sbin/pfctl -a "$ANCHOR_NAME" -s rules | grep -Fqx "$LIVE_RULE_MARKER"
}

anchor_loaded() {
  if [ "$SKIP_PFCTL" = "1" ]; then
    return 1
  fi

  /sbin/pfctl -s rules | grep -Fqx "$MAIN_RULE_MARKER"
}

load_pf() {
  if [ "$SKIP_PFCTL" = "1" ]; then
    return 0
  fi

  if ! pf_enabled; then
    /sbin/pfctl -E >/dev/null
  fi

  /sbin/pfctl -f "$MAIN_CONF" >/dev/null
}

write_main_conf() {
  ensure_dir "$(dirname "$MAIN_CONF")"
  tmp="$(make_tmp)"
  render_main >"$tmp"
  validate_main_conf "$tmp"
  chmod 600 "$tmp"

  if [ -f "$MAIN_CONF" ] && cmp -s "$tmp" "$MAIN_CONF"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$MAIN_CONF"
}

write_system_main_conf() {
  ensure_dir "$(dirname "$ETC_MAIN_CONF")"
  tmp="$(make_tmp)"
  render_main_with_paths "$(base_conf_source "$ETC_MAIN_BACKUP" "$ETC_MAIN_CONF" "$MAIN_CONF")" "$ETC_ANCHOR_CONF" >"$tmp"
  validate_main_conf "$tmp"
  chmod 600 "$tmp"

  if [ -f "$ETC_MAIN_CONF" ] && cmp -s "$tmp" "$ETC_MAIN_CONF"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$ETC_MAIN_CONF"
}

render_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALLED_SCRIPT</string>
    <string>daemon</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>WatchPaths</key>
  <array>
    <string>$MAIN_CONF</string>
    <string>$ANCHOR_CONF</string>
    <string>/etc/pf.conf</string>
  </array>
</dict>
</plist>
EOF
}

write_plist() {
  ensure_dir "$LAUNCHD_DIR"
  render_plist | write_if_changed "$PLIST_PATH" 644
}

install_script() {
  ensure_dir "$INSTALL_DIR"
  if [ "$SELF_PATH" != "$INSTALLED_SCRIPT" ]; then
    cp "$SELF_PATH" "$INSTALLED_SCRIPT"
  fi
  chmod 755 "$INSTALLED_SCRIPT"
}

bootstrap_launchd() {
  if [ "$LAUNCHD_BOOTSTRAP" != "1" ]; then
    return 0
  fi

  if ! /bin/launchctl bootout system "$PLIST_PATH"; then
    warn "launchctl bootout failed for $PLIST_PATH; continuing with bootstrap"
  fi
  /bin/launchctl bootstrap system "$PLIST_PATH"
  /bin/launchctl enable "system/$LABEL"
  /bin/launchctl kickstart -k "system/$LABEL" >/dev/null
}

bootout_launchd() {
  if [ "$LAUNCHD_BOOTSTRAP" != "1" ]; then
    return 0
  fi

  if ! /bin/launchctl bootout system "$PLIST_PATH"; then
    warn "launchctl bootout failed for $PLIST_PATH"
  fi
}

cmd_install() {
  require_root
  install_script
  ensure_base_backup
  ensure_system_backups
  write_anchor
  write_system_anchor
  write_main_conf
  write_system_main_conf
  write_plist
  load_pf
  bootstrap_launchd
}

cmd_apply() {
  require_root
  ensure_base_backup
  ensure_system_backups
  write_anchor
  write_system_anchor
  write_main_conf
  write_system_main_conf
  load_pf
}

cmd_daemon() {
  require_root
  ensure_base_backup
  ensure_system_backups
  write_anchor
  write_system_anchor
  write_main_conf
  write_system_main_conf

  if ! pf_enabled || ! anchor_loaded || ! managed_rules_loaded; then
    load_pf
  fi
}

cmd_uninstall() {
  require_root
  bootout_launchd
  rm -f "$PLIST_PATH"

  if [ -f "$BASE_BACKUP" ]; then
    ensure_dir "$(dirname "$MAIN_CONF")"
    cp "$BASE_BACKUP" "$MAIN_CONF"
    chmod 600 "$MAIN_CONF"
    if [ "$SKIP_PFCTL" != "1" ]; then
      /sbin/pfctl -f "$MAIN_CONF" >/dev/null
    fi
  fi

  if [ -f "$ETC_MAIN_BACKUP" ]; then
    ensure_dir "$(dirname "$ETC_MAIN_CONF")"
    cp "$ETC_MAIN_BACKUP" "$ETC_MAIN_CONF"
    chmod 600 "$ETC_MAIN_CONF"
  fi

  if [ -s "$ETC_ANCHOR_BACKUP" ]; then
    ensure_dir "$(dirname "$ETC_ANCHOR_CONF")"
    cp "$ETC_ANCHOR_BACKUP" "$ETC_ANCHOR_CONF"
    chmod 600 "$ETC_ANCHOR_CONF"
  else
    rm -f "$ETC_ANCHOR_CONF"
  fi

  rm -f "$BASE_BACKUP"
  rm -f "$ETC_MAIN_BACKUP"
  rm -f "$ETC_ANCHOR_BACKUP"
  rm -f "$ANCHOR_CONF"
  rm -f "$INSTALLED_SCRIPT"
  if ! rmdir "$INSTALL_DIR"; then
    warn "could not remove $INSTALL_DIR"
  fi
  if ! rmdir "$STATE_DIR"; then
    warn "could not remove $STATE_DIR"
  fi
}

cmd_status() {
  printf 'label: %s\n' "$LABEL"
  printf 'current_script: %s\n' "$SELF_PATH"
  printf 'managed_main_conf: %s\n' "$MAIN_CONF"
  printf 'anchor_conf: %s\n' "$ANCHOR_CONF"
  printf 'base_backup: %s\n' "$BASE_BACKUP"
  printf 'etc_main_conf: %s\n' "$ETC_MAIN_CONF"
  printf 'etc_main_backup: %s\n' "$ETC_MAIN_BACKUP"
  printf 'etc_anchor_conf: %s\n' "$ETC_ANCHOR_CONF"
  printf 'etc_anchor_backup: %s\n' "$ETC_ANCHOR_BACKUP"
  printf 'launchd_plist: %s\n' "$PLIST_PATH"
  printf 'installed_script: %s\n' "$INSTALLED_SCRIPT"
  printf 'main_conf_exists: %s\n' "$( [ -f "$MAIN_CONF" ] && printf yes || printf no )"
  printf 'anchor_exists: %s\n' "$( [ -f "$ANCHOR_CONF" ] && printf yes || printf no )"
  printf 'base_backup_exists: %s\n' "$( [ -f "$BASE_BACKUP" ] && printf yes || printf no )"
  printf 'etc_main_conf_exists: %s\n' "$( [ -f "$ETC_MAIN_CONF" ] && printf yes || printf no )"
  printf 'etc_main_backup_exists: %s\n' "$( [ -f "$ETC_MAIN_BACKUP" ] && printf yes || printf no )"
  printf 'etc_anchor_conf_exists: %s\n' "$( [ -f "$ETC_ANCHOR_CONF" ] && printf yes || printf no )"
  printf 'etc_anchor_backup_exists: %s\n' "$( [ -f "$ETC_ANCHOR_BACKUP" ] && printf yes || printf no )"
  printf 'launchd_plist_exists: %s\n' "$( [ -f "$PLIST_PATH" ] && printf yes || printf no )"
  printf 'managed_marker_present: %s\n' "$( managed_file "$MAIN_CONF" && printf yes || printf no )"
  printf 'etc_managed_marker_present: %s\n' "$( managed_file "$ETC_MAIN_CONF" && printf yes || printf no )"
  printf 'installed_script_needs_update: %s\n' "$( installed_script_needs_update && printf yes || printf no )"

  if [ "$SKIP_PFCTL" = "1" ]; then
    printf 'pf_enabled: skipped\n'
    printf 'main_anchor_loaded: skipped\n'
    printf 'live_rule_marker_loaded: skipped\n'
  elif pf_enabled; then
    printf 'pf_enabled: yes\n'
    printf 'main_anchor_loaded: %s\n' "$( anchor_loaded && printf yes || printf no )"
    printf 'live_rule_marker_loaded: %s\n' "$( managed_rules_loaded && printf yes || printf no )"
  else
    printf 'pf_enabled: no\n'
    printf 'main_anchor_loaded: no\n'
    printf 'live_rule_marker_loaded: no\n'
  fi
}

command="${1:-help}"

case "$command" in
  install)
    cmd_install
    ;;
  uninstall)
    cmd_uninstall
    ;;
  apply)
    cmd_apply
    ;;
  daemon)
    cmd_daemon
    ;;
  status)
    cmd_status
    ;;
  render-anchor)
    render_anchor
    ;;
  render-main)
    render_main
    ;;
  render-plist)
    render_plist
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
