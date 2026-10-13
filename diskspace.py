#!/usr/bin/env python3
"""
dl2curl → Aria2 RPC: Raspberry Pi Health & Disk Space Microservice (Python 3)

Runs a lightweight HTTP microservice on your Raspberry Pi with zero external dependencies.
Reports:
- Live disk space for /mnt/hdd/Downloads (Total, Free, Used, %)
- Mount verification (is /mnt/hdd/Downloads an active mount or root fallback?)
- Write verification (can it create files or is drive mounted read-only?)
- CPU temperature (°C) & under-voltage / throttling status
- RAM memory usage (Total, Free, Available MB, %)
- CPU load averages (1m, 5m, 15m) & uptime
- Aria2c daemon running status

Usage:
    python3 diskspace.py [port] [default_path]
    Default port: 6801
    Default path: /mnt/hdd/Downloads

Endpoints:
    GET /diskspace
    GET /diskspace?path=/mnt/hdd/Downloads
"""

import sys
import os
import json
import shutil
import time
import socket
import tempfile
import re
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

DEFAULT_PORT = 6801
DEFAULT_PATH = '/mnt/hdd/Downloads'
HELPER_VERSION = '1.3.3'
EXTENSION_INFO = {'version': None, 'last_seen': None}
EXTENSION_INFO_LOCK = threading.Lock()


def extension_info(version=None):
    with EXTENSION_INFO_LOCK:
        if isinstance(version, str) and re.fullmatch(r'\d+\.\d+\.\d+', version):
            EXTENSION_INFO.update(version=version, last_seen=int(time.time()))
        return dict(EXTENSION_INFO)


class HTTPServer(ThreadingHTTPServer):
    """Handle simultaneous extension checks without one slow client blocking them."""

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address


def get_cpu_temp():
    """Read Raspberry Pi CPU temperature in Celsius."""
    thermal_path = '/sys/class/thermal/thermal_zone0/temp'
    if os.path.exists(thermal_path):
        try:
            with open(thermal_path, 'r', encoding='utf-8') as f:
                val = f.read().strip()
                if val.isdigit():
                    return round(float(val) / 1000.0, 1)
        except Exception:
            pass
    return None


def get_throttled_status():
    """Check Raspberry Pi under-voltage or thermal throttling flags."""
    throttled_path = '/sys/devices/platform/soc/soc:firmware/get_throttled'
    if os.path.exists(throttled_path):
        try:
            with open(throttled_path, 'r', encoding='utf-8') as f:
                code = f.read().strip()
                return {'throttled': int(code, 16) != 0, 'code': code}
        except Exception:
            pass
    return {'throttled': False, 'code': '0x0'}


def get_ram_info():
    """Read RAM stats from /proc/meminfo."""
    ram = {'total_mb': None, 'free_mb': None, 'available_mb': None, 'percent_used': None}
    if os.path.exists('/proc/meminfo'):
        try:
            with open('/proc/meminfo', 'r', encoding='utf-8') as f:
                data = {}
                for line in f:
                    parts = line.split(':')
                    if len(parts) == 2:
                        k = parts[0].strip()
                        v = parts[1].strip().split()[0]
                        if v.isdigit():
                            data[k] = int(v)
                total_kb = data.get('MemTotal', 0)
                free_kb = data.get('MemFree', 0)
                avail_kb = data.get('MemAvailable', free_kb)
                if total_kb > 0:
                    ram['total_mb'] = round(total_kb / 1024, 0)
                    ram['free_mb'] = round(free_kb / 1024, 0)
                    ram['available_mb'] = round(avail_kb / 1024, 0)
                    ram['percent_used'] = round(((total_kb - avail_kb) / total_kb) * 100, 1)
        except Exception:
            pass
    return ram


def get_system_load_and_uptime():
    """Read CPU load averages and uptime."""
    load_avg = {'1m': 0.0, '5m': 0.0, '15m': 0.0}
    try:
        loads = os.getloadavg()
        load_avg = {'1m': round(loads[0], 2), '5m': round(loads[1], 2), '15m': round(loads[2], 2)}
    except Exception:
        pass

    uptime_sec = 0
    uptime_fmt = ''
    if os.path.exists('/proc/uptime'):
        try:
            with open('/proc/uptime', 'r', encoding='utf-8') as f:
                uptime_sec = int(float(f.read().split()[0]))
                days = uptime_sec // 86400
                hours = (uptime_sec % 86400) // 3600
                mins = (uptime_sec % 3600) // 60
                uptime_fmt = f"{days}d " if days > 0 else ""
                uptime_fmt += f"{hours}h {mins}m"
        except Exception:
            pass

    return load_avg, uptime_sec, uptime_fmt


def is_aria2_running():
    """Check if aria2c daemon is running."""
    if os.path.exists('/proc'):
        try:
            for entry in os.listdir('/proc'):
                if entry.isdigit():
                    cmd_path = os.path.join('/proc', entry, 'cmdline')
                    if os.path.exists(cmd_path):
                        try:
                            with open(cmd_path, 'rb') as f:
                                if b'aria2c' in f.read():
                                    return True
                        except (OSError, PermissionError):
                            continue
        except Exception:
            pass
    return False


