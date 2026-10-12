#!/usr/bin/env bash
# ==============================================================================
# dl2curl → Aria2: Raspberry Pi Health & Disk Space Auto-Boot Installer
# ==============================================================================
# Installs the optional dl2curl helper service on your Raspberry Pi with
# automatic start on system boot via systemd.
#
# Quick 1-Line Run on your Pi:
#   curl -sSL https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/install.sh | sudo bash
# ==============================================================================

set -euo pipefail

PORT="${1:-6801}"
DOWNLOADS_DIR="${2:-/mnt/hdd/Downloads}"
INSTALL_DIR="/opt/dl2curl-pi"
SERVICE_NAME="dl2curl-diskspace"

echo "========================================================"
echo " 🚀 dl2curl Pi Health & Disk Space Auto-Boot Installer"
echo "========================================================"
echo "Target port:      $PORT"
echo "Download folder:  $DOWNLOADS_DIR"
echo ""

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root: sudo bash install.sh"
  exit 1
fi

# 1. Create install directory
echo "📁 Setting up $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# 2. Check if diskspace.py exists locally in same directory or download from repo
SCRIPT_SRC="$(dirname "$0")/diskspace.py"
if [ -f "$SCRIPT_SRC" ]; then
  cp "$SCRIPT_SRC" "$INSTALL_DIR/diskspace.py"
else
  echo "⬇ Downloading diskspace.py from repository..."
  curl -sSL "https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/diskspace.py" -o "$INSTALL_DIR/diskspace.py"
fi
chmod +x "$INSTALL_DIR/diskspace.py"

# 3. If Apache is installed, also copy PHP helper to /var/www/html/ if available
PHP_SRC="$(dirname "$0")/diskspace.php"
if [ -d "/var/www/html" ]; then
  echo "🌐 Apache / Web server directory detected at /var/www/html"
  if [ -f "$PHP_SRC" ]; then
    cp "$PHP_SRC" "/var/www/html/diskspace.php"
    chmod 644 "/var/www/html/diskspace.php"
    echo "   ✓ Copied PHP helper to /var/www/html/diskspace.php (Port 80)"
  else
    echo "⬇ Downloading diskspace.php from repository..."
    curl -sSL "https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/diskspace.php" -o "/var/www/html/diskspace.php" 2>/dev/null || true
    chmod 644 "/var/www/html/diskspace.php" 2>/dev/null || true
  fi
fi

# 4. Create systemd auto-boot service
echo "⚙ Configuring systemd auto-boot service ($SERVICE_NAME)..."
cat <<EOF > "/etc/systemd/system/${SERVICE_NAME}.service"
[Unit]
Description=dl2curl Aria2 Pi Health & Disk Space Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/diskspace.py ${PORT} ${DOWNLOADS_DIR}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 5. Reload systemd, enable on boot, and start immediately
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 1

# 6. Verify service status
if systemctl is-active --quiet "$SERVICE_NAME"; then
  IP_ADDR=$(hostname -I | awk '{print $1}')
  echo ""
  echo "========================================================"
  echo " ✅ dl2curl Helper installed and RUNNING successfully!"
  echo "========================================================"
  echo "Service status:   Active (Running) and Enabled on boot"
  echo "Primary URL:      http://${IP_ADDR}:${PORT}/diskspace"
  if [ -f "/var/www/html/diskspace.php" ]; then
    echo "Apache PHP URL:   http://${IP_ADDR}/diskspace.php"
  fi
  echo ""
  echo "👉 Enter this URL into your Chrome Extension Settings under:"
  echo "   'Pi disk space script URL': http://${IP_ADDR}:${PORT}/diskspace"
  echo "========================================================"
else
  echo "⚠ Service was created but could not start automatically. Check: journalctl -u $SERVICE_NAME"
  exit 1
fi
