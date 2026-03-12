#!/bin/sh
# Toggle between Android Auto proxy mode and local USB music modes.
#
# Usage:
#   aa-mode-switch.sh aa
#   aa-mode-switch.sh media
#   aa-mode-switch.sh both
#   aa-mode-switch.sh mass
#   aa-mode-switch.sh aa_mass
#
# Optional env vars:
#   AA_PROXY_SERVICE      (default: aa-proxy-rs)
#   UMTPRD_BIN            (default: /usr/sbin/umtprd)
#   UMTPRD_CONF           (default: /var/run/umtprd.conf)
#   USB_GADGET_SCRIPT     (default: /var/run/S92usb_gadget)
#   AA_MUSIC_DIR          (default: /data/music)
#   MASS_IMAGE_PATH       (default: /data/music_mass.img)
#   MASS_MOUNT_DIR        (default: /tmp/aa-mass-mount)
#   MASS_IMAGE_SIZE_MB    (default: 4096)

set -eu

AA_PROXY_SERVICE="${AA_PROXY_SERVICE:-aa-proxy-rs}"
UMTPRD_BIN="${UMTPRD_BIN:-/usr/sbin/umtprd}"
UMTPRD_CONF="${UMTPRD_CONF:-/var/run/umtprd.conf}"
USB_GADGET_SCRIPT="${USB_GADGET_SCRIPT:-/var/run/S92usb_gadget}"
AA_MUSIC_DIR="${AA_MUSIC_DIR:-/data/music}"
MASS_IMAGE_PATH="${MASS_IMAGE_PATH:-/data/music_mass.img}"
MASS_MOUNT_DIR="${MASS_MOUNT_DIR:-/tmp/aa-mass-mount}"
MASS_IMAGE_SIZE_MB="${MASS_IMAGE_SIZE_MB:-4096}"
PIDFILE="/var/run/umtprd.pid"

CFGFS_BASE="/sys/kernel/config/usb_gadget"
MASS_GADGET_NAME="mass"
MASS_GADGET_PATH="$CFGFS_BASE/$MASS_GADGET_NAME"
ACCESSORY_GADGET_PATH="$CFGFS_BASE/accessory"

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

is_umtprd_running() {
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if pgrep -f "$(basename "$UMTPRD_BIN")" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

stop_umtprd() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" >/dev/null 2>&1 || true
    rm -f "$PIDFILE"
  fi
  pkill -f "$(basename "$UMTPRD_BIN")" >/dev/null 2>&1 || true
}

prepare_music_link() {
  if [ ! -d "$AA_MUSIC_DIR" ]; then
    log "Creating missing music directory: $AA_MUSIC_DIR"
    mkdir -p "$AA_MUSIC_DIR"
  fi

  mkdir -p /tmp/aa-proxy-mtp
  rm -f /tmp/aa-proxy-mtp/music
  ln -s "$AA_MUSIC_DIR" /tmp/aa-proxy-mtp/music
}

start_umtprd_once() {
  if [ ! -x "$UMTPRD_BIN" ]; then
    log "ERROR: umtprd binary not found/executable at $UMTPRD_BIN"
    return 1
  fi

  if [ ! -f "$UMTPRD_CONF" ]; then
    log "ERROR: umtprd config not found at $UMTPRD_CONF"
    log "Hint: run aa-proxy-rs --generate-system-config once on target image"
    return 1
  fi

  prepare_music_link

  umtprd_log="$(mktemp /tmp/aa-mode-switch-umtprd.XXXXXX.log)"
  if "$UMTPRD_BIN" -c "$UMTPRD_CONF" -d >"$umtprd_log" 2>&1; then
    log "umtprd started with config: $UMTPRD_CONF"
    rm -f "$umtprd_log"
    return 0
  fi

  cat "$umtprd_log" >&2 || true
  rm -f "$umtprd_log"
  return 1
}

