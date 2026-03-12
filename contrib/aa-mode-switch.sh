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
#   AA_PROXY_SERVICE       (default: aa-proxy-rs)
#   UMTPRD_BIN             (default: /usr/sbin/umtprd)
#   UMTPRD_CONF            (default: /var/run/umtprd.conf)
#   USB_GADGET_SCRIPT      (default: /var/run/S92usb_gadget)
#   AA_MUSIC_DIR           (default: /data/music)
#   MASS_IMAGE_PATH        (default: /data/music_mass.img)
#   MASS_MOUNT_DIR         (default: /tmp/aa-mass-mount)
#   MASS_IMAGE_SIZE_MB     (default: auto) | integer MB
#   MASS_IMAGE_MARGIN_MB   (default: 256)

set -eu

AA_MODE_SWITCH_LOG="${AA_MODE_SWITCH_LOG:-/var/log/aa-mode-switch.log}"
AA_MODE_SWITCH_DEBUG="${AA_MODE_SWITCH_DEBUG:-0}"

AA_PROXY_SERVICE="${AA_PROXY_SERVICE:-aa-proxy-rs}"
UMTPRD_BIN="${UMTPRD_BIN:-/usr/sbin/umtprd}"
UMTPRD_CONF="${UMTPRD_CONF:-/var/run/umtprd.conf}"
USB_GADGET_SCRIPT="${USB_GADGET_SCRIPT:-/var/run/S92usb_gadget}"
AA_MUSIC_DIR="${AA_MUSIC_DIR:-/data/music}"
MASS_IMAGE_PATH="${MASS_IMAGE_PATH:-/data/music_mass.img}"
MASS_MOUNT_DIR="${MASS_MOUNT_DIR:-/tmp/aa-mass-mount}"
MASS_IMAGE_SIZE_MB="${MASS_IMAGE_SIZE_MB:-auto}"
MASS_IMAGE_MARGIN_MB="${MASS_IMAGE_MARGIN_MB:-256}"
PIDFILE="/var/run/umtprd.pid"

CFGFS_BASE="/sys/kernel/config/usb_gadget"
MASS_GADGET_NAME="mass"
MASS_GADGET_PATH="$CFGFS_BASE/$MASS_GADGET_NAME"
ACCESSORY_GADGET_PATH="$CFGFS_BASE/accessory"

log() {
  ts="$(date '+%F %T' 2>/dev/null || true)"
  [ -n "$ts" ] || ts="-"
  mkdir -p "$(dirname "$AA_MODE_SWITCH_LOG")" >/dev/null 2>&1 || true
  printf '[aa-mode-switch] %s %s
' "$ts" "$*" | tee -a "$AA_MODE_SWITCH_LOG"
}

err() {
  ts="$(date '+%F %T' 2>/dev/null || true)"
  [ -n "$ts" ] || ts="-"
  mkdir -p "$(dirname "$AA_MODE_SWITCH_LOG")" >/dev/null 2>&1 || true
  printf '[aa-mode-switch] %s ERROR: %s
' "$ts" "$*" | tee -a "$AA_MODE_SWITCH_LOG" >&2
}

# initialize logging early
: > "$AA_MODE_SWITCH_LOG" 2>/dev/null || true
log "starting mode switch script"
if [ "$AA_MODE_SWITCH_DEBUG" = "1" ]; then
  set -x
  log "debug tracing enabled (set -x)"
fi

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

  pgrep -f "$(basename "$UMTPRD_BIN")" >/dev/null 2>&1
}

stop_umtprd() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" >/dev/null 2>&1 || true
    rm -f "$PIDFILE"
  fi
  pkill -f "$(basename "$UMTPRD_BIN")" >/dev/null 2>&1 || true
}

