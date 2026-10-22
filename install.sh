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
HELPER_VERSION="1.3.7"
HELPER_REPOSITORY_URL="https://raw.githubusercontent.com/naveen-ramalingam/dl2curl-pi-helper"
HELPER_SOURCE_URL="${HELPER_REPOSITORY_URL}/v${HELPER_VERSION}"
HELPER_UPDATES_URL="${HELPER_REPOSITORY_URL}/main/release.json"

clear_terminal() {
  # Keep redirected output, command substitutions and basic terminals unchanged.
  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
    printf '\033[H\033[2J'
  fi
}

clear_terminal

if [ "${1:-}" = version ] || [ "${1:-}" = --version ] || [ "${1:-}" = -V ]; then
  echo "dl2curl Pi installer $HELPER_VERSION"
  exit 0
fi

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
DEFAULT_RPC_SECRET="Ayyampalayam!9600"
DEFAULT_DOWNLOADS_DIR="/mnt/hdd/Downloads"
INSTALL_DIR="/opt/dl2curl-pi"
SERVICE_NAME="dl2curl-diskspace"
UPNP_SERVICE="/etc/systemd/system/aria2.service"
UPNP_DROPIN="/etc/systemd/system/aria2.service.d/dl2curl-upnp.conf"

CLI_PORT=""
CLI_DIR=""
CLI_UPNP=""

# Parse command line options
ACTION="setup"
FORCE_RECONFIGURE=false
for arg in "$@"; do
  case "$arg" in
    token|--token)
      ACTION="token"
      ;;
    status|--status|info|--info)
      ACTION="status"
      ;;
    tasks|--tasks|live|--live)
      ACTION="tasks"
      ;;
    update|--update)
      ACTION="update"
      ;;
    -f|--force)
      FORCE_RECONFIGURE=true
      ;;
    -y|--yes|--non-interactive|--auto)
      INTERACTIVE=false
      ;;
    --enable-upnp)
      CLI_UPNP=true
      ;;
    --disable-upnp)
      CLI_UPNP=false
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

# Read existing configuration if present
EXISTING_CONF="/etc/aria2/aria2.conf"
EXISTING_TOKEN=""
EXISTING_PORT="$DEFAULT_RPC_PORT"
EXISTING_DIR="$DEFAULT_DOWNLOADS_DIR"
EXISTING_HELPER_PORT="$DEFAULT_HELPER_PORT"

if [ -f "$EXISTING_CONF" ]; then
  EXISTING_TOKEN=$(awk -F= '$1 == "rpc-secret" { sub(/^[^=]*=/, ""); print; exit }' "$EXISTING_CONF")
  EXISTING_PORT=$(awk -F= '$1 == "rpc-listen-port" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$EXISTING_CONF" 2>/dev/null)
  EXISTING_PORT="${EXISTING_PORT:-$DEFAULT_RPC_PORT}"
  EXISTING_DIR=$(awk -F= '$1 == "dir" { sub(/^[^=]*=/, ""); print; exit }' "$EXISTING_CONF" 2>/dev/null)
  EXISTING_DIR="${EXISTING_DIR:-$DEFAULT_DOWNLOADS_DIR}"
fi

if [ -f "/etc/systemd/system/dl2curl-diskspace.service" ]; then
  EXISTING_HELPER_PORT=$(awk '/diskspace\.py/ { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }' /etc/systemd/system/dl2curl-diskspace.service 2>/dev/null)
  EXISTING_HELPER_PORT="${EXISTING_HELPER_PORT:-$DEFAULT_HELPER_PORT}"
fi


# ─── Final Summary Screen ─────────────────────────────────────────────────────

show_summary() {
  local ip_addr
  ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ -z "$ip_addr" ]; then
    ip_addr=$(ip route get 1 2>/dev/null | awk '{print $7}' 2>/dev/null || echo "127.0.0.1")
  fi

  local bt_port_display="${BT_PORT:-$(upnp_port)}"

  echo ""
  echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
  echo -e "${C_BOLD}${C_GREEN} 🎉 dl2curl & Aria2 Installation & Status${C_RESET}"
  echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
  echo -e " 🖥️  Host IP Address:        ${C_BOLD}${ip_addr}${C_RESET}"
  echo " 💓 Installed Helper:       $(helper_installed_version)"
  echo -e " 📁 Download Folder:        ${C_BOLD}${DOWNLOADS_DIR}${C_RESET}"
  if [ -n "${ARIA2_RPC_PORT:-}" ]; then
    if systemctl is-active --quiet aria2.service 2>/dev/null; then
      echo -e " 📥 Aria2 RPC Status:       ${C_GREEN}Active on port ${ARIA2_RPC_PORT}${C_RESET}"
    else
      echo -e " 📥 Aria2 RPC Status:       ${C_YELLOW}Not running (configured port ${ARIA2_RPC_PORT})${C_RESET}"
    fi
    if [ -n "${ARIA2_SECRET:-}" ]; then
      echo -e " 🔑 Aria2 Secret Token:     ${C_CYAN}${ARIA2_SECRET}${C_RESET}"
    else
      echo -e " 🔑 Aria2 Secret Token:     ${C_YELLOW}(None / Unauthenticated)${C_RESET}"
    fi
  fi
  if upnp_enabled; then
    if command -v upnpc >/dev/null 2>&1; then
      echo -e " 🌐 UPnP Port Mapping:      ${C_GREEN}Enabled for port ${bt_port_display} (requires router UPnP support)${C_RESET}"
    else
      echo -e " 🌐 UPnP Port Mapping:      ${C_YELLOW}Enabled, but miniupnpc is not installed${C_RESET}"
    fi
  else
    echo -e " 🌐 UPnP Port Mapping:      Disabled (optional)"
  fi
  echo "                            Manage later: sudo dl2curl upnp install|enable|disable|uninstall"
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
  echo -e "💡 ${C_CYAN}SSH Quick View:${C_RESET} Run ${C_BOLD}dl2curl${C_RESET} anytime in terminal to see this card"
  echo -e "                   Run ${C_BOLD}dl2curl token${C_RESET} to print only the secret token"
  echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
  echo ""
}

