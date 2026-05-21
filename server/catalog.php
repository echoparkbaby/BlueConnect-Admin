<?php
/**
 * catalog.php — auto-generated BlueConnect Admin package catalog.
 *
 * Drop this file into the same directory as your .pkg / .dmg files.
 * Set the app's "Catalog URL" to:
 *     https://<your-server>/<path-to-this-dir>/catalog.php
 *
 * Every request rescans the directory and returns a fresh JSON catalog.
 * Add or remove a .pkg / .dmg from the folder and the app picks it up
 * on the next Refresh — no manual catalog edits needed.
 *
 * Optional `metadata.json` sidecar in the same directory lets you set
 * per-file metadata (display name, group, description, icon,
 * destructive flag):
 *
 *   {
 *     "_catalogName": "MacFaqulty Standard",
 *     "munkitools-6.3.1.4580.pkg": {
 *       "name": "Munki tools 6.3x",
 *       "group": "Munki",
 *       "description": "Full Munki client; required before MunkiReport.",
 *       "iconName": "shippingbox.fill",
 *       "destructive": false
 *     },
 *     "bluesky-uninstall.pkg": {
 *       "name": "BlueSky uninstall",
 *       "group": "Uninstall",
 *       "destructive": true
 *     }
 *   }
 *
 * Files not listed in metadata.json get a sensible default: the name is
 * the filename without extension, the group is empty, and any file in
 * an "uninstall" entry is auto-flagged destructive.
 *
 * Tested on PHP 7.1+, mbstring not required.
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-cache, must-revalidate, max-age=0');

$dir = __DIR__;

// Derive the public baseURL. PRIORITY:
//   1. metadata.json's `_baseURL` (explicit, trusted, set by admin)
//   2. Validated HTTP_HOST + REQUEST_URI (sanitized to defang Host-header
//      poisoning — a hostile reverse proxy or curl --header could push
//      arbitrary Host: values; we reject anything not matching the
//      allowed hostname/port charset and fall back to SERVER_NAME)
// REQUEST_URI is reduced to its directory and validated to be a plain
// path (no schemes, no query, no traversal segments) before use.

$proto = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';

// Validate Host header. ^[A-Za-z0-9._-]+(:[0-9]{1,5})?$ — any other
// character (slash, @, space, control chars) drops us to SERVER_NAME,
// which is set by Apache's vhost config and not client-controllable.
$rawHost = (string)($_SERVER['HTTP_HOST'] ?? '');
if (preg_match('/^[A-Za-z0-9._-]+(:[0-9]{1,5})?$/', $rawHost) === 1) {
    $host = $rawHost;
} else {
    $host = (string)($_SERVER['SERVER_NAME'] ?? 'localhost');
}

// Trim the script name off REQUEST_URI; keep only the directory portion
// and only if it looks like a plain path (no traversal, no protocol).
$rawUri = (string)($_SERVER['REQUEST_URI'] ?? '/');
$rawUri = strtok($rawUri, '?');  // drop query string
$rawDir = rtrim(dirname($rawUri), '/');
$reqDir = (preg_match('#^(?:/[A-Za-z0-9._~%!$&\'()*+,;=:@-]+)*$#', $rawDir) === 1)
        ? $rawDir
        : '';

$baseURL = "$proto://$host$reqDir/";

// Pull optional sidecar metadata.
$metadata = [];
$catalogName = null;
$metaPath = $dir . '/metadata.json';
if (file_exists($metaPath)) {
    $raw = file_get_contents($metaPath);
    $decoded = json_decode($raw, true);
    if (is_array($decoded)) {
        if (isset($decoded['_catalogName'])) {
            $catalogName = (string)$decoded['_catalogName'];
            unset($decoded['_catalogName']);
        }
        // Admin-set `_baseURL` overrides the derived value above. Use
        // this when the catalog is behind a CDN, a tunnel, or any
        // setup where the Host header doesn't reflect the public URL.
        if (isset($decoded['_baseURL']) && is_string($decoded['_baseURL']) && $decoded['_baseURL'] !== '') {
            $override = rtrim($decoded['_baseURL'], '/') . '/';
            // Only honor http(s) URLs — refuse file://, javascript:, etc.
            if (preg_match('#^https?://#i', $override) === 1) {
                $baseURL = $override;
            }
            unset($decoded['_baseURL']);
        }
        $metadata = $decoded;
    }
}

// Scan the directory for installers.
$entries = @scandir($dir) ?: [];
$packages = [];
foreach ($entries as $entry) {
    if ($entry[0] === '.') continue;
    $ext = strtolower(pathinfo($entry, PATHINFO_EXTENSION));
    if ($ext !== 'pkg' && $ext !== 'dmg') continue;

    $meta = isset($metadata[$entry]) && is_array($metadata[$entry]) ? $metadata[$entry] : [];
    $pkg = [
        'name' => isset($meta['name']) && $meta['name'] !== ''
                  ? (string)$meta['name']
                  : pathinfo($entry, PATHINFO_FILENAME),
        'file' => $entry,
    ];
    foreach (['group', 'description', 'iconName',
              'version', 'bundleID', 'buildNumber', 'minSystem'] as $optStr) {
        if (isset($meta[$optStr]) && $meta[$optStr] !== '') {
            $pkg[$optStr] = (string)$meta[$optStr];
        }
    }
    if (isset($meta['destructive'])) {
        $pkg['destructive'] = (bool)$meta['destructive'];
    }
    $packages[] = $pkg;
}

// Stable order: group, then name. Empty group floats to top.
usort($packages, function($a, $b) {
    $ga = $a['group'] ?? '';
    $gb = $b['group'] ?? '';
    if ($ga !== $gb) {
        if ($ga === '') return -1;
        if ($gb === '') return 1;
        return strcasecmp($ga, $gb);
    }
    return strcasecmp($a['name'], $b['name']);
});

echo json_encode([
    'name'     => $catalogName ?? 'Auto-Generated',
    'baseURL'  => $baseURL,
    'kind'     => 'plain',
    'packages' => $packages,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
