# Raspberry Pi Health & Disk Space Helper for dl2curl → Aria2 RPC

Current helper release: **1.3.5**. Helper releases are versioned separately from the Chrome extension.

Because the standard Aria2 JSON-RPC protocol (`aria2c --enable-rpc`) does not expose host operating system metrics, this optional helper gives your Chrome extension direct real-time visibility into your Raspberry Pi and external drive.

---

## What It Reports

- **Live Disk Capacity & Available Space**: Real-time stats on `/mnt/hdd/Downloads` (Total GB/TB, Free GB/TB, Used GB/TB, % Free).
- **External Drive Mount Verification**: Checks whether the download location is on a mounted filesystem. With pre-send disk checks enabled, the extension warns if a location under `/mnt` or `/media` has fallen back to the root filesystem.
- **Write Permission Test**: Detects read-only locations and warns in the extension before sending a download, including downloads whose size is unknown.
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
   - Sets up authentication with the fixed default token `dl2curl-aria2`, or lets you generate a random token or enter your own custom secret.
   - Creates and enables `/etc/systemd/system/aria2.service` to auto-start on system boot.
   - Asks whether to install and enable optional UPnP torrent port mapping. The default on fresh installs is **No**; declining keeps automatic port mapping disabled.
3. **dl2curl Health & Disk Space Microservice**:
   - Installs the standalone microservice to `/opt/dl2curl-pi/diskspace.py`.
   - Creates and enables `/etc/systemd/system/dl2curl-diskspace.service` to automatically run on port `6801` on every system boot.
   - If Apache is installed on your Pi (`/var/www/html`), also copies `diskspace.php`.
4. **Configuration Summary**:
   - Prints your Raspberry Pi IP, Aria2 RPC URL, RPC Secret, and Health Helper URL ready to copy into your Chrome extension settings.

After running the script, in the Chrome extension settings:
- Set **Aria2 RPC URL** to: `http://<your-pi-ip>:6800/jsonrpc`
- Set **Aria2 RPC Secret** to: `dl2curl-aria2` (or your saved custom token)
- Set **Download directory** to: `<your-selected-storage-path>`
- Set **Pi disk space script URL** to: `http://<your-pi-ip>:6801/diskspace` (or `http://<your-pi-ip>/diskspace.php`)
- Click **Save settings** and **Test connection**.

For the Python service on its default port, you can leave **Pi disk space script
URL** blank: the extension automatically tries the configured RPC host on port
`6801`. Set an explicit URL for a custom helper port, HTTPS, or the PHP alternative.
The RPC secret still needs to match your saved Aria2 configuration; fresh installs
use `dl2curl-aria2`.

The helper supports concurrent checks and returns uncached disk metrics. Its
lightweight `http://<your-pi-ip>:6801/health` endpoint reports service availability
and helper version without probing or writing to the drive. Disk and system
metrics remain available at `/diskspace?path=<download-directory>`.

Reconfiguration preserves saved RPC and helper ports unless changed explicitly.
Updates verify the Python script before replacing it; a failed download or invalid
script keeps the previously installed helper. Re-running setup repairs a missing
or stopped health service rather than skipping setup solely because Aria2 is active.

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
* UPnP package availability, enabled/disabled setting, and configured torrent port
* Live Aria2 daemon running state

### Quick Flags:
```bash
dl2curl token    # Print only the raw secret token (easy to copy)
dl2curl tasks    # View active torrents and download speeds
sudo dl2curl settings  # Keep, generate, or manually change the saved RPC secret
dl2curl upnp status   # Show UPnP installation and enabled/disabled state
dl2curl version       # Show CLI and installed helper versions
dl2curl check-updates # Show the latest helper and extension versions on GitHub
dl2curl menu          # Interactive version/update/token/UPnP menu
sudo dl2curl update   # Update just the helper and CLI to the latest tagged release
```