# ─── Optional UPnP Port Mapping ───────────────────────────────────────────────

upnp_enabled() {
  [ -f "$UPNP_DROPIN" ] || {
    # Recognize installations made before UPnP became optional.
    [ -f "$UPNP_SERVICE" ] && grep -Fq "$INSTALL_DIR/upnp-open.sh" "$UPNP_SERVICE"
  }
}

upnp_port() {
  local port
  port=$(awk -F= '$1 == "listen-port" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$EXISTING_CONF" 2>/dev/null)
  echo "${port:-6881}"
}

upnp_status() {
  if command -v upnpc >/dev/null 2>&1; then
    echo "miniupnpc: Installed"
  else
    echo "miniupnpc: Not installed"
  fi
  if upnp_enabled; then
    echo "Automatic torrent port mapping: Enabled (requires router UPnP support)"
  else
    echo "Automatic torrent port mapping: Disabled"
  fi
  echo "BitTorrent port: $(upnp_port)"
}

upnp_package() {
  local action="$1"
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$action" = install ]; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y miniupnpc
    else
      DEBIAN_FRONTEND=noninteractive apt-get remove -y miniupnpc
    fi
  elif command -v pacman >/dev/null 2>&1; then
    if [ "$action" = install ]; then
      pacman -S --noconfirm miniupnpc
    else
      pacman -R --noconfirm miniupnpc
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf "$action" -y miniupnpc
  elif command -v yum >/dev/null 2>&1; then
    yum "$action" -y miniupnpc
  elif command -v apk >/dev/null 2>&1; then
    if [ "$action" = install ]; then
      apk add --no-cache miniupnpc
    else
      apk del miniupnpc
    fi
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive "$action" miniupnpc
  else
    echo "No supported package manager found. $action miniupnpc manually." >&2
    return 1
  fi
}

upnp_write_hooks() {
  mkdir -p "$INSTALL_DIR" || return 1
  {
    printf '#!/usr/bin/env bash\nCONF=%q\nDROPIN=%q\n' "$EXISTING_CONF" "$UPNP_DROPIN"
    cat <<'UPNP_OPEN'
[ -f "$DROPIN" ] || exit 0
command -v upnpc >/dev/null 2>&1 || exit 1
PORT=$(awk -F= '$1 == "listen-port" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$CONF" 2>/dev/null)
PORT="${PORT:-6881}"
TCP_OK=0
UDP_OK=0
upnpc -r "$PORT" TCP >/dev/null 2>&1 && TCP_OK=1
upnpc -r "$PORT" UDP >/dev/null 2>&1 && UDP_OK=1
if [ "$TCP_OK" = 1 ] && [ "$UDP_OK" = 1 ]; then
  echo "UPnP: mapped torrent port $PORT TCP+UDP."
else
  echo "UPnP: could not map torrent port $PORT TCP+UDP. Check router UPnP support." >&2
  exit 1
fi
UPNP_OPEN
  } > "$INSTALL_DIR/upnp-open.sh" || return 1
  {
    printf '#!/usr/bin/env bash\nCONF=%q\n' "$EXISTING_CONF"
    cat <<'UPNP_CLOSE'
command -v upnpc >/dev/null 2>&1 || exit 0
PORT=$(awk -F= '$1 == "listen-port" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$CONF" 2>/dev/null)
PORT="${PORT:-6881}"
upnpc -d "$PORT" TCP >/dev/null 2>&1
upnpc -d "$PORT" UDP >/dev/null 2>&1
UPNP_CLOSE
  } > "$INSTALL_DIR/upnp-close.sh" || return 1
  chmod +x "$INSTALL_DIR/upnp-open.sh" "$INSTALL_DIR/upnp-close.sh"
}

upnp_set_enabled() {
  local enabled="$1"
  local apply_now="${2:-true}"
  if [ "$enabled" = false ] && upnp_enabled; then
    if command -v upnpc >/dev/null 2>&1; then
      local port
      port=$(upnp_port)
      upnpc -d "$port" TCP >/dev/null 2>&1 || true
      upnpc -d "$port" UDP >/dev/null 2>&1 || true
    fi
  fi

  # Remove only the old dl2curl hooks; preserve all other service settings.
  if [ -f "$UPNP_SERVICE" ] && grep -Fq "$INSTALL_DIR/upnp-open.sh" "$UPNP_SERVICE"; then
    local service_temp
    service_temp=$(mktemp "${UPNP_SERVICE}.XXXXXX") || return 1
    if ! cp -p "$UPNP_SERVICE" "$service_temp" ||
       ! awk -v open_hook="$INSTALL_DIR/upnp-open.sh" -v close_hook="$INSTALL_DIR/upnp-close.sh" \
         '!(/^Exec(Start|Stop)Post=/ && (index($0, open_hook) || index($0, close_hook)))' "$UPNP_SERVICE" > "$service_temp" ||
       ! mv "$service_temp" "$UPNP_SERVICE"; then
      rm -f "$service_temp"
      return 1
    fi
  fi

  if [ "$enabled" = true ]; then
    upnp_write_hooks || return 1
    mkdir -p "$(dirname "$UPNP_DROPIN")" || return 1
    printf '[Service]\nExecStartPost=-/bin/bash %s/upnp-open.sh\nExecStopPost=-/bin/bash %s/upnp-close.sh\n' "${INSTALL_DIR}" "${INSTALL_DIR}" > "$UPNP_DROPIN" || return 1
  else
    rm -f "$UPNP_DROPIN" || return 1
  fi
  systemctl daemon-reload || return 1
  if [ "$enabled" = true ] && [ "$apply_now" = true ] && systemctl is-active --quiet aria2.service; then
    bash "$INSTALL_DIR/upnp-open.sh" || return 1
  fi
}

upnp_manage() {
  local action="${1:-status}"
  case "$action" in
    status) upnp_status; return 0 ;;
    install|enable|disable|uninstall) ;;
    *) echo "Usage: dl2curl upnp [status|install|enable|disable|uninstall]" >&2; return 1 ;;
  esac
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo dl2curl upnp $action" >&2
    return 1
  fi
  case "$action" in
    install)
      local already_enabled=false
      upnp_enabled && already_enabled=true
      if ! command -v upnpc >/dev/null 2>&1; then
        upnp_package install || return 1
      fi
      if ! command -v upnpc >/dev/null 2>&1; then
        echo "miniupnpc installation did not provide upnpc." >&2
        return 1
      fi
      upnp_write_hooks || return 1
      if [ "$already_enabled" = true ]; then
        upnp_set_enabled true false || return 1
      fi
      upnp_status
      echo "To enable port mapping: sudo dl2curl upnp enable"
      ;;
    enable)
      if [ ! -f "$EXISTING_CONF" ]; then
        echo "Aria2 configuration not found at $EXISTING_CONF." >&2
        return 1
      fi
      if ! command -v upnpc >/dev/null 2>&1; then
        echo "Install miniupnpc first: sudo dl2curl upnp install" >&2
        return 1
      fi
      upnp_set_enabled true || return 1
      echo "Automatic torrent port mapping enabled."
      ;;
    disable|uninstall)
      upnp_set_enabled false || return 1
      echo "Automatic torrent port mapping disabled."
      if [ "$action" = uninstall ]; then
        if command -v upnpc >/dev/null 2>&1; then
          upnp_package remove || return 1
          if command -v upnpc >/dev/null 2>&1; then
            echo "upnpc is still installed; remove its remaining installation manually." >&2
            return 1
          fi
        fi
        rm -f "$INSTALL_DIR/upnp-open.sh" "$INSTALL_DIR/upnp-close.sh" || return 1
        echo "miniupnpc and dl2curl UPnP hooks uninstalled."
      fi
      ;;
  esac
}

