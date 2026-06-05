<?php
/**
 * BlueConnect Admin — JSON API for MunkiReport.
 *
 * Standalone endpoint that reads MunkiReport's database directly and
 * returns JSON. Deliberately NOT a MunkiReport module — this file just
 * needs to live in MR's webroot, so upstream MR upgrades can't break it
 * by renaming module routes or auth helpers.
 *
 * Install:
 *   1. Copy this file to MR's public dir (same dir that holds MR's
 *      index.php / .htaccess). On Docker MR this is e.g.
 *      ~/docker/stacks/munkireport-php/public/blueconnect_api.php;
 *      on a native macOS install it's whatever DocumentRoot Apache
 *      points at (often /Library/WebServer/Documents/munkireport/public).
 *   2. Add the secret to MR's `.env` (the one at MR's project root,
 *      one level above `public/`):
 *        echo 'BLUECONNECT_API_TOKEN=<random 32+ chars>' >> .env
 *      Then:
 *        - Docker MR: `docker compose up -d` to restart the container.
 *        - Native MR: nothing extra to do — this file reads `.env`
 *          directly when getenv() comes up empty (which is what
 *          happens under mod_php/php-fpm on macOS, since MR's
 *          framework loads `.env` into MR's own config but not
 *          into the OS process environment).
 *   3. From the BlueConnect Admin app: Settings → MunkiReport → paste
 *      the same token into the API Token field. Run Test Connection.
 *
 * Endpoints (all require `Authorization: Bearer <token>`):
 *   GET  blueconnect_api.php?action=hosts
 *        — list every machine with core fields + last check-in
 *   GET  blueconnect_api.php?action=host&serial=<serial>
 *        — full inventory for one machine: machine row, reportdata,
 *          munkireport status, FileVault, disk, power, comment,
 *          managed installs, network interfaces, pending software
 *          updates, installed profiles, time-machine status. Sections
 *          come back null/[] when the corresponding MR module isn't
 *          installed (safe degradation).
 *   GET  blueconnect_api.php?action=ping
 *        — auth-only check; returns {"ok": true} when the token is valid.
 *
 * Failure modes:
 *   401 — missing / malformed Authorization header
 *   403 — wrong token (constant-time compare)
 *   503 — BLUECONNECT_API_TOKEN not found (or < 12 chars) in either
 *         the process environment or MR's `.env` file
 *   500 — DB connection failure (message includes the driver-level error)
 *   400 — unknown action or missing required parameter
 */

header('Content-Type: application/json');

// ---------------------------------------------------------------- token
//
// Token resolution: process env first (the Docker MR path), then
// fall back to parsing MR's .env file directly (the native-Apache
// path — mod_php/php-fpm on macOS doesn't inherit MR's app-level
// .env into getenv()).
$expected = getenv('BLUECONNECT_API_TOKEN');
if (!$expected) {
    // MR's .env sits at the project root, one above public/. Check
    // there first, then the sibling (some installs flatten the
    // layout), then a couple of common parents as belt-and-suspenders.
    $candidates = [
        dirname(__DIR__) . '/.env',
        __DIR__ . '/.env',
        dirname(__DIR__, 2) . '/.env',
    ];
    foreach ($candidates as $env_file) {
        if (!is_file($env_file) || !is_readable($env_file)) continue;
        $lines = @file($env_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if ($lines === false) continue;
        foreach ($lines as $line) {
            $line = ltrim($line);
            if ($line === '' || $line[0] === '#') continue;
            if (strncmp($line, 'BLUECONNECT_API_TOKEN=', 22) !== 0) continue;
            // Strip surrounding single/double quotes and trailing
            // whitespace. Some users wrap the value because other
            // MR keys do, even though dotenv treats both forms the
            // same.
            $val = trim(substr($line, 22));
            if (strlen($val) >= 2) {
                $first = $val[0]; $last = $val[strlen($val) - 1];
                if (($first === '"' && $last === '"') || ($first === "'" && $last === "'")) {
                    $val = substr($val, 1, -1);
                }
            }
            $expected = $val;
            break 2;
        }
    }
}
if (!$expected || strlen($expected) < 12) {
    http_response_code(503);
    echo json_encode(['error' => 'BLUECONNECT_API_TOKEN not found (min 12 chars). Add it to MR\'s .env (one level above public/) and restart Apache, or set it in the Docker container env. See blueconnect_api.php docstring.']);
    exit;
}

// Pull Authorization header from a few different SAPI shapes — PHP-FPM
// behind nginx hides it in REDIRECT_*, mod_php sometimes only exposes
// it via apache_request_headers().
$auth = '';
if (!empty($_SERVER['HTTP_AUTHORIZATION'])) {
    $auth = $_SERVER['HTTP_AUTHORIZATION'];
} elseif (!empty($_SERVER['REDIRECT_HTTP_AUTHORIZATION'])) {
    $auth = $_SERVER['REDIRECT_HTTP_AUTHORIZATION'];
} elseif (function_exists('apache_request_headers')) {
    foreach (apache_request_headers() as $k => $v) {
        if (strcasecmp($k, 'Authorization') === 0) { $auth = $v; break; }
    }
}
if (!preg_match('/^Bearer\s+(.+)$/i', trim($auth), $m)) {
    http_response_code(401);
    echo json_encode(['error' => 'Authorization: Bearer <token> required']);
    exit;
}
if (!hash_equals($expected, $m[1])) {
    http_response_code(403);
    echo json_encode(['error' => 'Invalid token']);
    exit;
}

// ----------------------------------------------------------------- DB
$driver = getenv('CONNECTION_DRIVER') ?: 'sqlite';
try {
    if ($driver === 'sqlite') {
        $sqlite_path = getenv('CONNECTION_SQLITE_FILE_NAME') ?: '/var/munkireport/app.sqlite';
        $pdo = new PDO("sqlite:$sqlite_path");
    } else {
        $host = getenv('CONNECTION_HOST') ?: 'db';
        $port = getenv('CONNECTION_PORT') ?: '3306';
        $name = getenv('CONNECTION_DATABASE') ?: 'munkireport';
        $user = getenv('CONNECTION_USERNAME') ?: 'munkireport';
        $pass = getenv('CONNECTION_PASSWORD') ?: '';
        $dsn = "$driver:host=$host;port=$port;dbname=$name;charset=utf8mb4";
        $pdo = new PDO($dsn, $user, $pass);
    }
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['error' => 'DB connection failed: ' . $e->getMessage(), 'driver' => $driver]);
    exit;
}