The installer uses the fixed RPC secret `dl2curl-aria2` by default and saves it in
`/etc/aria2/aria2.conf`. Re-running the installer preserves the saved secret
or disabled authentication unless you explicitly choose to change it.
To change it later without
reconfiguring the rest of the server, run `sudo dl2curl settings` and choose
to keep the current secret, generate a new one, enter a custom secret, or
disable authentication. The service is restarted after the change, and the
new secret is shown for entering in the extension's **RPC Secret** setting.

To enter a token manually, run `sudo dl2curl settings`, choose **3 — Enter a new
secret**, and type it. After the Aria2 service restarts, enter the same token in
the extension's **RPC Secret**, save settings, and test the connection.

### Versions and Interactive Updates

Running `dl2curl` in an SSH terminal shows the installed helper and CLI versions,
the latest helper and extension releases on GitHub, and the last extension version
reported to the Python helper. It then opens an interactive menu. Choose **2** to
update the helper and CLI, **3** to change the RPC token, or **4** to manage UPnP.
`dl2curl menu` opens this menu explicitly, while `dl2curl status` prints status only.
The extension shows the connected helper's version in its health card.

An older installation needs this one-time bootstrap to gain the new menu:

```bash
curl -fsSL https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/install.sh | sudo bash -s -- update
```

Helper-only updates preserve the existing service configuration, RPC token,
download directory, ports and UPnP preference. Only the health service restarts.
The updater downloads a tagged helper release, verifies the script version,
backs up the installed files, and restores them if the health check fails.

The public `release.json` contains only the latest helper and extension version
numbers, so the Pi needs no GitHub login to check the private extension's version.
The **last connected extension** is the version most recently reported by an app
request; it is unknown until an updated extension connects, and resets when the
health service restarts. PHP reports the requesting app's version in its response.
If GitHub is unreachable, installed versions and local status still work.

### Optional Automatic Torrent Port Mapping

The installer asks `Install and enable automatic torrent port mapping (UPnP)? [y/N]`.
Choose **Yes** to install miniupnpc and enable automatic TCP/UDP mapping of the
configured torrent port. Press Enter or choose **No** to skip it. Existing saved
preferences are preserved on reruns unless you choose to change them.

You can manage this feature later:

```bash
dl2curl upnp status           # Show whether miniupnpc is installed and mapping is enabled
sudo dl2curl upnp install     # Install miniupnpc and helper scripts; mapping stays disabled if disabled
sudo dl2curl upnp enable      # Enable mapping now if Aria2 is running, and on future starts
sudo dl2curl upnp disable     # Disable future mapping and attempt to remove the current TCP/UDP mappings
sudo dl2curl upnp uninstall   # Disable mapping, remove miniupnpc, and remove the UPnP helper scripts
```

Enabling requires miniupnpc to be installed and a router that supports UPnP.
Disabling keeps the package available for later use. These commands preserve your
RPC token and download settings and do not restart Aria2 or interrupt downloads.
After uninstalling, run `install` followed by `enable` to restore the feature.
Only the configured torrent port is mapped; the RPC and health-helper ports are
not mapped by this feature.

Unattended fresh installs also skip UPnP by default. Explicitly opt in or out with
`sudo bash install.sh --non-interactive --enable-upnp` or
`sudo bash install.sh --non-interactive --disable-upnp`.

### Interactive Installer Menu:
When re-running the 1-line installer:
```bash
curl -sSL https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/install.sh | sudo bash
```
It detects your existing installation and offers an interactive menu:
* `[1] View Status & RPC Token (Quick View)`
* `[2] Reconfigure / Run Full Setup`
* `[3] View Live Active Downloads`
* `[4] Update helper and CLI only`
* `[5] Change RPC token`
* `[6] Exit`

When changing a helper release, update `VERSION`, the installer, Python and PHP
version constants together. Automated sync publishes a matching helper tag and
release. Extension releases refresh the public version metadata after publication.

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