# ─── Helper Versions & Updates ───────────────────────────────────────────────

helper_installed_version() {
  local ver
  ver=$(python3 - "$INSTALL_DIR/diskspace.py" <<'VERSION_PY'
import ast, re, sys
try:
    tree = ast.parse(open(sys.argv[1], encoding='utf-8').read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'HELPER_VERSION' for target in node.targets):
            value = ast.literal_eval(node.value)
            if isinstance(value, str) and re.fullmatch(r'\d+\.\d+\.\d+', value):
                print(value)
                raise SystemExit
        if isinstance(node, ast.Dict):
            for key, value in zip(node.keys, node.values):
                if isinstance(key, ast.Constant) and key.value == 'version' and isinstance(value, ast.Constant) and isinstance(value.value, str) and re.fullmatch(r'\d+\.\d+\.\d+', value.value):
                    print(value.value)
                    raise SystemExit
except (OSError, SyntaxError, ValueError):
    pass
print('unknown')
VERSION_PY
)
  echo "$ver" | tr -d '\r'
}

helper_fetch_updates() {
  local metadata versions
  metadata=$(curl -fsSL --connect-timeout 3 --max-time 5 "$HELPER_UPDATES_URL") || return 1
  versions=$(python3 -c 'import json, re, sys
data = json.load(sys.stdin)
for key in ("helper_version", "extension_version"):
    value = data.get(key)
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise SystemExit("Invalid update metadata")
    print(value)' <<< "$metadata") || return 1
  LATEST_HELPER_VERSION=$(printf '%s\n' "$versions" | head -n 1 | tr -d '\r')
  LATEST_EXTENSION_VERSION=$(printf '%s\n' "$versions" | tail -n 1 | tr -d '\r')
}

helper_check_updates() {
  local installed
  installed=$(helper_installed_version)
  echo "Installed helper: $installed (CLI $HELPER_VERSION)"
  if ! helper_fetch_updates; then
    echo "Latest GitHub versions: unavailable. Check your internet connection."
    return 1
  fi
  echo "Latest helper on GitHub: $LATEST_HELPER_VERSION"
  echo "Latest extension on GitHub: $LATEST_EXTENSION_VERSION"
  if python3 -c 'import sys; key=lambda s: tuple(map(int, s.split("."))); raise SystemExit(0 if sys.argv[1] == "unknown" or key(sys.argv[2]) > key(sys.argv[1]) else 1)' "$installed" "$LATEST_HELPER_VERSION"; then
    echo "Helper update available. Run sudo dl2curl update or select Update in the menu."
  else
    echo "Helper is up to date."
  fi
}

helper_pull_latest() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo dl2curl update" >&2
    return 1
  fi
  helper_check_updates || return 1
  local installed
  installed=$(helper_installed_version)
  if [ "$installed" != unknown ] && python3 -c 'import sys; key=lambda s: tuple(map(int, s.split("."))); raise SystemExit(0 if key(sys.argv[1]) >= key(sys.argv[3]) and key(sys.argv[2]) >= key(sys.argv[3]) else 1)' "$installed" "$HELPER_VERSION" "$LATEST_HELPER_VERSION"; then
    return 0
  fi
  local update_dir downloaded_version result
  update_dir=$(mktemp -d) || return 1
  if ! curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "${HELPER_REPOSITORY_URL}/v${LATEST_HELPER_VERSION}/install.sh" -o "$update_dir/install.sh" ||
     ! bash -n "$update_dir/install.sh"; then
    rm -f "$update_dir/install.sh"
    rmdir "$update_dir"
    echo "Could not download a valid versioned installer. Existing helper was kept." >&2
    return 1
  fi
  downloaded_version=$(sed -n 's/^HELPER_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$update_dir/install.sh")
  if [ "$downloaded_version" != "$LATEST_HELPER_VERSION" ]; then
    rm -f "$update_dir/install.sh"
    rmdir "$update_dir"
    echo "Installer version does not match the published release. Existing helper was kept." >&2
    return 1
  fi
  bash "$update_dir/install.sh" update --non-interactive
  result=$?
  rm -f "$update_dir/install.sh"
  rmdir "$update_dir"
  return "$result"
}

# ─── Install Global CLI Shortcut ──────────────────────────────────────────────

install_cli_shortcut() {
  {
    printf '#!/usr/bin/env bash\nDEFAULT_RPC_SECRET=%q\n' "$DEFAULT_RPC_SECRET"
    printf 'INSTALL_DIR=%q\nUPNP_SERVICE=%q\nUPNP_DROPIN=%q\n' "$INSTALL_DIR" "$UPNP_SERVICE" "$UPNP_DROPIN"
    printf 'HELPER_VERSION=%q\nHELPER_REPOSITORY_URL=%q\nHELPER_UPDATES_URL=%q\n' "$HELPER_VERSION" "$HELPER_REPOSITORY_URL" "$HELPER_UPDATES_URL"
    declare -f clear_terminal
    declare -f upnp_enabled upnp_port upnp_status upnp_package upnp_write_hooks upnp_set_enabled upnp_manage
    declare -f helper_installed_version helper_fetch_updates helper_check_updates helper_pull_latest
    cat << 'CLI_SCRIPT'
set -u

clear_terminal

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"
C_RED="\033[31m"

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$IP" ] && IP="127.0.0.1"

CONF="/etc/aria2/aria2.conf"
EXISTING_CONF="$CONF"
TOKEN=""
PORT="6800"
DIR="/mnt/hdd/Downloads"
HELPER_PORT="6801"

case "${1:-}" in
  version|--version|-V)
    echo "dl2curl Pi CLI $HELPER_VERSION"
    echo "Installed helper: $(helper_installed_version)"
    exit 0
    ;;
  check-updates|--check-updates) helper_check_updates; exit $? ;;
  update|--update) helper_pull_latest; exit $? ;;
