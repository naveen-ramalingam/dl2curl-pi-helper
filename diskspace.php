<?php
/**
 * dl2curl → Aria2 RPC: Raspberry Pi Comprehensive Health & Disk Space Helper
 *
 * Place this file in your Raspberry Pi web server directory:
 *   sudo cp diskspace.php /var/www/html/diskspace.php
 *
 * Provides:
 * - Live dynamic disk space for /mnt/hdd/Downloads (Total, Free, Used, %)
 * - Mount validation: Checks if /mnt/hdd/Downloads is an active mounted disk
 * - Write test: Checks if disk is writable (not locked in read-only mode)
 * - CPU Temperature (°C) & Under-voltage / Throttling detection
 * - RAM usage (Total, Free, Available MB, %)
 * - CPU Load averages (1m, 5m, 15m) & System Uptime
 * - Aria2c daemon running status
 *
 * Usage:
 *   http://<pi-ip>/diskspace.php
 *   http://<pi-ip>/diskspace.php?path=/mnt/hdd/Downloads
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// Target directory to inspect (defaults to /mnt/hdd/Downloads)
$path = isset($_GET['path']) && trim($_GET['path']) !== '' ? trim($_GET['path']) : '/mnt/hdd/Downloads';

// Resolve directory to check
$checkPath = $path;
while (!file_exists($checkPath) && $checkPath !== '/' && $checkPath !== '') {
    $parent = dirname($checkPath);
    if ($parent === $checkPath) break;
    $checkPath = $parent;
}
if (!file_exists($checkPath)) {
    $checkPath = '/';
}

// ── 1. Disk Space ───────────────────────────────────────────────────────────
$freeBytes  = @disk_free_space($checkPath);
$totalBytes = @disk_total_space($checkPath);
if ($freeBytes === false || $totalBytes === false) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'error' => 'Could not read disk capacity for the requested path.']);
    exit;
}

$freeGb      = ($freeBytes !== false) ? round($freeBytes / (1024 * 1024 * 1024), 2) : 0;
$totalGb     = ($totalBytes !== false) ? round($totalBytes / (1024 * 1024 * 1024), 2) : 0;
$usedBytes   = ($totalBytes !== false && $freeBytes !== false) ? max(0, $totalBytes - $freeBytes) : 0;
$usedGb      = round($usedBytes / (1024 * 1024 * 1024), 2);
$percentFree = ($totalBytes > 0) ? round(($freeBytes / $totalBytes) * 100, 1) : 0;
$percentUsed = ($totalBytes > 0) ? round(($usedBytes / $totalBytes) * 100, 1) : 0;

// ── 2. Mount & Writable Check ───────────────────────────────────────────────
$isMounted = false;
$mountFilesystems = @file_get_contents('/proc/mounts');
if ($mountFilesystems) {
    $normalizedCheck = rtrim(realpath($checkPath) ?: $checkPath, '/');
    if ($normalizedCheck === '') $normalizedCheck = '/';
    foreach (explode("\n", $mountFilesystems) as $line) {
        $parts = preg_split('/\s+/', trim($line));
        if (count($parts) < 2) continue;
        $mount = str_replace(['\\040', '\\011', '\\134'], [' ', "\t", '\\'], $parts[1]);
        if ($mount !== '/' && ($normalizedCheck === $mount || strpos($normalizedCheck, rtrim($mount, '/') . '/') === 0)) {
            $isMounted = true;
            break;
        }
    }
}

// Test write permission (catches read-only mounts)
$isWritable = false;
if (is_dir($checkPath) && is_writable($checkPath)) {
    $testFile = @tempnam($checkPath, '.dl2curl_test_');
    if ($testFile !== false) {
        $isWritable = realpath(dirname($testFile)) === realpath($checkPath) && @file_put_contents($testFile, 'ok') !== false;
        @unlink($testFile);
    }
}

// ── 3. Raspberry Pi CPU Temperature & Throttling ────────────────────────────
$cpuTempC = null;
if (file_exists('/sys/class/thermal/thermal_zone0/temp')) {
    $rawTemp = @file_get_contents('/sys/class/thermal/thermal_zone0/temp');
    if ($rawTemp !== false && is_numeric(trim($rawTemp))) {
        $cpuTempC = round(((float)trim($rawTemp)) / 1000.0, 1);
    }
}

$isThrottled = false;
$throttledCode = null;
if (file_exists('/sys/devices/platform/soc/soc:firmware/get_throttled')) {
    $rawThrottled = @file_get_contents('/sys/devices/platform/soc/soc:firmware/get_throttled');
    if ($rawThrottled !== false) {
        $throttledCode = trim($rawThrottled);
        $isThrottled = (hexdec($throttledCode) !== 0);
    }
}

// ── 4. RAM / Memory ────────────────────────────────────────────────────────
$ram = [
    'total_mb'     => null,
    'free_mb'      => null,
    'available_mb' => null,
    'percent_used' => null,
];
$meminfo = @file_get_contents('/proc/meminfo');
if ($meminfo) {
    $mTotal = preg_match('/MemTotal:\s+(\d+)\s+kB/', $meminfo, $matches) ? (int)$matches[1] : 0;
    $mFree  = preg_match('/MemFree:\s+(\d+)\s+kB/', $meminfo, $matches) ? (int)$matches[1] : 0;
    $mAvail = preg_match('/MemAvailable:\s+(\d+)\s+kB/', $meminfo, $matches) ? (int)$matches[1] : $mFree;
    if ($mTotal > 0) {
        $ram['total_mb']     = round($mTotal / 1024, 0);
        $ram['free_mb']      = round($mFree / 1024, 0);
        $ram['available_mb'] = round($mAvail / 1024, 0);
        $ram['percent_used'] = round((($mTotal - $mAvail) / $mTotal) * 100, 1);
    }
}

// ── 5. CPU Load & System Uptime ────────────────────────────────────────────
$load = function_exists('sys_getloadavg') ? sys_getloadavg() : [0, 0, 0];
$loadAvg = [
    '1m'  => round($load[0] ?? 0, 2),
    '5m'  => round($load[1] ?? 0, 2),
    '15m' => round($load[2] ?? 0, 2)
];

$uptimeSeconds = 0;
$uptimeFormatted = '';
$uptimeRaw = @file_get_contents('/proc/uptime');
if ($uptimeRaw) {
    $parts = explode(' ', trim($uptimeRaw));
    $uptimeSeconds = (int)$parts[0];
    $days = floor($uptimeSeconds / 86400);
    $hours = floor(($uptimeSeconds % 86400) / 3600);
    $mins = floor(($uptimeSeconds % 3600) / 60);
    $uptimeFormatted = ($days > 0 ? "{$days}d " : '') . "{$hours}h {$mins}m";
}

// ── 6. Aria2 Daemon Check ──────────────────────────────────────────────────
$aria2Running = false;
if (file_exists('/proc')) {
    $pids = @scandir('/proc');
    if ($pids) {
        foreach ($pids as $pid) {
            if (is_numeric($pid) && file_exists("/proc/$pid/cmdline")) {
                $cmd = @file_get_contents("/proc/$pid/cmdline");
                if ($cmd && strpos($cmd, 'aria2c') !== false) {
                    $aria2Running = true;
                    break;
                }
            }
        }
    }
}

// ── Output JSON ────────────────────────────────────────────────────────────
$extensionVersion = $_GET['extension_version'] ?? null;
if (!is_string($extensionVersion) || !preg_match('/^\d+\.\d+\.\d+$/', $extensionVersion)) {
    $extensionVersion = null;
}
$response = [
    'status'       => 'ok',
    'helper'       => 'dl2curl-pi-helper',
    'version'      => '1.3.2',
    'extension'    => ['version' => $extensionVersion, 'last_seen' => $extensionVersion ? time() : null],
    'timestamp'    => time(),
    'hostname'     => gethostname() ?: 'raspberrypi',
    // Backward-compatible top-level keys
    'path'         => $checkPath,
    'requested'    => $path,
    'free'         => $freeBytes,
    'total'        => $totalBytes,
    'free_gb'      => $freeGb,
    'total_gb'     => $totalGb,
    'percent_free' => $percentFree,
    // Detailed sections
    'disk' => [
        'path'         => $checkPath,
        'requested'    => $path,
        'is_mounted'   => $isMounted,
        'is_writable'  => $isWritable,
        'free_bytes'   => $freeBytes,
        'total_bytes'  => $totalBytes,
        'used_bytes'   => $usedBytes,
        'free_gb'      => $freeGb,
        'total_gb'     => $totalGb,
        'used_gb'      => $usedGb,
        'percent_free' => $percentFree,
        'percent_used' => $percentUsed
    ],
    'system' => [
        'cpu_temp_c'       => $cpuTempC,
        'throttled'        => $isThrottled,
        'throttled_code'   => $throttledCode,
        'ram'              => $ram,
        'load_avg'         => $loadAvg,
        'uptime_seconds'   => $uptimeSeconds,
        'uptime_formatted' => $uptimeFormatted,
        'aria2_running'    => $aria2Running
    ]
];

echo json_encode($response, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
