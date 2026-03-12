# Local Music + Android Auto Setup (Single-File Guide)

This is the **single checklist** to get `aa-proxy-rs` running with:
- Android Auto (`aa` mode)
- Local USB MTP music (`media` mode)
- Combined MTP (`both` mode) when your head unit supports both together
- USB Mass Storage (`mass` mode)
- Android Auto + USB Mass Storage (`aa_mass` mode, platform/HU dependent)

---

## 0) Prerequisites

- Raspberry Pi image with `aa-proxy-rs` installed.
- `umtprd` available on the image.
- Device reachable on local network (default often `10.0.0.1`).

---

## 1) Build `aa-proxy-rs`

Run on your build machine (inside this repo):

```bash
cargo build --release
```

If you are cross-compiling, use your target triple:

```bash
cargo build --release --target <your-target-triple>
```

---

## 2) Install binary on Pi

Copy the binary to the Pi:

```bash
scp target/<your-target-triple>/release/aa-proxy-rs root@10.0.0.1:/usr/bin/aa-proxy-rs
```

If native-built for Pi on-device:

```bash
sudo cp target/release/aa-proxy-rs /usr/bin/aa-proxy-rs
```

---

## 3) Generate runtime system configs/scripts on Pi

This step is important. It generates:
- `/var/run/hostapd.conf`
- `/var/run/umtprd.conf`
- `/var/run/S92usb_gadget`
- `/var/run/aa-mode-switch.sh`

Run on Pi:

```bash
sudo aa-proxy-rs --generate-system-config
```

Verify generated files:

```bash
ls -l /var/run/hostapd.conf /var/run/umtprd.conf /var/run/S92usb_gadget /var/run/aa-mode-switch.sh
```

---

## 4) Start/restart service

```bash
sudo systemctl restart aa-proxy-rs
sudo systemctl status aa-proxy-rs --no-pager
```

If your image uses init.d:

```bash
sudo /etc/init.d/aa-proxy-rs restart
```

---

## 5) Open Web UI

From phone/laptop connected to aa-proxy network:

```text
http://10.0.0.1
```

Use the action buttons in UI:
- **USB mode: Android Auto** (`aa`)
- **USB mode: Local music** (`media`)
- **USB mode: Both (AA + MTP)** (`both`)
- **USB mode: Mass storage** (`mass`)
- **USB mode: Android Auto + Mass** (`aa_mass`)

---

## 6) Prepare music archive (on your computer)

Put your songs in a folder and create tar.gz:

```bash
mkdir -p music
cp /path/to/your/*.mp3 music/
tar -czf my-music.tar.gz -C music .
```

---

## 7) Upload songs (no SSH needed)

Preferred: from Web UI click **Upload music archive (.tar.gz)** and choose `my-music.tar.gz`.

Alternative with curl (if needed):

```bash
curl -X POST \
  -H "Content-Type: application/gzip" \
  --data-binary @my-music.tar.gz \
  http://10.0.0.1/upload-music
```

Songs are extracted to:

```text
/data/music
```

Mass image file path (used by `mass`/`aa_mass`):

```text
/data/music_mass.img
```

Mass mode uses an image file (default `/data/music_mass.img`) and **does not require a separate partition**.
By default image sizing is dynamic (`MASS_IMAGE_SIZE_MB=auto`): it scales based on `/data/music` size and free space.
If storage is tight, force a smaller image size before first `mass` run:

```bash
export MASS_IMAGE_SIZE_MB=512
sudo /var/run/aa-mode-switch.sh mass
```

---

## 8) Mode switch quick commands (optional fallback)

If ever needed from shell on Pi:

```bash
sudo /var/run/aa-mode-switch.sh aa
sudo /var/run/aa-mode-switch.sh media
sudo /var/run/aa-mode-switch.sh both
sudo /var/run/aa-mode-switch.sh mass
sudo /var/run/aa-mode-switch.sh aa_mass
```

---

## 9) Troubleshooting commands

Check aa-proxy logs:

```bash
sudo journalctl -u aa-proxy-rs -n 200 --no-pager
```

Check aa-mode-switch log:

```bash
sudo tail -n 200 /var/log/aa-mode-switch.log
```

Enable verbose tracing for one run:

```bash
sudo AA_MODE_SWITCH_DEBUG=1 /var/run/aa-mode-switch.sh mass
```

Check if `umtprd` is running:

```bash
ps -ef | grep umtprd | grep -v grep
```

If `mass` mode shows loop-device errors, check loop support:

```bash
sudo modprobe loop || true
ls -l /dev/loop-control /dev/loop0
```

If first `mass` run fails with `No space left on device`, recreate with smaller image:

```bash
rm -f /data/music_mass.img
MASS_IMAGE_SIZE_MB=512 sudo /var/run/aa-mode-switch.sh mass
```

If `both` mode fails with FunctionFS error, do this sequence:

```bash
sudo /var/run/aa-mode-switch.sh media
sudo /var/run/aa-mode-switch.sh both
```

If `aa_mass` fails, your USB controller/HU likely does not support composite AA+Mass together.
Use one of these stable fallbacks:

```bash
sudo /var/run/aa-mode-switch.sh aa
# or
sudo /var/run/aa-mode-switch.sh mass
```

---

## 10) Daily usage (simple)

1. Car starts, Pi powers up.
2. Open Web UI only when needed.
3. Press **Both (AA + Music)** for simultaneous mode.
4. Use head unit USB audio player for local MP3 from `/data/music`.
5. Use Android Auto as usual.