esac

if [ -f "$CONF" ]; then
  TOKEN=$(awk -F= '$1 == "rpc-secret" { sub(/^[^=]*=/, ""); print; exit }' "$CONF")
  PORT=$(awk -F= '$1 == "rpc-listen-port" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$CONF" 2>/dev/null)
  PORT="${PORT:-6800}"
  DIR=$(awk -F= '$1 == "dir" { sub(/^[^=]*=/, ""); print; exit }' "$CONF" 2>/dev/null)
  DIR="${DIR:-/mnt/hdd/Downloads}"
fi

if [ -f "/etc/systemd/system/dl2curl-diskspace.service" ]; then
  HELPER_PORT=$(awk '/diskspace\.py/ { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }' /etc/systemd/system/dl2curl-diskspace.service 2>/dev/null)
  HELPER_PORT="${HELPER_PORT:-6801}"
fi

# Manage optional automatic torrent port mapping.
if [ "${1:-}" = "upnp" ]; then
  upnp_manage "${2:-status}"
  exit $?
fi

# Quick token flag
if [ "${1:-}" = "token" ] || [ "${1:-}" = "--token" ]; then
  if [ -n "$TOKEN" ]; then
    echo "$TOKEN"
  else
    echo "None (unauthenticated)"
  fi
  exit 0
fi

# Update the Aria2 RPC secret without rerunning the full installer.
if [ "${1:-}" = "settings" ] || [ "${1:-}" = "--settings" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo dl2curl settings" >&2
    exit 1
  fi
  if [ ! -f "$CONF" ]; then
    echo "Aria2 configuration not found at $CONF" >&2
    exit 1
  fi

  CURRENT_TOKEN=$(awk -F= '$1 == "rpc-secret" { sub(/^[^=]*=/, ""); print; exit }' "$CONF")
  echo "Aria2 RPC secret settings:"
  if [ -n "$CURRENT_TOKEN" ]; then
    echo "  [1] Keep the current secret (default)"
    echo "  [2] Generate and save a new secure secret"
    echo "  [3] Enter a new secret"
    echo "  [4] Disable RPC authentication (not recommended)"
    read -rp "Choose [1-4]: " SETTINGS_CHOICE || SETTINGS_CHOICE=""
    SETTINGS_CHOICE="${SETTINGS_CHOICE:-1}"
  else
    echo "  [1] Use the default secret ($DEFAULT_RPC_SECRET)"
    echo "  [2] Generate and save a new secure secret"
    echo "  [3] Enter a new secret"
    echo "  [4] Keep RPC authentication disabled (default)"
    read -rp "Choose [1-4]: " SETTINGS_CHOICE || SETTINGS_CHOICE=""
    SETTINGS_CHOICE="${SETTINGS_CHOICE:-4}"
  fi

  case "$SETTINGS_CHOICE" in
    1)
      if [ -n "$CURRENT_TOKEN" ]; then
        NEW_TOKEN="$CURRENT_TOKEN"
      else
        NEW_TOKEN="$DEFAULT_RPC_SECRET"
      fi
      ;;
    2)
      NEW_TOKEN=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || true)
      if [ -z "$NEW_TOKEN" ]; then
        NEW_TOKEN=$(openssl rand -hex 16 2>/dev/null || true)
      fi
      if [ -z "$NEW_TOKEN" ]; then
        echo "Could not generate a secure token (need /dev/urandom or openssl)." >&2
        exit 1
      fi
      ;;
    3)
      read -rsp "Enter new secret: " NEW_TOKEN || NEW_TOKEN=""
      echo
      if [ -z "$NEW_TOKEN" ]; then
        echo "Secret cannot be empty. No changes made." >&2
        exit 1
      fi
      ;;
    4)
      NEW_TOKEN=""
      ;;
    *)
      echo "Invalid selection. No changes made." >&2
      exit 1
      ;;
  esac

  if [ "$NEW_TOKEN" = "$CURRENT_TOKEN" ]; then
    echo "RPC secret unchanged; no service restart needed."
    if [ -n "$NEW_TOKEN" ]; then
      echo "Current RPC secret (enter this in the extension's RPC Secret setting):"
      echo "$NEW_TOKEN"
    else
      echo "RPC authentication remains disabled."
    fi
    exit 0
  fi

  CONFIG_BACKUP="${CONF}.bak.$(date +%s)"
  if ! cp -p "$CONF" "$CONFIG_BACKUP"; then
    echo "Could not back up $CONF. No changes made." >&2
    exit 1
  fi
  CONFIG_TEMP=$(mktemp "${CONF}.XXXXXX") || {
    echo "Could not create a temporary config file. No changes made." >&2
    exit 1
  }
  chmod 600 "$CONFIG_TEMP"
  if ! awk '!/^rpc-secret=/' "$CONF" > "$CONFIG_TEMP"; then
    rm -f "$CONFIG_TEMP"
    echo "Could not prepare the updated config. No changes made." >&2
    exit 1
  fi
  if [ -n "$NEW_TOKEN" ]; then
    printf 'rpc-secret=%s\n' "$NEW_TOKEN" >> "$CONFIG_TEMP"
  fi
  if ! mv "$CONFIG_TEMP" "$CONF"; then
    rm -f "$CONFIG_TEMP"
    echo "Could not save the updated config. No changes made." >&2
    exit 1
  fi

  if systemctl restart aria2.service 2>/dev/null && systemctl is-active --quiet aria2.service 2>/dev/null; then
    echo "Aria2 RPC secret saved and service restarted."
    if [ -n "$NEW_TOKEN" ]; then
      echo "New RPC secret (enter this in the extension's RPC Secret setting):"
      echo "$NEW_TOKEN"
    else
      echo "RPC authentication is disabled."
    fi
  else
    echo "The secret was saved, but aria2.service did not restart successfully." >&2
    echo "Check the service with: systemctl status aria2.service" >&2
    echo "Previous config backup: $CONFIG_BACKUP" >&2
    exit 1
  fi
  exit 0
