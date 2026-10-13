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

### What this does (Interactive Wizard):
1. **Interactive Storage Drive Selection**:
   - Scans all mounted storage drives and partitions (USB hard drives, external SSDs, SD card).
   - Displays real-time total and free storage space.
   - Lets you choose your preferred storage location (or enter a custom directory) and verifies write permissions.
2. **Aria2 Detection & Installation**:
   - Detects whether `aria2` (`aria2c`) is installed.
   - If missing, offers 1-click automatic installation via package manager (`apt-get`, `pacman`, `dnf`, `apk`).
   - Configures `/etc/aria2/aria2.conf` with optimized multi-connection settings (16 splits, 16 connections, session persistence).
   - Sets up authentication with an auto-generated secure token or your own custom secret.
   - Creates and enables `/etc/systemd/system/aria2.service` to auto-start on system boot.
3. **dl2curl Health & Disk Space Microservice**:
   - Installs the standalone microservice to `/opt/dl2curl-pi/diskspace.py`.
   - Creates and enables `/etc/systemd/system/dl2curl-diskspace.service` to automatically run on port `6801` on every system boot.
   - If Apache is installed on your Pi (`/var/www/html`), also copies `diskspace.php`.
4. **Configuration Summary**:
   - Prints your Raspberry Pi IP, Aria2 RPC URL, RPC Secret, and Health Helper URL ready to copy into your Chrome extension settings.

After running the script, in the Chrome extension settings:
- Set **Aria2 RPC URL** to: `http://<your-pi-ip>:6800/jsonrpc`
- Set **Aria2 RPC Secret** to: `<your-secret-token>`
- Set **Download directory** to: `<your-selected-storage-path>`
- Set **Pi disk space script URL** to: `http://<your-pi-ip>:6801/diskspace` (or `http://<your-pi-ip>/diskspace.php`)
- Click **Save settings** and **Test connection**.

---

## 🔍 Quick Status & RPC Token in SSH Terminal

Whenever connected to your Pi via SSH, run the shortcut:

```bash
dl2curl
```

This displays a clean status card with your:
* Host IP address
* Aria2 RPC URL & **RPC Secret Token**
* Download directory
* Health Helper URL & port
* Live UPnP router port mapping status
* Live Aria2 daemon running state

### Quick Flags:
```bash
dl2curl token    # Print only the raw secret token (easy to copy)
dl2curl tasks    # View active torrents and download speeds
```

### Interactive Installer Menu:
When re-running the 1-line installer:
```bash
curl -sSL https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/install.sh | sudo bash
```
It detects your existing installation and offers an interactive menu:
* `[1] View Status & RPC Token (Quick View)`
* `[2] Reconfigure / Run Full Setup`
* `[3] View Live Active Downloads`
* `[4] Exit`

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

