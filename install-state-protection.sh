#!/usr/bin/env bash
# Install the independent state guard. --activate also loads its settings safely.
# Run from a directory containing this file and aria2-state.py.
set -euo pipefail
STATE_PROTECTION_VERSION="1.3.8"
ACTIVATE=false
if [ "${1:-}" = --activate ]; then
  ACTIVATE=true
elif [ "$#" -gt 0 ]; then
  echo 'Usage: install-state-protection.sh [--activate]' >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo 'Run as root: sudo bash install-state-protection.sh' >&2
  exit 1
fi

STATE_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/aria2-state.py"
[ -f "$STATE_SOURCE" ] || { echo 'aria2-state.py must be beside this installer.' >&2; exit 1; }
python3 - "$STATE_SOURCE" "$ACTIVATE" <<'PY'
import ast
from datetime import datetime, timezone
import grp
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

os.umask(0o077)
source = Path(sys.argv[1])
activate = sys.argv[2] == 'true'
ast.parse(source.read_text())
spec = importlib.util.spec_from_file_location('aria2_state', source)
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)
config_path = Path('/etc/aria2/aria2.conf')
config = state.read_config(config_path)
directory = config.get('dir', '')
if not directory.startswith('/') or directory == '/':
    raise SystemExit('An absolute, non-root download directory is required.')
if (config.get('on-download-stop', '') not in ('', '/usr/local/sbin/dl2curl-aria2-event')
        or any(config.get(key) for key in ('on-download-complete', 'on-download-error'))):
    raise SystemExit('Existing download event hooks need to be integrated before installing.')
mount_line = 'RequiresMountsFor="' + directory.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"\n'
journal_store = Path('/var/lib/dl2curl-aria2-journal')
legacy_mount = Path('/etc/systemd/system/var-log-journal.mount')
memory_log = subprocess.check_output(['findmnt', '-n', '-o', 'FSTYPE', '-T', '/var/log'], text=True).strip() in ('tmpfs', 'ramfs')
link_journal = memory_log or Path('/etc/systemd/system/dl2curl-journal-path.service').exists()
if legacy_mount.exists() and str(journal_store) not in legacy_mount.read_text():
    raise SystemExit('An existing custom journal mount needs to be preserved.')