fi

# Quick live tasks flag
if [ "${1:-}" = "tasks" ] || [ "${1:-}" = "live" ]; then
  if [ -n "$TOKEN" ]; then
    curl -s -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.tellActive\",\"params\":[\"token:${TOKEN}\"]}" http://127.0.0.1:${PORT}/jsonrpc | python3 -m json.tool
  else
    curl -s -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.tellActive\",\"params\":[]}" http://127.0.0.1:${PORT}/jsonrpc | python3 -m json.tool
  fi
  exit 0
fi

echo ""
echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
echo -e "${C_BOLD} 🚀 dl2curl & Aria2 — Quick Status & RPC Token${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
echo -e " 🖥️  Host IP Address:        ${C_BOLD}${IP}${C_RESET}"
echo -e " 📁 Download Folder:        ${C_BOLD}${DIR}${C_RESET}"
echo -e " 📥 Aria2 RPC URL:          ${C_BOLD}http://${IP}:${PORT}/jsonrpc${C_RESET}"
if [ -n "$TOKEN" ]; then
  echo -e " 🔑 Aria2 Secret Token:     ${C_BOLD}${C_GREEN}${TOKEN}${C_RESET}"
else
  echo -e " 🔑 Aria2 Secret Token:     ${C_YELLOW}(None / Unauthenticated)${C_RESET}"
fi
echo -e " 💓 Health Helper URL:      ${C_BOLD}http://${IP}:${HELPER_PORT}/diskspace${C_RESET}"
helper_check_updates || true
LAST_EXTENSION_VERSION=$(curl -fsSL --connect-timeout 1 --max-time 2 "http://127.0.0.1:${HELPER_PORT}/health" 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin).get("extension", {}).get("version") or "Not connected yet")' 2>/dev/null || echo "Unavailable")
echo "Extension last connected to this Pi: $LAST_EXTENSION_VERSION"
echo ""

upnp_status

# Aria2 process check
if systemctl is-active --quiet aria2 2>/dev/null; then
  echo -e " ⚡ Aria2 Daemon:           ${C_GREEN}Active & Running ✓${C_RESET}"
else
  echo -e " ⚡ Aria2 Daemon:           ${C_RED}Stopped ✗${C_RESET}"
fi

echo "──────────────────────────────────────────────────────────────"
echo -e "${C_BOLD}${C_YELLOW}👉 CHROME EXTENSION SETTINGS (⚙):${C_RESET}"
echo -e "  • RPC URL:     http://${IP}:${PORT}/jsonrpc"
echo -e "  • RPC Secret:  ${TOKEN:-[Leave empty]}"
echo -e "  • Directory:   ${DIR}"
echo -e "  • Script URL:  http://${IP}:${HELPER_PORT}/diskspace"
echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
echo "Quick shortcuts:"
echo "  dl2curl token   → Print only the secret token"
echo "  dl2curl tasks   → View active downloads"
echo "  sudo dl2curl settings → Change the RPC secret"
echo "  dl2curl upnp status → Show optional port mapping settings"
echo "  sudo dl2curl upnp install|enable|disable|uninstall → Manage port mapping"
echo "  dl2curl version|check-updates → Show installed and latest versions"
echo "  sudo dl2curl update → Pull the latest versioned helper and CLI"
echo "  dl2curl menu → Open the interactive menu"
echo ""

if [ "${1:-}" = menu ] || { [ -z "${1:-}" ] && [ -t 0 ]; }; then
  while true; do
    echo "  [1] Check latest helper and extension versions"
    echo "  [2] Update helper and CLI from GitHub"
    echo "  [3] Change RPC token"
    echo "  [4] Manage optional UPnP port mapping"
    echo "  [0] Exit"
    read -rp "Choose [0-4, default: 0]: " menu_choice || menu_choice=""
    clear_terminal
    case "${menu_choice:-0}" in
      1) helper_check_updates || true ;;
      2) helper_pull_latest; exit $? ;;
      3) bash "$0" settings ;;
      4)
        echo "UPnP actions: status, install, enable, disable, uninstall"
        read -rp "Action [default: status]: " upnp_action || upnp_action=""
        clear_terminal
        upnp_manage "${upnp_action:-status}" || true
        ;;
      0) exit 0 ;;
      *) echo "Invalid selection." ;;
    esac
  done
fi
CLI_SCRIPT
  } > /usr/local/bin/dl2curl || return 1
  chmod +x /usr/local/bin/dl2curl || return 1
}

# Quick CLI commands
if [ "$ACTION" = "token" ]; then
  if [ -n "$EXISTING_TOKEN" ]; then
    echo "$EXISTING_TOKEN"
  else
    echo "None (unauthenticated)"
  fi
  exit 0
fi

if [ "$ACTION" = "tasks" ]; then
  if [ -n "$EXISTING_TOKEN" ]; then
    curl -s -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.tellActive\",\"params\":[\"token:${EXISTING_TOKEN}\"]}" http://127.0.0.1:${EXISTING_PORT}/jsonrpc | python3 -m json.tool
  else
    curl -s -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.tellActive\",\"params\":[]}" http://127.0.0.1:${EXISTING_PORT}/jsonrpc | python3 -m json.tool
  fi
  exit 0
