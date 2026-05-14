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

// Derive the public baseURL from the request — same directory as this script.
$proto    = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
$host     = $_SERVER['HTTP_HOST'] ?? 'localhost';
$reqDir   = rtrim(dirname($_SERVER['REQUEST_URI'] ?? '/'), '/');
$baseURL  = "$proto://$host$reqDir/";

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