root = Path('/var/backups/dl2curl-aria2')
root.mkdir(parents=True, exist_ok=True, mode=0o700)
root.chmod(0o700)
stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
before = root / f'before-guard-{stamp}'
before.mkdir(mode=0o700)
targets = {
    '/usr/local/sbin/dl2curl-aria2-state': source.read_bytes(),
    '/usr/local/sbin/dl2curl-aria2-event': (
        '#!/bin/sh\n'
        '# Queue a separate service so the aria2 callback never waits on RPC.\n'
        'exec /bin/systemctl start --no-block dl2curl-aria2-backup.service\n'
    ).encode(),
    '/etc/systemd/system/dl2curl-aria2-backup.service': (
        '[Unit]\nDescription=Archive aria2 task state and recovery metadata\n'
        'After=aria2.service\n' + mount_line +
        '[Service]\nType=oneshot\nUser=root\nUMask=0077\n'
        'ExecStart=/usr/local/sbin/dl2curl-aria2-state snapshot --save-session --wait-lock 15\n'
        'TimeoutStartSec=60\nNoNewPrivileges=true\nPrivateTmp=true\n'
    ).encode(),
    '/etc/systemd/system/dl2curl-aria2-backup.timer': (
        '[Unit]\nDescription=Back up aria2 state every minute\n'
        '[Timer]\nOnBootSec=2min\nOnUnitActiveSec=60s\nAccuracySec=1s\n'
        'Unit=dl2curl-aria2-backup.service\n'
        '[Install]\nWantedBy=timers.target\n'
    ).encode(),
    '/etc/systemd/system/aria2.service.d/90-dl2curl-state.conf': (
        '[Unit]\n' + mount_line +
        '[Service]\n'
        'ExecStartPre=/usr/local/sbin/dl2curl-aria2-state snapshot --offline --wait-lock 15\n'
        'ExecStop=-/usr/local/sbin/dl2curl-aria2-state snapshot --save-session --wait-lock 15\n'
        'ExecStopPost=-/usr/local/sbin/dl2curl-aria2-state snapshot --offline --wait-lock 15\n'
    ).encode(),
    '/etc/systemd/journald.conf.d/90-dl2curl-persistence.conf': (
        '[Journal]\nStorage=persistent\nSystemMaxUse=64M\n'
    ).encode(),
}
if link_journal:
    # DietPi's hourly logclear walks real directories and truncates their files.
    # It does not follow symlinks. Use a root-owned link, rather than a bind mount.
    targets['/etc/tmpfiles.d/00-dl2curl-journal.conf'] = (
        'L /var/log/journal - - - - /var/lib/dl2curl-aria2-journal\n'
    ).encode()
    nocow_vendor = Path('/usr/lib/tmpfiles.d/journal-nocow.conf')
    nocow_override = Path('/etc/tmpfiles.d/journal-nocow.conf')
    if nocow_vendor.exists():
        if nocow_override.exists() and str(journal_store) not in nocow_override.read_text():
            raise SystemExit('A custom journal-nocow override needs to be integrated.')
        # Inode flags cannot be set on the symlink itself. Apply the vendor's
        # journal flags to the real storage directory instead.
        targets[str(nocow_override)] = nocow_vendor.read_bytes().replace(
            b'/var/log/journal', str(journal_store).encode())
    targets['/usr/local/sbin/dl2curl-journal-path'] = ('''#!/usr/bin/env python3
import datetime
import os
from pathlib import Path
import shutil
os.umask(0o077)
link = Path('/var/log/journal')
store = Path('/var/lib/dl2curl-aria2-journal')
if link.is_symlink():
    if link.resolve() != store:
        raise SystemExit('Refusing to replace a custom journal link')
else:
    if link.exists():
        backup = Path('/var/backups/dl2curl-aria2') / ('ram-journal-before-link-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'))
        # The service first asks journald to close these files. Preserve them.
        shutil.copytree(link, backup)
        shutil.rmtree(link)
    link.symlink_to(store, target_is_directory=True)
''').encode()
    targets['/etc/systemd/system/dl2curl-journal-path.service'] = (
        '[Unit]\nDescription=Prepare a disk-backed journal before flushing RAM logs\n'
        'DefaultDependencies=no\n'
        'RequiresMountsFor=/var/lib/dl2curl-aria2-journal /var/log\n'
        'Before=systemd-journal-flush.service\n'
        '[Service]\nType=oneshot\nRemainAfterExit=yes\n'
        'ExecStartPre=/bin/journalctl --relinquish-var\n'
        'ExecStart=/usr/local/sbin/dl2curl-journal-path\n'
        '[Install]\nWantedBy=systemd-journal-flush.service\n'
    ).encode()
settings = {
    'save-session-interval': '60',
    'rpc-save-upload-metadata': 'true',
    'bt-save-metadata': 'true',
    'keep-unfinished-download-result': 'true',
    'on-download-stop': '/usr/local/sbin/dl2curl-aria2-event',
}
lines = []
for line in config_path.read_text().splitlines():
    key = line.strip().split('=', 1)[0]
    if key not in settings and line != '# dl2curl state protection (independent backup service)':
        lines.append(line)
lines += ['', '# dl2curl state protection (independent backup service)']
lines += [f'{key}={value}' for key, value in settings.items()]
targets[str(config_path)] = ('\n'.join(lines) + '\n').encode()

# Complete a verified checkpoint before changing any existing installation file.
checkpoint = state.snapshot(config_path, root, save_session=True, wait_lock=15)
if checkpoint.get('rpc_error'):
    raise SystemExit('A live checkpoint is required before installing protection.')