ensure_umtprd_running() {
  if is_umtprd_running; then
    log "umtprd is already running"
    return 0
  fi

  start_umtprd_once
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

get_udc_name() {
  ls /sys/class/udc 2>/dev/null | head -n 1
}

unmount_mass_mount_dir() {
  if mount | grep -q "on $MASS_MOUNT_DIR "; then
    umount "$MASS_MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}

ensure_mass_image() {
  if [ ! -d "$AA_MUSIC_DIR" ]; then
    mkdir -p "$AA_MUSIC_DIR"
  fi

  if [ ! -f "$MASS_IMAGE_PATH" ]; then
    log "Creating mass-storage image: $MASS_IMAGE_PATH (${MASS_IMAGE_SIZE_MB}MB)"
    dd if=/dev/zero of="$MASS_IMAGE_PATH" bs=1M count="$MASS_IMAGE_SIZE_MB" status=none

    if command -v mkfs.vfat >/dev/null 2>&1; then
      mkfs.vfat "$MASS_IMAGE_PATH" >/dev/null 2>&1
    elif command -v mkfs.fat >/dev/null 2>&1; then
      mkfs.fat "$MASS_IMAGE_PATH" >/dev/null 2>&1
    else
      log "ERROR: mkfs.vfat/mkfs.fat not found"
      return 1
    fi
  fi

  mkdir -p "$MASS_MOUNT_DIR"
  unmount_mass_mount_dir

  mount -o loop "$MASS_IMAGE_PATH" "$MASS_MOUNT_DIR"
  mkdir -p "$MASS_MOUNT_DIR/Music"

  # refresh image content from AA_MUSIC_DIR
  find "$MASS_MOUNT_DIR/Music" -mindepth 1 -maxdepth 1 -exec rm -rf {} + >/dev/null 2>&1 || true
  cp -a "$AA_MUSIC_DIR"/. "$MASS_MOUNT_DIR/Music"/ 2>/dev/null || true
  sync
  umount "$MASS_MOUNT_DIR"

  log "Mass-storage image synced from: $AA_MUSIC_DIR"
}

unbind_gadget_udc() {
  gadget_path="$1"
  if [ -f "$gadget_path/UDC" ]; then
    printf '\n' > "$gadget_path/UDC" 2>/dev/null || true
  fi
}

cleanup_mass_gadget() {
  if [ -d "$MASS_GADGET_PATH" ]; then
    unbind_gadget_udc "$MASS_GADGET_PATH"
    rm -f "$MASS_GADGET_PATH/configs/c.1/mass_storage.0" >/dev/null 2>&1 || true
    rmdir "$MASS_GADGET_PATH/functions/mass_storage.0" >/dev/null 2>&1 || true
    rmdir "$MASS_GADGET_PATH/configs/c.1/strings/0x409" >/dev/null 2>&1 || true
    rmdir "$MASS_GADGET_PATH/configs/c.1" >/dev/null 2>&1 || true
    rmdir "$MASS_GADGET_PATH/strings/0x409" >/dev/null 2>&1 || true
    rmdir "$MASS_GADGET_PATH" >/dev/null 2>&1 || true
  fi
}

enable_mass_only_gadget() {
  if [ ! -d "$CFGFS_BASE" ]; then
    log "ERROR: configfs usb_gadget path not found: $CFGFS_BASE"
    return 1
  fi

  udc="$(get_udc_name)"
  if [ -z "$udc" ]; then
    log "ERROR: no UDC found in /sys/class/udc"
    return 1
  fi

  cleanup_mass_gadget

  mkdir -p "$MASS_GADGET_PATH"
  printf '0x1d6b\n' > "$MASS_GADGET_PATH/idVendor"
  printf '0x0104\n' > "$MASS_GADGET_PATH/idProduct"
  printf '0x0100\n' > "$MASS_GADGET_PATH/bcdDevice"
  printf '0x0200\n' > "$MASS_GADGET_PATH/bcdUSB"

  mkdir -p "$MASS_GADGET_PATH/strings/0x409"
  printf 'aa-proxy\n' > "$MASS_GADGET_PATH/strings/0x409/manufacturer"
  printf 'aa-proxy mass storage\n' > "$MASS_GADGET_PATH/strings/0x409/product"
  printf 'mass-storage\n' > "$MASS_GADGET_PATH/strings/0x409/serialnumber"

  mkdir -p "$MASS_GADGET_PATH/configs/c.1/strings/0x409"
  printf 'MSC\n' > "$MASS_GADGET_PATH/configs/c.1/strings/0x409/configuration"
  printf 120 > "$MASS_GADGET_PATH/configs/c.1/MaxPower"

  mkdir -p "$MASS_GADGET_PATH/functions/mass_storage.0"
  printf 1 > "$MASS_GADGET_PATH/functions/mass_storage.0/stall"
  printf 0 > "$MASS_GADGET_PATH/functions/mass_storage.0/lun.0/ro"
  printf 0 > "$MASS_GADGET_PATH/functions/mass_storage.0/lun.0/cdrom"
  printf '%s\n' "$MASS_IMAGE_PATH" > "$MASS_GADGET_PATH/functions/mass_storage.0/lun.0/file"

  ln -sf "$MASS_GADGET_PATH/functions/mass_storage.0" "$MASS_GADGET_PATH/configs/c.1/mass_storage.0"

  printf '%s\n' "$udc" > "$MASS_GADGET_PATH/UDC"
  log "Mass-storage gadget bound to UDC: $udc"
}

disable_mass_in_accessory_gadget() {
  if [ -d "$ACCESSORY_GADGET_PATH" ]; then
    rm -f "$ACCESSORY_GADGET_PATH/configs/c.1/mass_storage.0" >/dev/null 2>&1 || true
    rmdir "$ACCESSORY_GADGET_PATH/functions/mass_storage.0" >/dev/null 2>&1 || true
  fi
}

enable_mass_in_accessory_gadget() {
  if [ ! -d "$ACCESSORY_GADGET_PATH" ]; then
    log "ERROR: accessory gadget missing at $ACCESSORY_GADGET_PATH"
    return 1
  fi

  udc="$(cat "$ACCESSORY_GADGET_PATH/UDC" 2>/dev/null || true)"

  mkdir -p "$ACCESSORY_GADGET_PATH/functions/mass_storage.0"
  printf 1 > "$ACCESSORY_GADGET_PATH/functions/mass_storage.0/stall"
  printf 0 > "$ACCESSORY_GADGET_PATH/functions/mass_storage.0/lun.0/ro"
  printf 0 > "$ACCESSORY_GADGET_PATH/functions/mass_storage.0/lun.0/cdrom"
  printf '%s\n' "$MASS_IMAGE_PATH" > "$ACCESSORY_GADGET_PATH/functions/mass_storage.0/lun.0/file"

  ln -sf "$ACCESSORY_GADGET_PATH/functions/mass_storage.0" "$ACCESSORY_GADGET_PATH/configs/c.1/mass_storage.0"

  # Rebind only if already bound
  if [ -n "$udc" ]; then
    printf '\n' > "$ACCESSORY_GADGET_PATH/UDC" 2>/dev/null || true
    sleep 0.2
    printf '%s\n' "$udc" > "$ACCESSORY_GADGET_PATH/UDC"
  fi

  log "Mass-storage function added to accessory gadget"
}

switch_to_aa() {
  log "Switching to Android Auto mode"
  stop_umtprd
  service_do umtprd stop

  cleanup_mass_gadget
  disable_mass_in_accessory_gadget

  usb_gadget_stop
  usb_gadget_start

  service_do "$AA_PROXY_SERVICE" restart
  log "Android Auto mode requested"
}

switch_to_media() {
  log "Switching to Local Music (MTP) mode"
  service_do "$AA_PROXY_SERVICE" stop

  stop_umtprd
  service_do umtprd stop

  cleanup_mass_gadget
  disable_mass_in_accessory_gadget

  usb_gadget_stop
  usb_gadget_start

  ensure_umtprd_running
  log "Media mode requested (HU must be set to USB media source)"
}

switch_to_both() {
  log "Switching to Combined mode (Android Auto + Local Music MTP)"

  cleanup_mass_gadget
  disable_mass_in_accessory_gadget

  service_do "$AA_PROXY_SERVICE" start

  if ! ensure_umtprd_running; then
    log "ERROR: Could not start umtprd in combined mode."
    log "Hint: if you see FunctionFS init errors, switch to 'media' once, then back to 'both'."
    return 1
  fi

  log "Combined mode requested (requires HU support for AA + USB media at the same time)"
}

switch_to_mass() {
  log "Switching to USB Mass Storage mode"

  service_do "$AA_PROXY_SERVICE" stop
  stop_umtprd
  service_do umtprd stop

  usb_gadget_stop

  ensure_mass_image
  enable_mass_only_gadget

  log "Mass-storage mode requested"
}

switch_to_aa_mass() {
  log "Switching to Android Auto + USB Mass Storage mode"

  stop_umtprd
  service_do umtprd stop

  cleanup_mass_gadget
  service_do "$AA_PROXY_SERVICE" start

  ensure_mass_image

  if ! enable_mass_in_accessory_gadget; then
    log "ERROR: Could not enable AA+Mass composite gadget"
    log "Hint: your platform may not support AA+Mass simultaneously; use 'mass' mode instead."
    return 1
  fi

  log "AA+Mass mode requested (requires HU and gadget support)"
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
  mass)
    switch_to_mass
    ;;
  aa_mass)
    switch_to_aa_mass
    ;;
  *)
    echo "Usage: $0 {aa|media|both|mass|aa_mass}" >&2
    exit 2
    ;;
esac
