#!/bin/sh
# Toggle between Android Auto proxy mode and local USB MTP music mode.
#
# Usage:
#   aa-mode-switch.sh aa
#   aa-mode-switch.sh media
#   aa-mode-switch.sh both
#
# Optional env vars:
#   AA_PROXY_SERVICE   (default: aa-proxy-rs)
#   UMTPRD_BIN         (default: /usr/sbin/umtprd)
#   UMTPRD_CONF        (default: /var/run/umtprd.conf)
#   USB_GADGET_SCRIPT  (default: /var/run/S92usb_gadget)
#   AA_MUSIC_DIR       (default: /data/music)

set -eu

AA_PROXY_SERVICE="${AA_PROXY_SERVICE:-aa-proxy-rs}"
UMTPRD_BIN="${UMTPRD_BIN:-/usr/sbin/umtprd}"
UMTPRD_CONF="${UMTPRD_CONF:-/var/run/umtprd.conf}"
USB_GADGET_SCRIPT="${USB_GADGET_SCRIPT:-/var/run/S92usb_gadget}"
AA_MUSIC_DIR="${AA_MUSIC_DIR:-/data/music}"
PIDFILE="/var/run/umtprd.pid"

log() {
  printf '[aa-mode-switch] %s\n' "$*"
}

service_do() {
  svc="$1"
  action="$2"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl "$action" "$svc" >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service "$svc" "$action" >/dev/null 2>&1 || true
  elif [ -x "/etc/init.d/$svc" ]; then
    "/etc/init.d/$svc" "$action" >/dev/null 2>&1 || true
  fi
}

stop_umtprd() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" >/dev/null 2>&1 || true
    rm -f "$PIDFILE"
  fi
  pkill -f "$(basename "$UMTPRD_BIN")" >/dev/null 2>&1 || true
}

start_umtprd() {
  if [ ! -x "$UMTPRD_BIN" ]; then
    log "ERROR: umtprd binary not found/executable at $UMTPRD_BIN"
    exit 1
  fi

  if [ ! -f "$UMTPRD_CONF" ]; then
    log "ERROR: umtprd config not found at $UMTPRD_CONF"
    log "Hint: run aa-proxy-rs --generate-system-config once on target image"
    exit 1
  fi

  if [ ! -d "$AA_MUSIC_DIR" ]; then
    log "Creating missing music directory: $AA_MUSIC_DIR"
    mkdir -p "$AA_MUSIC_DIR"
  fi

  # Many umtprd templates read from a static path; keep a predictable mountpoint/link.
  mkdir -p /tmp/aa-proxy-mtp
  rm -f /tmp/aa-proxy-mtp/music
  ln -s "$AA_MUSIC_DIR" /tmp/aa-proxy-mtp/music

  "$UMTPRD_BIN" -c "$UMTPRD_CONF" -d
  log "umtprd started with config: $UMTPRD_CONF"
}

usb_gadget_start() {
  if [ -x "$USB_GADGET_SCRIPT" ]; then
    "$USB_GADGET_SCRIPT" start >/dev/null 2>&1 || true
  fi
}

usb_gadget_stop() {
  if [ -x "$USB_GADGET_SCRIPT" ]; then
    "$USB_GADGET_SCRIPT" stop >/dev/null 2>&1 || true
  fi
}

switch_to_aa() {
  log "Switching to Android Auto mode"
  stop_umtprd
  service_do umtprd stop

  usb_gadget_stop
  usb_gadget_start

  service_do "$AA_PROXY_SERVICE" restart
  log "Android Auto mode requested"
}

switch_to_media() {
  log "Switching to Local Music (MTP) mode"
  service_do "$AA_PROXY_SERVICE" stop

  usb_gadget_stop
  usb_gadget_start

  start_umtprd
  log "Media mode requested (HU must be set to USB media source)"
}

switch_to_both() {
  log "Switching to Combined mode (Android Auto + Local Music MTP)"

  # Keep/restart gadget once to ensure all gadget functions are applied.
  usb_gadget_stop
  usb_gadget_start

  # Keep Android Auto proxy running and also expose MTP media content.
  service_do "$AA_PROXY_SERVICE" restart
  start_umtprd

  log "Combined mode requested (requires HU support for AA + USB media at the same time)"
}


case "${1:-}" in
  aa)
    switch_to_aa
    ;;
  media)
    switch_to_media
    ;;
  both)
    switch_to_both
    ;;
  *)
    echo "Usage: $0 {aa|media|both}" >&2
    exit 2
    ;;
esac