def check_mount_and_writable(path):
    """Check if path is a mounted filesystem and writable."""
    is_mounted = False
    if os.path.exists('/proc/mounts'):
        try:
            with open('/proc/mounts', 'r', encoding='utf-8') as f:
                mounts = f.read()
                norm = os.path.realpath(path)
                for line in mounts.splitlines():
                    parts = line.split()
                    if len(parts) >= 2:
                        mount = os.path.normpath(parts[1].replace('\\040', ' ').replace('\\011', '\t').replace('\\134', '\\'))
                        if mount != '/' and (norm == mount or norm.startswith(mount.rstrip('/') + '/')):
                            is_mounted = True
                            break
        except Exception:
            pass

    is_writable = False
    if os.path.isdir(path) and os.access(path, os.W_OK):
        try:
            with tempfile.TemporaryFile(mode='w', encoding='utf-8', dir=path, prefix='.dl2curl_test_') as f:
                f.write('ok')
                f.flush()
            is_writable = True
        except Exception:
            is_writable = False

    return is_mounted, is_writable


class DiskSpaceHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Keep terminal log clean
        sys.stderr.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {format % args}\n")

    def send_cors_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')

    def send_json(self, response, status=200):
        payload = json.dumps(response).encode('utf-8')
        self.send_response(status)
        self.send_cors_headers()
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        client = extension_info(qs.get('extension_version', [None])[0]) if parsed.path in ('/health', '/diskspace') else extension_info()
        if parsed.path == '/health':
            self.send_json({'status': 'ok', 'helper': 'dl2curl-pi-helper', 'version': HELPER_VERSION, 'extension': client})
            return
        if parsed.path != '/diskspace':
            self.send_json({'status': 'error', 'error': 'Endpoint not found. Use /diskspace or /health.'}, 404)
            return

        requested_path = qs.get('path', [DEFAULT_PATH])[0]
        check_path = requested_path

        # Traverse up if path does not exist yet
        while not os.path.exists(check_path) and check_path not in ('/', ''):
            parent = os.path.dirname(check_path)
            if parent == check_path:
                break
            check_path = parent

        if not os.path.exists(check_path):
            check_path = '/'

        try:
            usage = shutil.disk_usage(check_path)
            free_bytes = usage.free
            total_bytes = usage.total
            used_bytes = max(0, total_bytes - free_bytes)

            free_gb = round(free_bytes / (1024 ** 3), 2)
            total_gb = round(total_bytes / (1024 ** 3), 2)
            used_gb = round(used_bytes / (1024 ** 3), 2)
            percent_free = round((free_bytes / total_bytes) * 100, 1) if total_bytes > 0 else 0
            percent_used = round((used_bytes / total_bytes) * 100, 1) if total_bytes > 0 else 0

            is_mounted, is_writable = check_mount_and_writable(check_path)
            cpu_temp = get_cpu_temp()
            throttle = get_throttled_status()
            ram = get_ram_info()
            load_avg, uptime_sec, uptime_fmt = get_system_load_and_uptime()
            aria2_running = is_aria2_running()

            response = {
                'status': 'ok',
                'helper': 'dl2curl-pi-helper',
                'version': HELPER_VERSION,
                'extension': client,
                'timestamp': int(time.time()),
                'hostname': socket.gethostname(),
                # Top-level backward compatibility
                'path': check_path,
                'requested': requested_path,
                'free': free_bytes,
                'total': total_bytes,
                'free_gb': free_gb,
                'total_gb': total_gb,
                'percent_free': percent_free,
                # Detailed sections
                'disk': {
                    'path': check_path,
                    'requested': requested_path,
                    'is_mounted': is_mounted,
                    'is_writable': is_writable,
                    'free_bytes': free_bytes,
                    'total_bytes': total_bytes,
                    'used_bytes': used_bytes,
                    'free_gb': free_gb,
                    'total_gb': total_gb,
                    'used_gb': used_gb,
                    'percent_free': percent_free,
                    'percent_used': percent_used
                },
                'system': {
                    'cpu_temp_c': cpu_temp,
                    'throttled': throttle['throttled'],
                    'throttled_code': throttle['code'],
                    'ram': ram,
                    'load_avg': load_avg,
                    'uptime_seconds': uptime_sec,
                    'uptime_formatted': uptime_fmt,
                    'aria2_running': aria2_running
                }
            }

            self.send_json(response)

        except (BrokenPipeError, ConnectionResetError):
            pass  # The extension may cancel a request when its popup closes.
        except Exception as e:
            self.send_json({'status': 'error', 'error': str(e)}, 500)


def main():
    try:
        port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    except ValueError:
        raise SystemExit('Helper port must be between 1 and 65535.') from None
    if not 1 <= port <= 65535:
        raise SystemExit('Helper port must be between 1 and 65535.')
    if len(sys.argv) > 2:
        global DEFAULT_PATH
        DEFAULT_PATH = sys.argv[2]

    server_address = ('0.0.0.0', port)
    httpd = HTTPServer(server_address, DiskSpaceHandler)
    print(f"dl2curl Pi Health & Disk Space Service listening on http://0.0.0.0:{port}/diskspace")
    print(f"Default check path: {DEFAULT_PATH}")
    print("Press Ctrl+C to stop.")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server.")
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
