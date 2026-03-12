# Local Music + Android Auto Setup (Single-File Guide)

This is the **single checklist** to get `aa-proxy-rs` running with:
- Android Auto (`aa` mode)
- Local USB MTP music (`media` mode)
- Combined mode (`both` mode) when your head unit supports both together

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
- **USB mode: Both (AA + Music)** (`both`)

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

---

## 8) Mode switch quick commands (optional fallback)

If ever needed from shell on Pi:

```bash
sudo /var/run/aa-mode-switch.sh aa
sudo /var/run/aa-mode-switch.sh media
sudo /var/run/aa-mode-switch.sh both
```

---

## 9) Troubleshooting commands

Check aa-proxy logs:

```bash
sudo journalctl -u aa-proxy-rs -n 200 --no-pager
```

Check if `umtprd` is running:

```bash
ps -ef | grep umtprd | grep -v grep
```

If `both` mode fails with FunctionFS error, do this sequence:

```bash
sudo /var/run/aa-mode-switch.sh media
sudo /var/run/aa-mode-switch.sh both
```

---

## 10) Daily usage (simple)

1. Car starts, Pi powers up.
2. Open Web UI only when needed.
3. Press **Both (AA + Music)** for simultaneous mode.
4. Use head unit USB audio player for local MP3 from `/data/music`.
5. Use Android Auto as usual.