fi

if [ "$ACTION" = "status" ]; then
  HELPER_PORT="$EXISTING_HELPER_PORT"
  DOWNLOADS_DIR="$EXISTING_DIR"
  ARIA2_RPC_PORT="$EXISTING_PORT"
  ARIA2_SECRET="$EXISTING_TOKEN"
  show_summary
  exit 0
fi

DOWNLOADS_DIR="${CLI_DIR:-$EXISTING_DIR}"
HELPER_PORT="${CLI_PORT:-$EXISTING_HELPER_PORT}"
ARIA2_RPC_PORT="$EXISTING_PORT"
ARIA2_SECRET="$EXISTING_TOKEN"

# Check if already installed and no configuration changes are requested
TARGET_DIR="${CLI_DIR:-$EXISTING_DIR}"
TARGET_HELPER_PORT="${CLI_PORT:-$EXISTING_HELPER_PORT}"

if [ "$ACTION" = setup ] && [ "$FORCE_RECONFIGURE" = false ] && [ -f "$EXISTING_CONF" ]; then
  # If non-interactive OR if CLI arguments were passed that match existing configuration
  if [ "$INTERACTIVE" = false ] || [ -n "$CLI_DIR" ] || [ -n "$CLI_PORT" ]; then
    if [ -z "$CLI_UPNP" ] && [ "$TARGET_DIR" = "$EXISTING_DIR" ] && [ "$TARGET_HELPER_PORT" = "$EXISTING_HELPER_PORT" ] &&
       [ -f "$INSTALL_DIR/diskspace.py" ] && systemctl is-active --quiet aria2 2>/dev/null && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      echo ""
      echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
      echo -e "${C_BOLD}${C_GREEN} ℹ️  dl2curl & Aria2 are already installed and running.${C_RESET}"
      echo -e " ✓  No configuration changes detected — skipping setup to keep existing settings & RPC secret."
      echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
      echo "    (To force re-run setup and change settings, use: install.sh --force)"
      install_cli_shortcut
      DOWNLOADS_DIR="$EXISTING_DIR"
      ARIA2_RPC_PORT="$EXISTING_PORT"
      ARIA2_SECRET="$EXISTING_TOKEN"
      HELPER_PORT="$EXISTING_HELPER_PORT"
      show_summary
      exit 0
    fi
  fi
fi

if [ "$ACTION" = setup ]; then
echo ""
echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
echo -e "${C_BOLD} 🚀 dl2curl & Aria2 Complete Interactive Setup for Raspberry Pi${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
echo "This installer sets up Aria2 download manager and the dl2curl health"
echo "microservice with automatic boot on systemd."
echo ""

# Interactive menu if already installed
if [ "$INTERACTIVE" = true ] && [ -f "$EXISTING_CONF" ] && [ "$FORCE_RECONFIGURE" = false ] && [ -z "$CLI_UPNP" ]; then
  echo -e "${C_GREEN}✓ Existing dl2curl & Aria2 installation detected!${C_RESET}"
  echo "What would you like to do?"
  echo -e "  [${C_BOLD}1${C_RESET}] View Status & RPC Token (Quick View)"
  echo -e "  [${C_BOLD}2${C_RESET}] Reconfigure / Run Full Setup"
  echo -e "  [${C_BOLD}3${C_RESET}] View Live Active Downloads"
  echo -e "  [${C_BOLD}4${C_RESET}] Update helper and CLI only (v${HELPER_VERSION})"
  echo -e "  [${C_BOLD}5${C_RESET}] Change RPC token"
  echo -e "  [${C_BOLD}6${C_RESET}] Exit"
  echo ""
  read -rp "Select option [1-6, default: 1]: " menu_choice || menu_choice=""
  clear_terminal
  case "${menu_choice:-1}" in
    1)
      DOWNLOADS_DIR="$EXISTING_DIR"
      ARIA2_RPC_PORT="$EXISTING_PORT"
      ARIA2_SECRET="$EXISTING_TOKEN"
      HELPER_PORT="$EXISTING_HELPER_PORT"
      show_summary
      exit 0
      ;;
    3)
      if [ -n "$EXISTING_TOKEN" ]; then
        curl -s -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.tellActive\",\"params\":[\"token:${EXISTING_TOKEN}\"]}" http://127.0.0.1:${EXISTING_PORT}/jsonrpc | python3 -m json.tool
      else
        curl -s -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.tellActive\",\"params\":[]}" http://127.0.0.1:${EXISTING_PORT}/jsonrpc | python3 -m json.tool
      fi
      exit 0
      ;;
    4) ACTION=update ;;
    5)
      install_cli_shortcut
      bash /usr/local/bin/dl2curl settings
      exit $?
      ;;
    6)
      echo "Exiting."
      exit 0
      ;;
    *)
      echo "Proceeding with setup..."
      ;;
  esac
