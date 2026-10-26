#!/usr/bin/env python3
"""Private, bounded aria2 session/metadata backups and a durable task archive.

This utility never adds, removes, pauses or resumes a download. With
--save-session it asks aria2 to serialize its existing queue before backing up.
Completed task records are archived separately; they are never auto-requeued.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
import urllib.error
import urllib.request


STATE_PROTECTION_VERSION = '1.3.8'

TASK_KEYS = [
    'gid', 'status', 'totalLength', 'completedLength', 'errorCode',
    'errorMessage', 'dir', 'files', 'bittorrent', 'infoHash',
]
METADATA_SUFFIXES = {'.aria2', '.torrent', '.metalink', '.meta4'}


def now():
    return datetime.now(timezone.utc).isoformat()


def read_config(path):
    result = {}
    for line in Path(path).read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            result[key.strip()] = value.strip()
    return result


def atomic_write(path, data):
    """Publish a complete, private file; never expose a half-written backup."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists() and path.read_bytes() == data:
        path.chmod(0o600)
        return
    fd, temp = tempfile.mkstemp(prefix='.writing-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def write_json(path, value):
    atomic_write(path, (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode())


def version_file(directory, data, suffix, keep):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    digest = hashlib.sha256(data).hexdigest()
    existing = sorted(directory.glob(f'*-{digest}{suffix}'))
    if existing:
        target = existing[-1]
    else:
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
        target = directory / f'{stamp}-{digest}{suffix}'
        atomic_write(target, data)
    versions = sorted(directory.glob(f'*{suffix}'))
    for old in versions[:-keep]:
        # A recurring old content hash can be the current version again.
        if old != target:
            old.unlink()
    return target


def backup_session(root, source):
    source = Path(source)
    try:
        data = source.read_bytes()
    except FileNotFoundError:
        return {'source': str(source), 'missing': True, 'bytes': 0}
    result = {'source': str(source), 'bytes': len(data)}
    if data.strip():
        target = version_file(root / 'sessions', data, '.session', 168)
        atomic_write(root / 'last-nonempty.session', data)
        result['backup'] = str(target)
    # Empty sessions are observed, never copied over the recovery checkpoint.
    return result


def backup_metadata(root, download_dir):
    manifest_path = root / 'metadata' / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    current = 0
    if not download_dir.is_dir():
        raise RuntimeError('Configured download directory is unavailable')
    for folder, dirs, files in os.walk(download_dir, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(folder) / name).is_symlink()]
        for name in files:
            path = Path(folder) / name
            if path.suffix.lower() not in METADATA_SUFFIXES or path.is_symlink():
                continue
            try:
                if path.stat().st_size > 64 * 1024 * 1024:
                    raise RuntimeError('Metadata exceeds the 64 MiB backup limit')
                data = path.read_bytes()
            except FileNotFoundError:
                continue
            key = hashlib.sha256(str(path).encode()).hexdigest()
            target = version_file(root / 'metadata' / key, data, path.suffix.lower(), 16)
            manifest[str(path)] = {'backup': str(target), 'bytes': len(data), 'seen': now()}
            current += 1
    write_json(manifest_path, manifest)
    return current


def rpc(config, method, params=None):
    params = list(params or [])
    if config.get('rpc-secret'):
        params.insert(0, 'token:' + config['rpc-secret'])
    port = int(config.get('rpc-listen-port', '6800'))
    if config.get('rpc-secure', 'false') == 'true':
        raise RuntimeError('HTTPS RPC requires a separately configured backup endpoint')
    request = urllib.request.Request(
        f'http://127.0.0.1:{port}/jsonrpc',
        data=json.dumps({'jsonrpc': '2.0', 'id': 'state-backup',
                         'method': method, 'params': params}).encode(),
        headers={'Content-Type': 'application/json'},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            result = json.load(response)
        if 'error' in result or 'result' not in result:
            raise ValueError('RPC rejected the request')
        return result['result']
    except (OSError, ValueError, urllib.error.URLError):
        # Do not print raw RPC data, signed URLs, cookies or credentials.
        raise RuntimeError(f'{method} failed') from None


def collect_tasks(config):
    tasks = rpc(config, 'aria2.tellActive', [TASK_KEYS])
    if not isinstance(tasks, list):
        raise RuntimeError('Invalid active task response')
    for method in ('aria2.tellWaiting', 'aria2.tellStopped'):
        for offset in range(0, 10000, 100):
            page = rpc(config, method, [offset, 100, TASK_KEYS])
            if not isinstance(page, list):
                raise RuntimeError('Invalid paginated task response')
            tasks.extend(page)
            if len(page) < 100:
                break
        else:
            raise RuntimeError('Task archive exceeds the 10000-entry pagination limit')
    return tasks


def archive_tasks(root, tasks):
    for task in tasks:
        gid = task.get('gid', '')
        if not re.fullmatch(r'[0-9a-fA-F]{16}', gid):
            raise RuntimeError('Invalid task ID')
        target = root / 'history' / f'{gid}.json'
        previous = json.loads(target.read_text()) if target.exists() else {}
        record = {'first_seen': previous.get('first_seen', now()),
                  'last_seen': now(), 'task': task}
        if task.get('status') == 'complete' or previous.get('completed_at'):
            record['completed_at'] = previous.get('completed_at', now())
        write_json(target, record)
    # An empty live list must never delete or empty the durable history.


def snapshot(config_path, root, offline=False, save_session=False, wait_lock=0):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    lock_fd = os.open(root / '.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        deadline = time.monotonic() + wait_lock
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    if wait_lock:
                        raise RuntimeError('Timed out waiting for the backup lock') from None
                    return {'skipped': 'another snapshot is running'}
                time.sleep(0.1)
        config = read_config(config_path)
        result = {'timestamp': now(), 'offline': offline, 'archived_tasks': 0}
        if not offline:
            try:
                tasks = collect_tasks(config)
                archive_tasks(root, tasks)
                result['archived_tasks'] = len(tasks)
                if save_session:
                    rpc(config, 'aria2.saveSession')
            except RuntimeError as error:
                result['rpc_error'] = str(error)
        version_file(root / 'configurations', Path(config_path).read_bytes(), '.conf', 32)
        session = config.get('save-session')
        if not session or not Path(session).is_absolute():
            raise RuntimeError('An absolute save-session path is required')
        result['session'] = backup_session(root, session)
        if config.get('input-file') and config['input-file'] != session:
            if not Path(config['input-file']).is_absolute():
                raise RuntimeError('An absolute input-file path is required')
            result['input_session'] = backup_session(root / 'input', config['input-file'])
        directory = Path(config.get('dir', ''))
        if not directory.is_absolute() or directory == Path('/'):
            raise RuntimeError('An absolute, non-root download directory is required')
        result['metadata_files'] = backup_metadata(root, directory)
        write_json(root / 'last-snapshot.json', result)
        return result
    finally:
        os.close(lock_fd)


def history(root):
    result = []
    for path in sorted((Path(root) / 'history').glob('*.json')):
        record = json.loads(path.read_text())
        task = record['task']
        files = task.get('files', [])
        name = task.get('bittorrent', {}).get('info', {}).get('name')
        if not name and files:
            name = Path(files[0].get('path', '')).name
        result.append({'gid': task['gid'], 'status': task.get('status'),
                       'name': name or task['gid'], 'last_seen': record['last_seen'],
                       'completed_at': record.get('completed_at'),
                       'completed_bytes': task.get('completedLength', '0'),
                       'total_bytes': task.get('totalLength', '0')})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path('/etc/aria2/aria2.conf'))
    parser.add_argument('--backup-dir', type=Path, default=Path('/var/backups/dl2curl-aria2'))
    commands = parser.add_subparsers(dest='command', required=True)
    capture = commands.add_parser('snapshot')
    capture.add_argument('--offline', action='store_true')
    capture.add_argument('--save-session', action='store_true')
    capture.add_argument('--wait-lock', type=int, choices=range(0, 31), default=0,
                         metavar='0..30', help='Wait for another snapshot before a service transition')
    commands.add_parser('history', help='Show archived task summaries without source URLs')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == 'history':
            result = history(args.backup_dir)
        else:
            result = snapshot(args.config, args.backup_dir, args.offline,
                              args.save_session, args.wait_lock)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return int(isinstance(result, dict) and 'rpc_error' in result)
    except Exception:
        # Source paths and exception messages can contain credentials.
        print('Aria2 state backup failed; inspect configuration and private backup permissions.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