prepare_music_link() {
  mkdir -p "$AA_MUSIC_DIR"
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

get_free_space_mb() {
  target_dir="$1"
  df -Pm "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}'
}

get_dir_size_mb() {
  target_dir="$1"
  du -sm "$target_dir" 2>/dev/null | awk '{print $1}'
}

get_image_size_mb() {
  image="$1"
  if [ -f "$image" ]; then
    bytes="$(stat -c %s "$image" 2>/dev/null || echo 0)"
    echo $(( (bytes + 1024*1024 - 1) / (1024*1024) ))
  else
    echo 0
  fi
}

resolve_mass_image_size_mb() {
  image_parent="$(dirname "$MASS_IMAGE_PATH")"
  mkdir -p "$image_parent"
  free_mb="$(get_free_space_mb "$image_parent" || true)"

  if [ "$MASS_IMAGE_SIZE_MB" = "auto" ]; then
    music_mb="$(get_dir_size_mb "$AA_MUSIC_DIR" || true)"
    [ -n "$music_mb" ] || music_mb=0

    target_mb=$((music_mb + MASS_IMAGE_MARGIN_MB))
    [ "$target_mb" -lt 256 ] && target_mb=256

    if [ -n "$free_mb" ]; then
      cap_mb=$((free_mb - 64))
      [ "$cap_mb" -lt 128 ] && cap_mb=128
      if [ "$target_mb" -gt "$cap_mb" ]; then
        target_mb="$cap_mb"
      fi
    fi

    echo "$target_mb"
    return 0
  fi

  echo "$MASS_IMAGE_SIZE_MB"
}

resolve_mkfs_fat_tool() {
  if command -v mkfs.vfat >/dev/null 2>&1; then
    echo "mkfs.vfat"
    return 0
  fi
  if command -v mkfs.fat >/dev/null 2>&1; then
    echo "mkfs.fat"
    return 0
  fi
  if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -q '^mkfs\.vfat$'; then
    echo "busybox mkfs.vfat"
    return 0
  fi
  return 1
}


ensure_loop_devices() {
  if command -v modprobe >/dev/null 2>&1; then
    modprobe loop >/dev/null 2>&1 || true
  fi

  [ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237 >/dev/null 2>&1 || true
  [ -e /dev/loop0 ] || mknod /dev/loop0 b 7 0 >/dev/null 2>&1 || true
}


diagnose_loop_support() {
  log "loop diagnose: kernel=$(uname -r 2>/dev/null || echo unknown)"

  if [ -e /proc/devices ]; then
    if grep -q "[[:space:]]loop$" /proc/devices; then
      log "loop diagnose: loop block driver present in /proc/devices"
    else
      err "loop diagnose: loop block driver NOT present in /proc/devices"
      err "loop diagnose: kernel likely missing CONFIG_BLK_DEV_LOOP"
    fi
  fi

  if [ -d /sys/module/loop ]; then
    log "loop diagnose: /sys/module/loop exists"
  else
    err "loop diagnose: /sys/module/loop missing"
  fi

  if ls /dev/loop-control /dev/loop0 >/dev/null 2>&1; then
    log "loop diagnose: loop device nodes exist"
  else
    err "loop diagnose: /dev/loop-control or /dev/loop0 missing"
  fi

  if command -v losetup >/dev/null 2>&1; then
    losetup_out="$(losetup -f 2>&1 || true)"
    if [ -n "$losetup_out" ]; then
      log "loop diagnose: losetup -f => $losetup_out"
    else
      log "loop diagnose: losetup -f returned empty output"
    fi
  else
    err "loop diagnose: losetup binary missing"
  fi
}

mount_mass_image() {
  ensure_loop_devices

  if command -v losetup >/dev/null 2>&1; then
    loop_dev="$(losetup -f --show "$MASS_IMAGE_PATH" 2>/dev/null || true)"
    if [ -n "$loop_dev" ]; then
      if mount "$loop_dev" "$MASS_MOUNT_DIR" >/dev/null 2>&1; then
        printf '%s\n' "$loop_dev"
        return 0
      fi
      losetup -d "$loop_dev" >/dev/null 2>&1 || true
    fi
  fi

  if mount -o loop "$MASS_IMAGE_PATH" "$MASS_MOUNT_DIR" >/dev/null 2>&1; then
    printf '\n'
    return 0
  fi

  return 1
}

unmount_mass_mount_dir() {
  if mount | grep -q "on $MASS_MOUNT_DIR "; then
    umount "$MASS_MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}

unmount_mass_image() {
  loop_dev="$1"
  unmount_mass_mount_dir

  if [ -n "$loop_dev" ] && command -v losetup >/dev/null 2>&1; then
    losetup -d "$loop_dev" >/dev/null 2>&1 || true
  fi
}

create_or_resize_mass_image() {
  image_parent="$(dirname "$MASS_IMAGE_PATH")"
  mkdir -p "$image_parent"

  target_mb="$(resolve_mass_image_size_mb)"
  current_mb="$(get_image_size_mb "$MASS_IMAGE_PATH")"

  # validate target numeric
  case "$target_mb" in
    ''|*[!0-9]*)
      err "invalid MASS_IMAGE_SIZE_MB: $target_mb"
      return 1
      ;;
  esac

  free_mb="$(get_free_space_mb "$image_parent" || true)"
  needed_mb=$((target_mb + 64))
  if [ -n "$free_mb" ] && [ "$current_mb" -eq 0 ] && [ "$free_mb" -lt "$needed_mb" ]; then
    err "not enough free space to create mass image"
    log "Need ~${needed_mb}MB free, available: ${free_mb}MB"
    log "Hint: set smaller size, e.g.: MASS_IMAGE_SIZE_MB=512 /var/run/aa-mode-switch.sh mass"
    return 1
  fi

  if [ "$current_mb" -ne "$target_mb" ]; then
    log "(re)creating sparse mass image at $MASS_IMAGE_PATH (${target_mb}MB)"
    rm -f "$MASS_IMAGE_PATH"
    truncate -s "${target_mb}M" "$MASS_IMAGE_PATH"

    mkfs_tool="$(resolve_mkfs_fat_tool || true)"
    if [ -z "$mkfs_tool" ]; then
      err "mkfs.vfat/mkfs.fat not found"
      err "Install dosfstools in your firmware image (or provide busybox mkfs.vfat)."
      err "Without FAT formatter we cannot create USB mass-storage image."
      return 1
    fi

    # shellcheck disable=SC2086
    $mkfs_tool "$MASS_IMAGE_PATH" >/dev/null 2>&1
  fi
}

ensure_mass_image() {
  mkdir -p "$AA_MUSIC_DIR"
  mkdir -p "$MASS_MOUNT_DIR"

  log "mass image path: $MASS_IMAGE_PATH"
  if ! create_or_resize_mass_image; then
    return 1
  fi
  unmount_mass_mount_dir

  loop_dev="$(mount_mass_image || true)"
  if [ -z "$loop_dev" ] && ! mount | grep -q "on $MASS_MOUNT_DIR "; then
    err "could not mount mass image via loop device"
    diagnose_loop_support
    log "Hint: if loop driver is missing, rebuild image/kernel with CONFIG_BLK_DEV_LOOP=y (or module)"
    log "Hint: if module exists, ensure it can be loaded: modprobe loop"
    return 1
  fi

  mkdir -p "$MASS_MOUNT_DIR/Music"
  find "$MASS_MOUNT_DIR/Music" -mindepth 1 -maxdepth 1 -exec rm -rf {} + >/dev/null 2>&1 || true
  cp -a "$AA_MUSIC_DIR"/. "$MASS_MOUNT_DIR/Music"/ 2>/dev/null || true
  sync
  unmount_mass_image "$loop_dev"

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

  if ! ensure_mass_image; then
    err "mass mode failed while preparing image; see $AA_MODE_SWITCH_LOG"
    return 1
  fi

  if ! enable_mass_only_gadget; then
    err "mass mode failed while enabling gadget; see $AA_MODE_SWITCH_LOG"
    return 1
  fi

  log "Mass-storage mode requested"
}

switch_to_aa_mass() {
  log "Switching to Android Auto + USB Mass Storage mode"
  stop_umtprd
  service_do umtprd stop

  cleanup_mass_gadget
  service_do "$AA_PROXY_SERVICE" start

  if ! ensure_mass_image; then
    err "aa_mass failed while preparing mass image; see $AA_MODE_SWITCH_LOG"
    return 1
  fi

  if ! enable_mass_in_accessory_gadget; then
    err "Could not enable AA+Mass composite gadget"
    err "Hint: your platform may not support AA+Mass simultaneously (USB endpoint/function limit)."
    err "Hint: use 'mass' mode as fallback, or keep AA in 'aa' mode."
    return 1
  fi

  log "AA+Mass mode requested (requires HU and gadget support)"
}

case "${1:-}" in
  aa) switch_to_aa ;;
  media) switch_to_media ;;
  both) switch_to_both ;;
  mass) switch_to_mass ;;
  aa_mass) switch_to_aa_mass ;;
  *)
    echo "Usage: $0 {aa|media|both|mass|aa_mass}" >&2
    exit 2
    ;;
esac