fi
fi

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
  local rpc_port="${EXISTING_PORT:-$DEFAULT_RPC_PORT}"
  if [ "$INTERACTIVE" = true ]; then
    read -rp "Enter Aria2 RPC Port [default: $rpc_port]: " p_in || p_in=""
    rpc_port="${p_in:-$rpc_port}"
  fi
  if ! [[ "$rpc_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$rpc_port < 1 || 10#$rpc_port > 65535 )); then
    echo "Aria2 RPC port must be between 1 and 65535." >&2
    return 1
  fi
  ARIA2_RPC_PORT="$rpc_port"

  # 2. RPC Secret Token
  local rpc_secret="$DEFAULT_RPC_SECRET"
  if [ -f "$EXISTING_CONF" ]; then
    rpc_secret="$EXISTING_TOKEN"
  fi
  if [ "$INTERACTIVE" = true ]; then
    echo ""
    echo "Aria2 RPC Secret Token (Authentication):"
    if [ -f "$EXISTING_CONF" ]; then
      echo -e "  [${C_BOLD}1${C_RESET}] Keep current token (${C_GREEN}${EXISTING_TOKEN:-None / Unauthenticated}${C_RESET}) [Default]"
    else
      echo -e "  [${C_BOLD}1${C_RESET}] Use default token (${C_GREEN}${DEFAULT_RPC_SECRET}${C_RESET}) [Default]"
    fi
    echo -e "  [${C_BOLD}2${C_RESET}] Generate new random token"
    echo -e "  [${C_BOLD}3${C_RESET}] Enter your own custom secret token"
    echo -e "  [${C_BOLD}4${C_RESET}] No secret (unauthenticated LAN access)"
    read -rp "Choose authentication [1-4, default: 1]: " s_opt || s_opt=""
    case "${s_opt:-1}" in
      2)
        rpc_secret=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || openssl rand -hex 16 2>/dev/null)
        if [ -z "$rpc_secret" ]; then
          echo "Could not generate a secure token (need /dev/urandom or openssl)." >&2
          exit 1
        fi
        ;;
      3)
        read -rp "Enter custom secret token: " custom_tok || custom_tok=""
        if [ -z "$custom_tok" ]; then
          echo "Secret cannot be empty. No changes made." >&2
          exit 1
        fi
        rpc_secret="$custom_tok"
        ;;
      4) rpc_secret="" ;;
    esac
  fi
  ARIA2_SECRET="$rpc_secret"

  # 3. BitTorrent listen port
  local bt_port
  bt_port=$(upnp_port)
  if [ "$INTERACTIVE" = true ]; then
    echo ""
    echo -e "${C_BOLD}${C_BLUE}─── BitTorrent Speed Optimisation ───${C_RESET}"
    echo "An open inbound torrent port helps other peers connect to your Pi."
    echo ""
    read -rp "Enter BitTorrent listen port [default: $bt_port]: " bt_in || bt_in=""
    bt_port="${bt_in:-$bt_port}"
  fi
  if ! [[ "$bt_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$bt_port < 1 || 10#$bt_port > 65535 )); then
    echo "BitTorrent port must be between 1 and 65535." >&2
    return 1
  fi

  # Automatic port mapping is optional and requires an explicit choice on fresh installs.
  local enable_upnp=false
  upnp_enabled && enable_upnp=true
  if [ -n "$CLI_UPNP" ]; then
    enable_upnp="$CLI_UPNP"
  elif [ "$INTERACTIVE" = true ]; then
    echo ""
    echo "Optional: install miniupnpc and automatically map the torrent port on your router."
    echo "You can install, enable, disable, or uninstall this later with sudo dl2curl upnp."
    local upnp_answer
    if [ "$enable_upnp" = true ]; then
      read -rp "Keep automatic torrent port mapping enabled? [Y/n]: " upnp_answer || upnp_answer=""
      upnp_answer="${upnp_answer:-Y}"
    else
      read -rp "Install and enable automatic torrent port mapping (UPnP)? [y/N]: " upnp_answer || upnp_answer=""
      upnp_answer="${upnp_answer:-N}"
    fi
    case "$upnp_answer" in
      [yY]|[yY][eE][sS]) enable_upnp=true ;;
      *) enable_upnp=false ;;
    esac
  fi
  # Release the previous port before configuration changes, including upgrades from legacy hooks.
  upnp_set_enabled false || return 1
  echo ""
  if [ "$enable_upnp" = true ]; then
    echo "📦 Installing optional UPnP port mapping..."
    if ! upnp_manage install; then
      echo "UPnP installation failed; continuing with automatic port mapping disabled." >&2
      enable_upnp=false
    fi
  else
    echo "Automatic torrent port mapping skipped/disabled. You can enable it later."
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
# For inbound peers, optionally enable UPnP or forward TCP+UDP ${bt_port} to this Pi.
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

  # 5. Create /etc/systemd/system/aria2.service. Optional UPnP hooks live in a drop-in.
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
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  if [ "$enable_upnp" = true ]; then
    upnp_set_enabled true false || return 1
  fi
  systemctl daemon-reload
  systemctl enable aria2.service 2>/dev/null || true
  systemctl restart aria2.service 2>/dev/null || true
  sleep 2

  if systemctl is-active --quiet aria2.service 2>/dev/null; then
    echo -e "   ${C_GREEN}✓ Aria2 service active on port ${ARIA2_RPC_PORT}${C_RESET}"
    if upnp_enabled; then
      echo -e "   ${C_GREEN}✓ Optional UPnP enabled for torrent port ${bt_port}${C_RESET}"
    fi
  else
    echo -e "   ${C_YELLOW}⚠️ aria2.service created. Check: journalctl -u aria2 -n 20${C_RESET}"
  fi

  BT_PORT="$bt_port"
}

# ─── Step 4: dl2curl Health & Disk Space Helper Setup ─────────────────────────

