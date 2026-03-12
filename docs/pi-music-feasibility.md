# Raspberry Pi local music playback feasibility (with `aa-proxy-rs`)

## Objective
Use the same Raspberry Pi Zero 2 W that runs `aa-proxy-rs` to play MP3 files from the Pi's SD card through the car head unit, reducing phone heat from media streaming.

## What `aa-proxy-rs` currently does
`aa-proxy-rs` is focused on Android Auto transport bridging (phone <-> Pi over BT/Wi-Fi, and Pi <-> head unit over USB accessory mode). It initializes USB gadget mode and switches to Android Open Accessory mode for Android Auto, not USB mass-storage playback.

The codebase also generates runtime config/templates for:
- `hostapd` (Wi-Fi AP)
- `umtprd` config
- USB gadget init script (`S92usb_gadget`)

That means the platform already has hooks for a USB media-facing mode (for head units that support MTP), but no built-in mode switch orchestrator.

## Feasibility options

### Option A (recommended): Dual-mode switch (Android Auto mode vs Local Music mode)
- **Android Auto mode**: run `aa-proxy-rs` normally.
- **Local Music mode**: stop `aa-proxy-rs`, expose Pi music folder over USB **MTP** via `umtprd`, let the head unit browse/play files directly from Pi storage.

Why this is recommended:
- Very low phone load (phone not streaming media).
- Reuses existing gadget + `umtprd` support already present in this project.
- Works on many (not all) head units that support USB MTP devices.

Trade-offs:
- Compatibility depends on the head unit USB stack: some units need mode switching, while others (like yours) can handle AA + USB media simultaneously.
- You still need a predictable way to control which services are running (`aa`, `media`, or `both`).

### Option B: USB Mass Storage gadget (LUN image/file)
Expose a block device image (FAT/exFAT) to HU.

Pros:
- Broad head-unit compatibility.

Cons:
- More operational complexity (safe unmount/sync, image management).
- Harder to keep a live directory view without rebuilding/syncing filesystem image.
- Easier to corrupt data if unplugged improperly.

### Option C: Keep Android Auto, but serve media from Pi to phone over local network
Phone runs a local media app (SMB/DLNA/Jellyfin client), streaming from Pi over local Wi-Fi only.

Pros:
- Keeps AA UI and controls.

Cons:
- Phone still does decode/render and some networking, so heat reduction is partial (not full elimination).

## Practical recommendation for your setup
Given your goal to *eliminate* phone streaming heat as much as possible, use **Option A** and treat the car HU as the direct media player. Since your HU supports simultaneous operation, prefer `both` mode for day-to-day use.

## Implementation added in this repository
This repository now provides an integrated mode switch workflow.
At runtime, `aa-proxy-rs --generate-system-config` injects `/var/run/aa-mode-switch.sh` automatically.

It supports:
- `aa` mode (Android Auto only)
- `media` mode (USB MTP local music only)
- `both` mode (Android Auto + USB MTP together, for head units that support simultaneous AA + USB audio)
- `mass` mode (USB Mass Storage; preferred for HUs that do not browse MTP content reliably, using `/data/music_mass.img`)
- `aa_mass` mode (Android Auto + USB Mass Storage; depends on gadget/HU support)

> The script is intentionally conservative and uses environment variables to match distro/service differences.

## Suggested deployment on Raspberry Pi image
1. Build image as usual (no manual script installation needed).
2. Ensure `umtprd` and gadget init script are present in your image.
3. On first boot, open the aa-proxy web interface.
4. Use mode buttons in UI (`aa`, `media`, `both`, `mass`, `aa_mass`) instead of shell commands.
5. Mass image size can be dynamic (`MASS_IMAGE_SIZE_MB=auto`) or fixed (e.g. `512`).


## Adding MP3 files after flashing (no SSH needed)
Use the embedded Web UI music uploader:

1. Prepare a tar.gz archive containing your music files/folders (for example `my-music.tar.gz`).
2. Open the aa-proxy web UI from your phone/laptop while connected to the device network.
3. Click **"Upload music archive (.tar.gz)"**.
4. Select the archive; it is automatically extracted to:
   - `/data/music`

Notes:
- You can upload folders; directory structure is preserved.
- Re-uploading will overwrite files with same paths.
- If `both` mode reports a FunctionFS init error, switch to `media` once and then back to `both` (this is now also hinted in backend logs).

## Validation checklist in your car
1. `media` mode: HU in USB media source should detect device and browse music.
2. `both` mode: verify Android Auto stays connected while HU can play local MP3 simultaneously.
3. `mass` mode: verify HU indexes files and playback works as if USB pen drive.
4. `aa_mass` mode: verify simultaneous AA + mass storage (if supported).
5. Play MP3 for at least 20–30 minutes; confirm phone is not actively streaming audio data.
6. Switch back to `aa` mode and verify normal auto-connect/reconnect works.
7. Repeat transitions multiple times to confirm stability.

## Future enhancement ideas
- Wire mode switch to GPIO button patterns.
- Add optional auto-switch policy (e.g., long press = media mode).