// ------------------------------------------------------------ helpers
/** Single-row fetch that swallows missing-table errors so optional MR
 *  modules degrade to null instead of a 500. */
function safe_fetch_one($pdo, $sql, $params) {
    try {
        $st = $pdo->prepare($sql);
        $st->execute($params);
        $r = $st->fetch(PDO::FETCH_ASSOC);
        return $r ?: null;
    } catch (Exception $e) {
        return null;
    }
}
function safe_fetch_all($pdo, $sql, $params) {
    try {
        $st = $pdo->prepare($sql);
        $st->execute($params);
        return $st->fetchAll(PDO::FETCH_ASSOC);
    } catch (Exception $e) {
        return null;
    }
}

// --------------------------------------------------------------- dispatch
$action = $_GET['action'] ?? 'host';

if ($action === 'ping') {
    echo json_encode(['ok' => true, 'driver' => $driver]);
    exit;
}

if ($action === 'hosts') {
    // Columns reflect MR's actual schema: machine_desc (not _friendly),
    // cpu (not cpu_type), os_version (int, MMmmpp packed).
    $rows = safe_fetch_all($pdo, "
        SELECT m.serial_number, m.computer_name, m.hostname,
               m.os_version, m.machine_model, m.machine_desc,
               m.cpu, m.cpu_arch, m.physical_memory,
               r.timestamp AS last_check_in
        FROM machine m
        LEFT JOIN reportdata r ON m.serial_number = r.serial_number
        ORDER BY r.timestamp DESC
    ", []);
    echo json_encode([
        'count' => count($rows ?? []),
        'hosts' => $rows ?: [],
    ]);
    exit;
}

if ($action === 'host') {
    $serial = $_GET['serial'] ?? '';
    if (!$serial) {
        http_response_code(400);
        echo json_encode(['error' => 'Missing ?serial=<serial_number>']);
        exit;
    }
    // Each section is `null` when the corresponding MR module isn't
    // installed, so the client renders only what's present. Table names
    // match MR-php 5.x: `diskreport` (no underscore), `filevault_status`,
    // `managedinstalls`, etc.
    // Column lists below alias MR-PHP 5.x's actual schema (service,
    // `order`, ethernet, ipv4dns, searchdomain — and snake_case names in
    // timemachine / profile) into the JSON keys the Swift models expect.
    // `payload_data` is excluded from profiles intentionally — can be
    // large and contains the raw profile body.
    $out = [
        'serial'           => $serial,
        'machine'          => safe_fetch_one($pdo, "SELECT * FROM machine WHERE serial_number = :s",          [':s' => $serial]),
        'reportdata'       => safe_fetch_one($pdo, "SELECT * FROM reportdata WHERE serial_number = :s",       [':s' => $serial]),
        'munkireport'      => safe_fetch_one($pdo, "SELECT * FROM munkireport WHERE serial_number = :s",      [':s' => $serial]),
        'filevault'        => safe_fetch_one($pdo, "SELECT * FROM filevault_status WHERE serial_number = :s", [':s' => $serial]),
        'disk_report'      => safe_fetch_one($pdo, "SELECT * FROM diskreport WHERE serial_number = :s",       [':s' => $serial]),
        'power'            => safe_fetch_one($pdo, "SELECT * FROM power WHERE serial_number = :s",            [':s' => $serial]),
        'comment'          => safe_fetch_one($pdo, "SELECT * FROM comment WHERE serial_number = :s",          [':s' => $serial]),
        'managed_installs' => safe_fetch_all($pdo, "SELECT * FROM managedinstalls WHERE serial_number = :s ORDER BY name",
                                             [':s' => $serial]),

        // Pending Munki installs live in MR's `pendingupdates` table on
        // most builds (some older deployments call it `pendinginstalls`).
        // Try both. `?: null` so an empty array still degrades cleanly.
        'pending_installs' => (safe_fetch_all($pdo, "SELECT * FROM pendingupdates WHERE serial_number = :s ORDER BY name",
                                              [':s' => $serial])
                            ?: safe_fetch_all($pdo, "SELECT * FROM pendinginstalls WHERE serial_number = :s ORDER BY name",
                                              [':s' => $serial])
                            ?: null),

        // Local user accounts (UID >= 500) from MR's local_users module.
        // Filters out Apple's `_*` system accounts (UID 1..499) so we
        // only show the real humans + local admins like `ladmin`. Aliases
        // MR's schema (`local_users` table, `unique_id`/`record_name`/
        // `real_name`/`home_directory`/`user_shell`/`administrator`)
        // into the snake_case names the Swift model expects.
        'users'            => safe_fetch_all($pdo, "
            SELECT record_name        AS name,
                   real_name          AS realname,
                   unique_id          AS uid,
                   primary_group_id   AS gid,
                   home_directory     AS home,
                   user_shell         AS shell,
                   administrator      AS admin,
                   ssh_access         AS ssh_access,
                   last_login_timestamp AS last_login_ts
            FROM local_users
            WHERE serial_number = :s
              AND unique_id >= 500
            ORDER BY administrator DESC, unique_id",
            [':s' => $serial]),

        'network'          => safe_fetch_all($pdo, "
            SELECT service              AS service_name,
                   `order`              AS service_order,
                   ipv4ip, ipv4mask, ipv4router,
                   ipv4dns              AS ipv4dnsservers,
                   searchdomain         AS ipv4searchdomains,
                   ipv6ip,
                   ethernet             AS ethernet_macaddress
            FROM network
            WHERE serial_number = :s
            ORDER BY `order`",
            [':s' => $serial]),

        // Wi-Fi lives in MR's separate `wifi` module (SSID, BSSID,
        // channel, security, RSSI). Some deployments use `wifi_signal`
        // or `airport`, so we try a few likely table names. SELECT * to
        // tolerate column-set drift between MR versions.
        'wifi'             => safe_fetch_one($pdo, "SELECT * FROM wifi WHERE serial_number = :s",        [':s' => $serial])
                           ?? safe_fetch_one($pdo, "SELECT * FROM wifi_signal WHERE serial_number = :s", [':s' => $serial])
                           ?? safe_fetch_one($pdo, "SELECT * FROM airport WHERE serial_number = :s",     [':s' => $serial]),

        // softwareupdate is a single per-host status row, NOT a per-update
        // table. Common columns: recommendedupdates (count), patchupdates
        // (count), lastfullsuccessfuldate, lastsuccessfuldate, etc.
        'software_updates' => safe_fetch_one($pdo, "SELECT * FROM softwareupdate WHERE serial_number = :s",
                                             [':s' => $serial]),

        // profile: alias the snake_case module schema. Skip payload_data —
        // potentially large and not needed for the inventory summary.
        'profiles'         => safe_fetch_all($pdo, "
            SELECT profile_name             AS name,
                   profile_uuid             AS identifier,
                   profile_removal_allowed  AS removaldisallowed,
                   payload_name             AS payload_name,
                   payload_display          AS payload_display
            FROM profile
            WHERE serial_number = :s
            ORDER BY profile_name",
            [':s' => $serial]),

        // timemachine: confirmed snake_case columns — no `time_machine`
        // fallback (that table never existed; the old `??` chain just hid
        // real SQL errors as a missing module).
        'timemachine'      => safe_fetch_one($pdo, "SELECT * FROM timemachine WHERE serial_number = :s",
                                             [':s' => $serial]),
    ];
    echo json_encode($out, JSON_UNESCAPED_SLASHES);
    exit;
}

http_response_code(400);
echo json_encode(['error' => 'Unknown action. Use ?action=ping | ?action=hosts | ?action=host&serial=ABC']);