setup_health_helper() {
  echo ""
  echo -e "${C_BOLD}${C_BLUE}─── Step 3: dl2curl Health & Disk Space Helper Setup ───${C_RESET}"

  local helper_port="${CLI_PORT:-$EXISTING_HELPER_PORT}"
  if [ "$INTERACTIVE" = true ]; then
    read -rp "Enter Health Helper microservice port [default: $helper_port]: " h_in || h_in=""
    helper_port="${h_in:-$helper_port}"
  fi
  if ! [[ "$helper_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$helper_port < 1 || 10#$helper_port > 65535 )); then
    echo "Health helper port must be between 1 and 65535." >&2
    return 1
  fi
  HELPER_PORT="$helper_port"

  echo "📁 Setting up $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR"

  local python_bin
  python_bin=$(command -v python3) || {
    echo "Python 3 is required for the health helper. Install python3 and rerun setup." >&2
    return 1
  }
  local helper_temp
  helper_temp=$(mktemp "$INSTALL_DIR/diskspace.py.XXXXXX") || return 1
  SCRIPT_SRC="$(dirname "$0")/diskspace.py"
  if [ -f "$SCRIPT_SRC" ] && [ "$(cat "$(dirname "$0")/VERSION" 2>/dev/null)" = "$HELPER_VERSION" ]; then
    if ! cp "$SCRIPT_SRC" "$helper_temp"; then
      rm -f "$helper_temp"
      return 1
    fi
  else
    echo "⬇ Downloading diskspace.py from repository..."
    if ! curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "${HELPER_SOURCE_URL}/diskspace.py" -o "$helper_temp"; then
      rm -f "$helper_temp"
      echo "Could not download the health helper. Existing installation was kept." >&2
      return 1
    fi
  fi
  if ! "$python_bin" -c 'import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
version = next((ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "HELPER_VERSION" for target in node.targets)), None)
if version != sys.argv[2]:
    raise SystemExit("Helper version does not match installer")' "$helper_temp" "$HELPER_VERSION"; then
    rm -f "$helper_temp"
    echo "Downloaded helper is not a valid Python script for this version. Existing installation was kept." >&2
    return 1
  fi
  chmod +x "$helper_temp"
  mv "$helper_temp" "$INSTALL_DIR/diskspace.py" || return 1

  # Optional Apache PHP copy
  PHP_SRC="$(dirname "$0")/diskspace.php"
  if [ -d "/var/www/html" ] && { [ "${ACTION:-setup}" != update ] || [ -f "/var/www/html/diskspace.php" ]; }; then
    echo "🌐 Apache / Web server directory detected at /var/www/html"
    if [ -f "$PHP_SRC" ]; then
      cp "$PHP_SRC" "/var/www/html/diskspace.php"
      chmod 644 "/var/www/html/diskspace.php"
      echo "   ✓ Copied PHP helper to /var/www/html/diskspace.php (Port 80)"
    else
      echo "⬇ Downloading diskspace.php from repository..."
      local php_temp
      php_temp=$(mktemp "/var/www/html/diskspace.php.XXXXXX") || return 1
      if curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "${HELPER_SOURCE_URL}/diskspace.php" -o "$php_temp"; then
        chmod 644 "$php_temp"
        mv "$php_temp" "/var/www/html/diskspace.php"
      else
        rm -f "$php_temp"
        echo "Optional PHP helper download failed; keeping any existing PHP helper." >&2
      fi
    fi
  fi
  printf '%s\n' "$HELPER_VERSION" > "$INSTALL_DIR/VERSION" || return 1
  if [ "${ACTION:-setup}" = update ]; then
    return 0
  fi

  echo "⚙ Configuring systemd auto-boot service ($SERVICE_NAME)..."
  cat <<EOF > "/etc/systemd/system/${SERVICE_NAME}.service"
[Unit]
Description=dl2curl Aria2 Pi Health & Disk Space Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${python_bin} ${INSTALL_DIR}/diskspace.py ${HELPER_PORT} "${DOWNLOADS_DIR}"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  if ! systemctl daemon-reload || ! systemctl enable "$SERVICE_NAME" || ! systemctl restart "$SERVICE_NAME"; then
    echo "Could not start the health helper. Check: systemctl status $SERVICE_NAME" >&2
    return 1
  fi

  sleep 1

  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "   ${C_GREEN}✓ dl2curl Health Helper service is active and running on port ${HELPER_PORT}!${C_RESET}"
  else
    echo -e "   ${C_YELLOW}⚠️ Helper service created. Check: journalctl -u $SERVICE_NAME -n 20${C_RESET}"
    return 1
  fi
}

update_installed_helper() {
  if [ ! -f "$INSTALL_DIR/diskspace.py" ] || [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    echo "No installed health helper found. Run the installer without 'update' first." >&2
    return 1
  fi
  INTERACTIVE=false
  CLI_PORT=""
  HELPER_PORT="$EXISTING_HELPER_PORT"
  local backup_dir
  backup_dir=$(mktemp -d "$INSTALL_DIR/.update.XXXXXX") || return 1
  local targets=("$INSTALL_DIR/diskspace.py" "$INSTALL_DIR/VERSION" "/usr/local/bin/dl2curl")
  if [ -f "/var/www/html/diskspace.php" ]; then
    targets+=("/var/www/html/diskspace.php")
  fi
  local existed=() index
  for index in "${!targets[@]}"; do
    if [ -f "${targets[$index]}" ]; then
      cp -p "${targets[$index]}" "$backup_dir/asset-$index" || return 1
      existed[$index]=true
    else
      existed[$index]=false
    fi
  done
  echo "Updating helper and CLI to $HELPER_VERSION..."
  local healthy=false attempt health_response
  if setup_health_helper && install_cli_shortcut && systemctl restart "$SERVICE_NAME"; then
    for attempt in 1 2 3 4 5; do
      # systemd can report active before Python has bound its HTTP socket.
      if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null &&
          health_response=$(curl -fsSL --connect-timeout 1 --max-time 2 "http://127.0.0.1:${HELPER_PORT}/health" 2>/dev/null) &&
          python3 -c 'import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if isinstance(data, dict) and data.get("status") == "ok" and data.get("version") == sys.argv[1] else 1)' "$HELPER_VERSION" <<< "$health_response"; then
        healthy=true
        break
      fi
      if [ "$attempt" = 1 ]; then
        echo "Waiting for the helper to become ready..."
      fi
      if [ "$attempt" -lt 5 ]; then
        sleep 1
      fi
    done
  fi
  if [ "$healthy" = false ]; then
    echo "Update did not pass its health check. Restoring the previous helper and CLI." >&2
    for index in "${!targets[@]}"; do
      if [ "${existed[$index]}" = true ]; then
        cp -p "$backup_dir/asset-$index" "${targets[$index]}" || return 1
      else
        rm -f "${targets[$index]}" || return 1
      fi
    done
    systemctl restart "$SERVICE_NAME" || echo "Check the restored service: systemctl status $SERVICE_NAME" >&2
  fi
  rm -f "$backup_dir"/asset-*
  rmdir "$backup_dir"
  if [ "$healthy" = false ]; then
    return 1
  fi
  echo "Helper $HELPER_VERSION installed. RPC settings, storage and UPnP preference were preserved."
}

# ─── Execution ────────────────────────────────────────────────────────────────

if [ "$ACTION" = update ]; then
  update_installed_helper
  exit $?
fi

select_storage
install_aria2_package
setup_health_helper || exit 1
install_cli_shortcut
show_summary