runtime = state.rpc(config, 'aria2.getGlobalOption') if activate else {}
restart_required = activate and any(runtime.get(key) != value for key, value in settings.items())
manifest = []
for index, (name, content) in enumerate(targets.items()):
    path = Path(name)
    entry = {'path': name, 'existed': path.exists()}
    if path.exists():
        previous = before / f'file-{index}'
        shutil.copy2(path, previous)
        entry['backup'] = str(previous)
        entry['mode'] = path.stat().st_mode & 0o777
    manifest.append(entry)
state.write_json(before / 'rollback-manifest.json', manifest)
state.atomic_write(root / 'guard-install-backup-path', (str(before) + '\n').encode())
for name, content in targets.items():
    path = Path(name)
    state.atomic_write(path, content)
    path.chmod(0o755 if name.startswith('/usr/local/sbin/') else 0o600 if name == str(config_path) else 0o644)

service = Path('/etc/systemd/system/dl2curl-aria2-backup.service')
Path(config['save-session']).chmod(0o600)
subprocess.run(['systemctl', 'daemon-reload'], check=True)
units = [str(service), '/etc/systemd/system/dl2curl-aria2-backup.timer', '/etc/systemd/system/aria2.service']
if link_journal:
    units.append('/etc/systemd/system/dl2curl-journal-path.service')
subprocess.run(['systemd-analyze', 'verify', *units], check=True)
subprocess.run(['systemctl', 'enable', '--now', 'dl2curl-aria2-backup.timer'], check=True)
subprocess.run(['systemctl', 'start', 'dl2curl-aria2-backup.service'], check=True)
Path('/var/log/journal').mkdir(exist_ok=True)
if not link_journal:
    subprocess.run(['systemd-tmpfiles', '--create', '--prefix', '/var/log/journal'], check=True)
if link_journal:
    journal_store.mkdir(mode=0o2755, exist_ok=True)
    os.chown(journal_store, 0, grp.getgrnam('systemd-journal').gr_gid)
    journal_store.chmod(0o2755)
    if legacy_mount.exists():
        shutil.copy2(legacy_mount, before / 'legacy-var-log-journal.mount')
        subprocess.run(['journalctl', '--relinquish-var'], check=True)
        subprocess.run(['systemctl', 'disable', '--now', 'var-log-journal.mount'], check=True)
        legacy_mount.unlink()
        subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', '--now', 'dl2curl-journal-path.service'], check=True)
    subprocess.run(['systemd-tmpfiles', '--create', '/etc/tmpfiles.d/00-dl2curl-journal.conf'], check=True)
    subprocess.run(['systemd-tmpfiles', '--create', '--prefix', '/var/log/journal'], check=True)
subprocess.run(['systemctl', 'restart', 'systemd-journald.service'], check=True)
subprocess.run(['journalctl', '--flush'], check=True)
subprocess.run(['systemctl', 'start', 'systemd-journal-flush.service'], check=True)
restarted = False
if restart_required:
    stats = state.rpc(config, 'aria2.getGlobalStat')
    latest = state.snapshot(config_path, root, save_session=True, wait_lock=15)
    if latest.get('rpc_error'):
        raise SystemExit('The pre-restart checkpoint failed; aria2 was not restarted.')
    if int(stats['numActive']) + int(stats['numWaiting']) and not latest['session']['bytes']:
        raise SystemExit('Some live tasks were not serialized; aria2 was not restarted. Inspect the private task archive.')
    subprocess.run(['systemctl', 'restart', 'aria2.service'], check=True)
    restarted = True
    for attempt in range(5):
        verified = state.snapshot(config_path, root, save_session=True, wait_lock=15)
        if not verified.get('rpc_error'):
            break
        time.sleep(1)
    else:
        raise SystemExit('Aria2 restarted, but its post-restart snapshot failed. Inspect the backup service.')
print(json.dumps({'installed': list(targets), 'rollback_manifest': str(before / 'rollback-manifest.json'),
                  'aria2_restarted': restarted, 'activation_requested': activate,
                  'next_step': 'Protection is active.' if activate else 'Verify a nonempty session, then restart aria2 once.'}, indent=2))
PY
