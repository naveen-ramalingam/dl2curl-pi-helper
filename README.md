# Raspberry Pi Health & Disk Space Helper for dl2curl → Aria2 RPC

Because the standard Aria2 JSON-RPC protocol (`aria2c --enable-rpc`) does not expose host operating system metrics, this optional helper gives your Chrome extension direct real-time visibility into your Raspberry Pi and external drive.

---

## What It Reports

- **Live Disk Capacity & Available Space**: Real-time stats on `/mnt/hdd/Downloads` (Total GB/TB, Free GB/TB, Used GB/TB, % Free).
- **External Drive Mount Verification**: Checks if `/mnt/hdd/Downloads` is an actual mounted filesystem (preventing Aria2 from accidentally downloading onto the root MicroSD card if the USB drive unplugs or powers down).
- **Write Permission Test**: Catches USB hard drives that remount as **Read-Only** after dirty unmounts or power glitches.
- **CPU Temperature (°C)**: Thermal monitoring for heavy multi-connection downloading or archive extraction (7z/rar).
- **Under-Voltage / Throttling Detection**: Alerts you if an external USB drive draws too much power over USB without a powered hub.
- **RAM / Memory Usage**: Total, free, and available MB.
- **CPU Load & System Uptime**: 1m/5m load averages and uptime.
- **Aria2c Daemon Running Check**: Confirms the `aria2c` background process is active.

---

## ⚡ 1-Minute Auto-Boot Installation (Recommended)

Run this single command on your Raspberry Pi terminal (or via SSH):

```bash
curl -sSL https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/install.sh | sudo bash
```

### What this does:
1. Installs the standalone microservice to `/opt/dl2curl-pi/diskspace.py`.
2. Creates and enables the systemd service `/etc/systemd/system/dl2curl-diskspace.service` to **automatically start on every system boot**.
3. If Apache is installed on your Pi (`/var/www/html`), it also copies `diskspace.php` so you can query it via Port 80.
4. Starts the service immediately on port `6801`.

After running the script, in the Chrome extension settings:
- Set **Pi disk space script URL** to: `http://<your-pi-ip>:6801/diskspace` (or `http://<your-pi-ip>/diskspace.php`)
- Click **Save settings** and **Check Space**.

---

## ⚙️ Service Control

```bash
# Check service status
sudo systemctl status dl2curl-diskspace

# Restart service
sudo systemctl restart dl2curl-diskspace

# Stop service
sudo systemctl stop dl2curl-diskspace

# View logs
sudo journalctl -u dl2curl-diskspace -f
```

---

## ℹ️ Is This Service Required?

**No, it is 100% optional.**
If you do not install this helper:
- The extension works completely normally.
- It will simply use the **Manual free space fallback (GB)** value entered in Settings (e.g. `50` or `450` GB) to protect against out-of-disk-space downloads.
- When the helper is active, you get live telemetry and system health diagnostics in the extension header.

---

## 🌐 Public Provider & Deployment

Since the main extension repository is private, the helper installer is hosted on a public repository for unauthenticated curl installation:
- **Public Repo**: [https://github.com/naveen-ramalingam/dl2curl-pi-helper](https://github.com/naveen-ramalingam/dl2curl-pi-helper)
- **Deployment & Sync Guide**: See [DEPLOYMENT.md](./DEPLOYMENT.md) for details on GitHub Actions automatic sync and credential configuration.

