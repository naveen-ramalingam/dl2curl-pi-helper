#!/usr/bin/env bash
# ==============================================================================
# dl2curl → Aria2: Complete Installer & Interactive Setup for Linux / Raspberry Pi
# ==============================================================================
# Installs and configures:
#   1. Storage directory selection (scans mounted USB drives, SSDs, SD card)
#   2. Aria2 (aria2c) package installation (if not already installed)
#   3. Aria2 RPC daemon auto-boot systemd service & authentication
#   4. dl2curl Pi Health & Disk Space microservice on systemd
#
# Quick 1-Line Run on your Pi:
#   curl -sSL https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/install.sh | sudo bash
# ==============================================================================

set -uo pipefail

# ANSI color codes
if [ -t 1 ]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_CYAN="\033[36m"
  C_RED="\033[31m"
  C_BLUE="\033[34m"
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_RED=""
  C_BLUE=""
fi

# Ensure running as root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo -e "${C_RED}❌ Please run as root: sudo bash install.sh${C_RESET}"
  exit 1
fi

# If stdin was piped (e.g. curl ... | sudo bash), reconnect stdin to /dev/tty for interactive menus
INTERACTIVE=true
if [ ! -t 0 ]; then
  if [ -c /dev/tty ] && { exec < /dev/tty; } 2>/dev/null; then
    INTERACTIVE=true
  else
    INTERACTIVE=false
  fi
fi

# Defaults
DEFAULT_HELPER_PORT=6801
DEFAULT_RPC_PORT=6800
DEFAULT_DOWNLOADS_DIR="/mnt/hdd/Downloads"
INSTALL_DIR="/opt/dl2curl-pi"
SERVICE_NAME="dl2curl-diskspace"

CLI_PORT=""
CLI_DIR=""

# Parse command line options
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--non-interactive|--auto)
      INTERACTIVE=false
      ;;
    [0-9]*)
      [ -z "$CLI_PORT" ] && CLI_PORT="$arg"
      ;;
    /*)
      [ -z "$CLI_DIR" ] && CLI_DIR="$arg"
      ;;
    *)
      ;;
  esac
done

DOWNLOADS_DIR="${CLI_DIR:-$DEFAULT_DOWNLOADS_DIR}"
HELPER_PORT="${CLI_PORT:-$DEFAULT_HELPER_PORT}"
ARIA2_RPC_PORT="$DEFAULT_RPC_PORT"
ARIA2_SECRET=""

echo ""
echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
echo -e "${C_BOLD} 🚀 dl2curl & Aria2 Complete Interactive Setup for Raspberry Pi${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
echo "This installer sets up Aria2 download manager and the dl2curl health"
echo "microservice with automatic boot on systemd."
echo ""

# ─── Drive Discovery Helper ───────────────────────────────────────────────────

discover_drives() {
  # Parses df to find real storage mounts (ignores tmpfs, devtmpfs, system partitions)
  df -k -P 2>/dev/null | awk 'NR>1 {
    fs=$1; total_k=$2; avail_k=$4;
    mount="";
    for (i=6; i<=NF; i++) mount=(mount=="" ? $i : mount " " $i);
    if (mount ~ /^\// &&
        fs !~ /^(tmpfs|devtmpfs|udev|none|overlay|shm|cgroup|sysfs|proc|devpts|debugfs|securityfs|fusectl|pstore)/ &&
        mount !~ /^(\/dev|\/proc|\/sys|\/run|\/boot|\/etc|\/var\/log|\/var\/tmp|\/System|\/snap)/ &&
        mount !~ /(Recovery|firmware)/ &&
        total_k > 10240) {
      
      total_g = sprintf("%.1f GB", total_k / 1048576);
      if (total_k >= 1073741824) total_g = sprintf("%.2f TB", total_k / 1073741824);
      avail_g = sprintf("%.1f GB", avail_k / 1048576);
      if (avail_k >= 1073741824) avail_g = sprintf("%.2f TB", avail_k / 1073741824);
      
      print mount ";" total_g ";" avail_g;
    }
  }'
}

# ─── Step 1: Storage Selection Menu ───────────────────────────────────────────

select_storage() {
  local detected_mounts=()
  while IFS= read -r line; do
    [ -n "$line" ] && detected_mounts+=("$line")
  done < <(discover_drives)

  echo -e "${C_BOLD}${C_BLUE}─── Step 1: Storage Selection (Where to save downloads?) ───${C_RESET}"

  local default_choice=1
  local ext_found=false

  if [ "${#detected_mounts[@]}" -gt 0 ]; then
    echo "Detected storage drives and partitions on this system:"
    local i=1
    for item in "${detected_mounts[@]}"; do
      IFS=";" read -r m t a <<< "$item"
      local tag=""
      if [[ "$m" =~ ^/mnt/ ]] || [[ "$m" =~ ^/media/ ]] || [[ "$m" =~ ^/Volumes/ ]] || [[ "$m" =~ ^/media$ ]] || [[ "$m" =~ ^/mnt$ ]]; then
        tag="${C_GREEN}★ [External Drive / USB Storage]${C_RESET}"
        if [ "$ext_found" = false ]; then
          default_choice=$i
          ext_found=true
        fi
      elif [ "$m" = "/" ]; then
        tag="${C_YELLOW}[Root MicroSD / OS Disk]${C_RESET}"
      fi
      echo -e "  [${C_BOLD}$i${C_RESET}] $m  (Total: $t | Free: $a) $tag"
      ((i++))
    done
    local custom_idx=$i
    echo -e "  [${C_BOLD}$custom_idx${C_RESET}] Custom Path (Enter any manual directory)"
    echo ""

    local choice="$default_choice"
    if [ "$INTERACTIVE" = true ]; then
      read -rp "Select storage drive [1-$custom_idx, default: $default_choice]: " input_c || input_c=""
      choice="${input_c:-$default_choice}"
    fi

    local selected_mount=""
    if [ "$choice" -ge 1 ] && [ "$choice" -lt "$custom_idx" ] 2>/dev/null; then
      local sel_item="${detected_mounts[$((choice - 1))]}"
      IFS=";" read -r selected_mount _ _ <<< "$sel_item"
    fi

    if [ -n "$selected_mount" ]; then
      local def_dir="$selected_mount/Downloads"
      if [ "$selected_mount" = "/" ]; then
        if [ -d "/mnt/hdd" ]; then
          def_dir="/mnt/hdd/Downloads"
        else
          def_dir="/var/downloads"
        fi
      fi

      if [ "$INTERACTIVE" = true ]; then
        read -rp "Enter download folder path [$def_dir]: " input_dir || input_dir=""
        DOWNLOADS_DIR="${input_dir:-$def_dir}"
      else
        DOWNLOADS_DIR="${CLI_DIR:-$def_dir}"
      fi
    else
      # Custom path chosen
      local def_dir="${CLI_DIR:-/mnt/hdd/Downloads}"
      if [ "$INTERACTIVE" = true ]; then
        read -rp "Enter custom download folder path [$def_dir]: " input_dir || input_dir=""
        DOWNLOADS_DIR="${input_dir:-$def_dir}"
      else
        DOWNLOADS_DIR="$def_dir"
      fi
    fi
  else
    # Fallback if no drives parsed
    local def_dir="${CLI_DIR:-/mnt/hdd/Downloads}"
    if [ "$INTERACTIVE" = true ]; then
      read -rp "Enter download folder path [$def_dir]: " input_dir || input_dir=""
      DOWNLOADS_DIR="${input_dir:-$def_dir}"
    else
      DOWNLOADS_DIR="$def_dir"
    fi
  fi

  echo ""
  echo "📁 Setting up download directory: $DOWNLOADS_DIR..."
  mkdir -p "$DOWNLOADS_DIR"
  chmod 775 "$DOWNLOADS_DIR" 2>/dev/null || true

  if touch "$DOWNLOADS_DIR/.dl2curl_test" 2>/dev/null; then
    rm -f "$DOWNLOADS_DIR/.dl2curl_test"
    echo -e "   ${C_GREEN}✓ Verified writable directory:${C_RESET} $DOWNLOADS_DIR"
  else
    echo -e "   ${C_RED}⚠️ Warning: Cannot write to $DOWNLOADS_DIR. Check drive mount permissions.${C_RESET}"
  fi
}

# ─── Step 2: Aria2 Detection & Installation ───────────────────────────────────

install_aria2_package() {
  echo ""
  echo -e "${C_BOLD}${C_BLUE}─── Step 2: Aria2 Download Manager Setup ───${C_RESET}"

  local aria2_installed=false
  if command -v aria2c >/dev/null 2>&1; then
    aria2_installed=true
    local aria_ver
    aria_ver=$(aria2c --version 2>&1 | head -n 1)
    echo -e "${C_GREEN}✓ Aria2 (aria2c) is already installed:${C_RESET} $aria_ver"
  fi

  local setup_aria2_config=true

  if [ "$aria2_installed" = false ]; then
    echo -e "${C_YELLOW}⚠️  Aria2 (aria2c) is NOT installed on this machine!${C_RESET}"
    echo "Aria2 is the high-speed multi-connection engine used to receive downloads."
    echo ""
    local do_install=true
    if [ "$INTERACTIVE" = true ]; then
      read -rp "Would you like to install Aria2 now via package manager? [Y/n]: " ans || ans=""
      case "${ans:-Y}" in
        [yY]|[yY][eE][sS]) do_install=true ;;
        *) do_install=false ;;
      esac
    fi

    if [ "$do_install" = true ]; then
      echo "📦 Installing aria2 via system package manager..."
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y aria2
      elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm aria2
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y aria2
      elif command -v yum >/dev/null 2>&1; then
        yum install -y aria2
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache aria2
      elif command -v zypper >/dev/null 2>&1; then
        zypper install -y aria2
      else
        echo -e "${C_RED}❌ Could not detect package manager. Please install aria2 manually.${C_RESET}"
        setup_aria2_config=false
      fi

      if command -v aria2c >/dev/null 2>&1; then
        echo -e "${C_GREEN}✓ Aria2 installed successfully!${C_RESET}"
        aria2_installed=true
      else
        echo -e "${C_RED}❌ Aria2 installation was not completed.${C_RESET}"
        setup_aria2_config=false
      fi
    else
      echo "Skipping Aria2 installation. Proceeding with health helper only."
      setup_aria2_config=false
    fi
  else
    # Aria2 is already installed
    if [ "$INTERACTIVE" = true ]; then
      echo ""
      echo "Aria2 Configuration Options:"
      echo -e "  [${C_BOLD}1${C_RESET}] Configure/Update Aria2 RPC service & storage settings (Recommended)"
      echo -e "  [${C_BOLD}2${C_RESET}] Keep existing Aria2 configuration as-is"
      read -rp "Choose option [1/2, default: 1]: " a_opt || a_opt=""
      if [ "${a_opt:-1}" != "1" ]; then
        setup_aria2_config=false
      fi
    fi
  fi

  if [ "$setup_aria2_config" = true ] && command -v aria2c >/dev/null 2>&1; then
    configure_aria2_rpc
  fi
}

# ─── Step 3: Aria2 RPC Configuration & Systemd ────────────────────────────────

configure_aria2_rpc() {
  echo ""
  echo "⚙️ Configuring Aria2 RPC..."

  # 1. RPC Port
  local rpc_port="$DEFAULT_RPC_PORT"
  if [ "$INTERACTIVE" = true ]; then
    read -rp "Enter Aria2 RPC Port [default: $DEFAULT_RPC_PORT]: " p_in || p_in=""
    rpc_port="${p_in:-$DEFAULT_RPC_PORT}"
  fi
  ARIA2_RPC_PORT="$rpc_port"

  # 2. RPC Secret Token
  local generated_token
  generated_token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || openssl rand -hex 16 2>/dev/null || echo "aria2_$(date +%s)")
  
  local rpc_secret="$generated_token"
  if [ "$INTERACTIVE" = true ]; then
    echo ""
    echo "Aria2 RPC Secret Token (Authentication):"
    echo -e "  [${C_BOLD}1${C_RESET}] Generate strong random token (${C_GREEN}${generated_token}${C_RESET}) [Recommended]"
    echo -e "  [${C_BOLD}2${C_RESET}] Enter your own custom secret token"
    echo -e "  [${C_BOLD}3${C_RESET}] No secret (unauthenticated LAN access)"
    read -rp "Choose authentication [1-3, default: 1]: " s_opt || s_opt=""
    case "${s_opt:-1}" in
      1) rpc_secret="$generated_token" ;;
      2)
        read -rp "Enter custom secret token: " custom_tok || custom_tok=""
        rpc_secret="$custom_tok"
        ;;
      3) rpc_secret="" ;;
      *) rpc_secret="$generated_token" ;;
    esac
  fi
  ARIA2_SECRET="$rpc_secret"

  # 3. BitTorrent listen port
  local bt_port=6881
  if [ "$INTERACTIVE" = true ]; then
    echo ""
    echo -e "${C_BOLD}${C_BLUE}─── BitTorrent Speed Optimisation ───${C_RESET}"
    echo "For fast torrent speeds, Aria2 needs an open inbound port so peers"
    echo "can connect back to your Pi (avoids 0 B/s stall with many peers)."
    echo ""
    read -rp "Enter BitTorrent listen port [default: 6881]: " bt_in || bt_in=""
    bt_port="${bt_in:-6881}"
  fi

  # Install miniupnpc — enables upnp-open.sh / upnp-close.sh called by aria2.service.
  # The port is opened automatically each time Aria2 starts and released when it stops.
  echo ""
  echo "📦 Installing miniupnpc (automatic UPnP router port mapping)..."
  UPNP_AVAILABLE=false
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y miniupnpc >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm miniupnpc >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y miniupnpc >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache miniupnpc >/dev/null 2>&1
  fi
  command -v upnpc >/dev/null 2>&1 && UPNP_AVAILABLE=true || UPNP_AVAILABLE=false
  if [ "$UPNP_AVAILABLE" = true ]; then
    echo -e "   ${C_GREEN}✓ miniupnpc ready — Aria2 will auto-open port ${bt_port} on your router via UPnP.${C_RESET}"
  else
    echo -e "   ${C_YELLOW}⚠️ miniupnpc unavailable — forward port ${bt_port} TCP+UDP manually on your router.${C_RESET}"
  fi

  # 4. Write /etc/aria2/aria2.conf
  mkdir -p /etc/aria2
  local conf_file="/etc/aria2/aria2.conf"
  if [ -f "$conf_file" ]; then
    cp "$conf_file" "${conf_file}.bak.$(date +%s)" 2>/dev/null || true
  fi

  echo "📝 Writing configuration to $conf_file..."
  cat <<EOF > "$conf_file"
## ==============================================================================
## Aria2 Configuration for dl2curl (Generated: $(date))
## ==============================================================================

# ── Basic Settings ─────────────────────────────────────────────────────────────
dir=${DOWNLOADS_DIR}
file-allocation=none
continue=true
max-concurrent-downloads=5
auto-file-renaming=true
content-disposition-default-utf8=true

# ── HTTP / Multi-connection ────────────────────────────────────────────────────
max-connection-per-server=16
split=16
min-split-size=10M

# ── RPC Settings ──────────────────────────────────────────────────────────────
enable-rpc=true
rpc-listen-all=true
rpc-listen-port=${ARIA2_RPC_PORT}
rpc-allow-origin-all=true
$([ -n "$ARIA2_SECRET" ] && echo "rpc-secret=${ARIA2_SECRET}")

# ── Session State Persistence ─────────────────────────────────────────────────
input-file=/etc/aria2/aria2.session
save-session=/etc/aria2/aria2.session
save-session-interval=60

# ── Performance ───────────────────────────────────────────────────────────────
disk-cache=64M
summary-interval=0

# ── BitTorrent Speed Optimisation ─────────────────────────────────────────────
# Without an open listen port, peers cannot connect back to your Pi → 0 B/s stall.
# Forward TCP+UDP port ${bt_port} → this Pi's LAN IP on your router.
listen-port=${bt_port}
dht-listen-port=${bt_port}

# Peer discovery
enable-dht=true
enable-dht6=false
enable-peer-exchange=true
bt-enable-lpd=true

# Peer limits & speed floor
bt-max-peers=100
bt-request-peer-speed-limit=50K
bt-max-open-files=100

# Seeding — stop quickly to free bandwidth for the next download
seed-ratio=0.1
bt-stop-timeout=600

# Extra public trackers (helps find peers when the magnet tracker list is thin)
bt-tracker=udp://tracker.dler.com:6969/announce,udp://open.demonii.com:1337/announce,udp://tracker.torrent.eu.org:451/announce,udp://tracker-udp.gbitt.info:80/announce,http://tracker.bt4g.com:2095/announce
EOF
  chmod 600 "$conf_file"

  # Create session file
  touch /etc/aria2/aria2.session
  chmod 644 /etc/aria2/aria2.session

  # 4. Write UPnP open/close helper scripts
  #    These are called by aria2.service ExecStartPost / ExecStopPost
  #    so the router port is open exactly while Aria2 is running.
  mkdir -p "$INSTALL_DIR"

  cat <<'UPNP_OPEN' > "$INSTALL_DIR/upnp-open.sh"
#!/usr/bin/env bash
# Called by aria2.service ExecStartPost — open BT port on router via UPnP.
PORT="$(grep -Po '(?<=^listen-port=)\d+' /etc/aria2/aria2.conf 2>/dev/null || echo 6881)"
if ! command -v upnpc >/dev/null 2>&1; then exit 0; fi
upnpc -r "$PORT" TCP >/dev/null 2>&1
upnpc -r "$PORT" UDP >/dev/null 2>&1
EXT="$(upnpc -s 2>/dev/null | awk -F= '/ExternalIPAddress/{gsub(/ /,"",$2); print $2}')"
echo "$(date '+%Y-%m-%d %H:%M:%S') [upnp-open] port $PORT mapped (external: ${EXT:-unknown})"
UPNP_OPEN

  cat <<'UPNP_CLOSE' > "$INSTALL_DIR/upnp-close.sh"
#!/usr/bin/env bash
# Called by aria2.service ExecStopPost — release port mapping when Aria2 stops.
PORT="$(grep -Po '(?<=^listen-port=)\d+' /etc/aria2/aria2.conf 2>/dev/null || echo 6881)"
if ! command -v upnpc >/dev/null 2>&1; then exit 0; fi
upnpc -d "$PORT" TCP >/dev/null 2>&1
upnpc -d "$PORT" UDP >/dev/null 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') [upnp-close] port $PORT released"
UPNP_CLOSE

  chmod +x "$INSTALL_DIR/upnp-open.sh" "$INSTALL_DIR/upnp-close.sh"

  # 5. Create /etc/systemd/system/aria2.service
  #    ExecStartPost runs upnp-open.sh after Aria2 is up (non-blocking).
  #    ExecStopPost  runs upnp-close.sh after Aria2 exits.
  local aria_bin
  aria_bin=$(command -v aria2c || echo "/usr/bin/aria2c")
  cat <<EOF > "/etc/systemd/system/aria2.service"
[Unit]
Description=Aria2 Download Manager Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${aria_bin} --conf-path=${conf_file}
ExecStartPost=-/bin/bash ${INSTALL_DIR}/upnp-open.sh
ExecStopPost=-/bin/bash ${INSTALL_DIR}/upnp-close.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable aria2.service 2>/dev/null || true
  systemctl restart aria2.service 2>/dev/null || true
  sleep 2

  if systemctl is-active --quiet aria2.service 2>/dev/null; then
    echo -e "   ${C_GREEN}✓ Aria2 service active on port ${ARIA2_RPC_PORT}${C_RESET}"
    echo -e "   ${C_GREEN}✓ UPnP hooks installed — port ${bt_port} opens/closes with Aria2${C_RESET}"
  else
    echo -e "   ${C_YELLOW}⚠️ aria2.service created. Check: journalctl -u aria2 -n 20${C_RESET}"
  fi

  # Export so show_summary can check UPnP availability
  BT_PORT="$bt_port"
  UPNP_AVAILABLE=false
  if command -v upnpc >/dev/null 2>&1; then
    UPNP_AVAILABLE=true
  fi
}

# ─── Step 4: dl2curl Health & Disk Space Helper Setup ─────────────────────────

setup_health_helper() {
  echo ""
  echo -e "${C_BOLD}${C_BLUE}─── Step 3: dl2curl Health & Disk Space Helper Setup ───${C_RESET}"

  local helper_port="${CLI_PORT:-$DEFAULT_HELPER_PORT}"
  if [ "$INTERACTIVE" = true ]; then
    read -rp "Enter Health Helper microservice port [default: $helper_port]: " h_in || h_in=""
    helper_port="${h_in:-$helper_port}"
  fi
  HELPER_PORT="$helper_port"

  echo "📁 Setting up $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR"

  SCRIPT_SRC="$(dirname "$0")/diskspace.py"
  if [ -f "$SCRIPT_SRC" ]; then
    cp "$SCRIPT_SRC" "$INSTALL_DIR/diskspace.py"
  else
    echo "⬇ Downloading diskspace.py from repository..."
    curl -sSL "https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper/main/diskspace.py" -o "$INSTALL_DIR/diskspace.py"
  fi
  chmod +x "$INSTALL_DIR/diskspace.py"

  # Optional Apache PHP copy
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

  echo "⚙ Configuring systemd auto-boot service ($SERVICE_NAME)..."
  cat <<EOF > "/etc/systemd/system/${SERVICE_NAME}.service"
[Unit]
Description=dl2curl Aria2 Pi Health & Disk Space Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/diskspace.py ${HELPER_PORT} ${DOWNLOADS_DIR}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" 2>/dev/null || true
  systemctl restart "$SERVICE_NAME" 2>/dev/null || true

  sleep 1

  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "   ${C_GREEN}✓ dl2curl Health Helper service is active and running on port ${HELPER_PORT}!${C_RESET}"
  else
    echo -e "   ${C_YELLOW}⚠️ Helper service created. Check: journalctl -u $SERVICE_NAME -n 20${C_RESET}"
  fi
}

# ─── Step 5: Final Summary Screen ─────────────────────────────────────────────

show_summary() {
  local ip_addr
  ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ -z "$ip_addr" ]; then
    ip_addr=$(ip route get 1 2>/dev/null | awk '{print $7}' 2>/dev/null || echo "127.0.0.1")
  fi

  local bt_port_display="${BT_PORT:-6881}"

  echo ""
  echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
  echo -e "${C_BOLD}${C_GREEN} 🎉 dl2curl & Aria2 Installation & Setup Complete!${C_RESET}"
  echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
  echo -e " 🖥️  Host IP Address:        ${C_BOLD}${ip_addr}${C_RESET}"
  echo -e " 📁 Download Folder:        ${C_BOLD}${DOWNLOADS_DIR}${C_RESET}"
  if [ -n "${ARIA2_RPC_PORT:-}" ]; then
    echo -e " 📥 Aria2 RPC Status:       ${C_GREEN}Active on port ${ARIA2_RPC_PORT}${C_RESET}"
    if [ -n "${ARIA2_SECRET:-}" ]; then
      echo -e " 🔑 Aria2 Secret Token:     ${C_CYAN}${ARIA2_SECRET}${C_RESET}"
    else
      echo -e " 🔑 Aria2 Secret Token:     ${C_YELLOW}(None / Unauthenticated)${C_RESET}"
    fi
  fi
  if [ "${UPNP_AVAILABLE:-false}" = true ]; then
    echo -e " 🌐 UPnP Port Mapping:      ${C_GREEN}Auto-active — port ${bt_port_display} opens when Aria2 starts ✓${C_RESET}"
    echo -e "                            ${C_GREEN}(no router login needed — just like qBittorrent)${C_RESET}"
  else
    echo -e " 🌐 UPnP Port Mapping:      ${C_YELLOW}miniupnpc unavailable${C_RESET}"
    echo -e "                            ${C_YELLOW}→ Forward TCP+UDP ${bt_port_display} to ${ip_addr} on your router${C_RESET}"
  fi
  echo -e " 💓 Health Helper URL:      ${C_BOLD}http://${ip_addr}:${HELPER_PORT}/diskspace${C_RESET}"
  if [ -f "/var/www/html/diskspace.php" ]; then
    echo -e " 🌐 Apache Helper URL:      http://${ip_addr}/diskspace.php"
  fi
  echo ""
  echo -e "${C_BOLD}${C_YELLOW}👉 ENTER THESE IN YOUR CHROME EXTENSION SETTINGS (⚙):${C_RESET}"
  echo "──────────────────────────────────────────────────────────────"
  if [ -n "${ARIA2_RPC_PORT:-}" ]; then
    echo -e "  • Aria2 RPC URL:           ${C_BOLD}http://${ip_addr}:${ARIA2_RPC_PORT}/jsonrpc${C_RESET}"
    echo -e "  • Aria2 RPC Secret:        ${C_BOLD}${ARIA2_SECRET:-[Leave empty]}${C_RESET}"
  fi
  echo -e "  • Download directory:      ${C_BOLD}${DOWNLOADS_DIR}${C_RESET}"
  echo -e "  • Pi disk space script:    ${C_BOLD}http://${ip_addr}:${HELPER_PORT}/diskspace${C_RESET}"
  echo "──────────────────────────────────────────────────────────────"
  echo -e "${C_BOLD}Click 'Save settings' and 'Test Connection' in the extension!${C_RESET}"
  echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
  echo ""
}

# ─── Execution ────────────────────────────────────────────────────────────────

select_storage
install_aria2_package
setup_health_helper
show_summary


