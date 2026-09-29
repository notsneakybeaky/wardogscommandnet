# Wardogs Command Net setup: installs Mumble and pre-configures it for the Wardogs Command Net server.
#   B = push-to-talk to your squad
#   V = talk to all squad leaders (works only while you are a squad leader)
# Players can change both keys later in Mumble: Configure > Settings > Shortcuts.
param(
    [string]$SettingsFile,       # override for testing (default: Mumble's own settings file)
    [string]$DatabaseFile,       # override for testing (default: Mumble's own database)
    [switch]$SkipMumbleInstall,
    [switch]$SkipDesktopShortcut
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 otherwise writes some arrays as {"value":[...],"Count":n} in JSON
Remove-TypeData System.Array -ErrorAction SilentlyContinue

# ---- Server details ------------------------------------------------------------------------
$ServerHost  = 'YOUR.SERVER.IP'
$ServerPort  = 64738
$ServerTitle = 'Wardogs Command Net'
# Fingerprints of the server's certificate. If the server ever gets a new certificate, update both:
#   CertSha1   = SHA-1 fingerprint of the certificate   (lets Mumble trust the server without a warning)
#   PubKeySha1 = SHA-1 of the certificate's public key  (Mumble stores per-server shortcuts under this)
$CertSha1    = 'd32bdeb090a621ba9176d670ec93ee175d1aad63'
$PubKeySha1  = 'fca06e1581b49c167596148af1d907c6f39cb3ca'
$LeaderGroup = 'sl'     # must match SL_GROUP in the server bot
$SquadKey    = 0x30     # scan code for B
$LeaderKey   = 0x2F     # scan code for V

$MumbleInstallerUrl    = 'https://github.com/mumble-voip/mumble/releases/download/v1.5.915/mumble_client-1.5.915.x64.exe'
$MumbleInstallerSha256 = '2e867930c78e02a0ed87509757e318375b267cb449a77dafedc3ece4daedccaa'

# Shortcut type ids from Mumble's GlobalShortcutTypes.h
$PushToTalk   = 1
$WhisperShout = 12

function Say($msg) { Write-Host "  $msg" }

# ---- Qt QDataStream encoding (Mumble stores shortcuts this way) -----------------------------
# Every helper returns a single byte[]; Join-Bytes joins them.
function Join-Bytes { $l = New-Object System.Collections.Generic.List[byte]; foreach ($a in $args) { $l.AddRange([byte[]]$a) }; ,$l.ToArray() }
function BE([byte[]]$b) { [Array]::Reverse($b); ,$b }
function U32([uint32]$v) { BE ([BitConverter]::GetBytes($v)) }
function I32([int32]$v)  { BE ([BitConverter]::GetBytes($v)) }
function U16([uint16]$v) { BE ([BitConverter]::GetBytes($v)) }
function Bool([bool]$v)  { ,[byte[]]@([int]$v) }
function QStr([string]$s) { $b = [Text.Encoding]::BigEndianUnicode.GetBytes($s); Join-Bytes (U32 $b.Length) $b }
function CStr([string]$s) { $b = [Text.Encoding]::ASCII.GetBytes($s); Join-Bytes (U32 ($b.Length + 1)) $b (Bool $false) }
# A QVariant holding a registered custom type. Qt 5 streams write type 1024 plus a null flag;
# Qt 4 streams (used by Mumble's database) write type 127 and no null flag.
function UserVariant([string]$typeName, [byte[]]$payload, [bool]$qt5) {
    if ($qt5) { $head = Join-Bytes (U32 1024) (Bool $false) } else { $head = U32 127 }
    Join-Bytes $head (CStr $typeName) $payload
}
function KeyVariant([int]$scanCode, [bool]$qt5) { UserVariant 'InputKeyboard' (Join-Bytes (Bool $false) (U16 $scanCode)) $qt5 }
function ButtonList([int]$scanCode, [bool]$qt5) { Join-Bytes (U32 1) (KeyVariant $scanCode $qt5) }
function ShoutTarget([bool]$qt5) {
    # v2 format: currentSelection, users, forceCenter, channel id (0 = Root), group, links, subchannels
    $p = Join-Bytes (QStr 'v2') (Bool $false) (Bool $false) (Bool $false) (I32 0) (QStr $LeaderGroup) (Bool $false) (Bool $true)
    UserVariant 'ShortcutTarget' $p $qt5
}
function B64([byte[]]$b) { [Convert]::ToBase64String($b) }
function HexBytes([string]$hex) { ,[byte[]]($hex -split '(..)' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) }) }

# ---- SQLite via the copy built into Windows (winsqlite3.dll) ----------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WardogsSqlite {
    const string L = "winsqlite3.dll";
    [DllImport(L)] static extern int sqlite3_open_v2(byte[] f, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(L)] static extern int sqlite3_close(IntPtr db);
    [DllImport(L)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
    [DllImport(L)] static extern int sqlite3_step(IntPtr st);
    [DllImport(L)] static extern int sqlite3_finalize(IntPtr st);
    [DllImport(L)] static extern int sqlite3_bind_blob(IntPtr st, int i, byte[] v, int n, IntPtr d);
    [DllImport(L)] static extern int sqlite3_bind_text(IntPtr st, int i, byte[] v, int n, IntPtr d);
    [DllImport(L)] static extern int sqlite3_bind_int64(IntPtr st, int i, long v);
    [DllImport(L)] static extern long sqlite3_column_int64(IntPtr st, int i);
    [DllImport(L)] static extern IntPtr sqlite3_errmsg(IntPtr db);
    static readonly IntPtr TRANSIENT = new IntPtr(-1);
    static byte[] U(string s) { return System.Text.Encoding.UTF8.GetBytes(s + "\0"); }
    IntPtr db;
    public static WardogsSqlite Open(string path) {
        var s = new WardogsSqlite();
        if (sqlite3_open_v2(U(path), out s.db, 6, IntPtr.Zero) != 0) throw new Exception("Cannot open " + path);
        return s;
    }
    // Runs a statement; parameters may be byte[] (blob), string (text) or int/long. Returns first column of first row, or -1.
    public long Exec(string sql, params object[] args) {
        IntPtr st;
        if (sqlite3_prepare_v2(db, U(sql), -1, out st, IntPtr.Zero) != 0) throw new Exception(Marshal.PtrToStringAnsi(sqlite3_errmsg(db)));
        for (int i = 0; i < args.Length; i++) {
            object a = args[i];
            if (a is byte[]) { var b = (byte[])a; sqlite3_bind_blob(st, i + 1, b, b.Length, TRANSIENT); }
            else if (a is string) { var b = System.Text.Encoding.UTF8.GetBytes((string)a); sqlite3_bind_text(st, i + 1, b, b.Length, TRANSIENT); }
            else sqlite3_bind_int64(st, i + 1, Convert.ToInt64(a));
        }
        int rc = sqlite3_step(st);
        long result = (rc == 100) ? sqlite3_column_int64(st, 0) : -1;
        sqlite3_finalize(st);
        if (rc != 100 && rc != 101) throw new Exception(Marshal.PtrToStringAnsi(sqlite3_errmsg(db)));
        return result;
    }
    public void Close() { sqlite3_close(db); }
}
"@

Write-Host ''
Write-Host '=== Wardogs Command Net setup ===' -ForegroundColor Cyan

# ---- 1. Mumble itself --------------------------------------------------------------------------
function Find-Mumble {
    foreach ($p in @("$env:ProgramFiles\Mumble\client\mumble.exe", "${env:ProgramFiles(x86)}\Mumble\client\mumble.exe", "$env:ProgramFiles\Mumble\mumble.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}
$mumbleExe = Find-Mumble
if (-not $mumbleExe -and -not $SkipMumbleInstall) {
    Say 'Downloading Mumble 1.5.915 from the official GitHub release...'
    $tmp = Join-Path $env:TEMP 'mumble_client-1.5.915.x64.exe'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $MumbleInstallerUrl -OutFile $tmp -UseBasicParsing
    if ((Get-FileHash $tmp -Algorithm SHA256).Hash -ne $MumbleInstallerSha256) { throw 'Downloaded Mumble installer failed its checksum; not running it.' }
    Say 'Running the Mumble installer - click through it with the default options.'
    Start-Process $tmp -Wait
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $mumbleExe = Find-Mumble
    if (-not $mumbleExe) { throw 'Mumble does not seem to be installed. Run this setup again after installing it.' }
}
if ($mumbleExe) { Say "Mumble found: $mumbleExe" }

# ---- 2. Mumble must be closed, or it overwrites our changes when it exits ----------------------
if (-not $SettingsFile) {
    $running = Get-Process mumble -ErrorAction SilentlyContinue
    if ($running) {
        Say 'Closing Mumble so its settings can be updated...'
        $running | ForEach-Object { [void]$_.CloseMainWindow() }
        $running | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
        if (Get-Process mumble -ErrorAction SilentlyContinue) { throw 'Please quit Mumble (right-click its tray icon > Quit) and run this setup again.' }
    }
}

# ---- 3. Settings file: push-to-talk on B ------------------------------------------------------
if (-not $SettingsFile) { $SettingsFile = Join-Path $env:LOCALAPPDATA 'Mumble\Mumble\mumble_settings.json' }
New-Item -ItemType Directory -Force (Split-Path $SettingsFile) | Out-Null

if (Test-Path $SettingsFile) {
    Copy-Item $SettingsFile "$SettingsFile.before-wardogs" -Force
    $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json
} else {
    $settings = [pscustomobject]@{ settings_version = 1 }
}
function Section($name) {
    if (-not $settings.PSObject.Properties[$name]) { $settings | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{}) }
    $settings.$name
}
function SetValue($section, $key, $value) {
    $s = Section $section
    if ($s.PSObject.Properties[$key]) { $s.$key = $value } else { $s | Add-Member -NotePropertyName $key -NotePropertyValue $value }
}

SetValue 'audio' 'transmit_mode' 'PTT'
if (-not (Section 'misc').PSObject.Properties['audio_wizard_has_been_shown']) { SetValue 'misc' 'audio_wizard_has_been_shown' $true }

if (-not $DatabaseFile) {
    $misc = Section 'misc'
    if ($misc.PSObject.Properties['database_location'] -and $misc.database_location) { $DatabaseFile = $misc.database_location }
    else { $DatabaseFile = Join-Path $env:APPDATA 'Mumble\Mumble\mumble.sqlite' }
}
SetValue 'misc' 'database_location' ($DatabaseFile -replace '\\', '/')

$shortcuts = Section 'shortcuts'
$defined = @()
if ($shortcuts.PSObject.Properties['defined']) { $defined = @($shortcuts.defined) }
if ($defined | Where-Object { $_.index -eq $PushToTalk }) {
    Say 'Push-to-talk key already set - keeping yours.'
} else {
    $defined += [pscustomobject]@{
        suppress = $false
        index    = $PushToTalk
        buttons  = @(B64 (KeyVariant $SquadKey $true))
        data     = B64 (Join-Bytes (U32 0) (Bool $true))   # empty QVariant
    }
    Say 'Push-to-talk (squad) set to B.'
}
if ($shortcuts.PSObject.Properties['defined']) { $shortcuts.defined = $defined } else { $shortcuts | Add-Member -NotePropertyName defined -NotePropertyValue $defined }

$json = $settings | ConvertTo-Json -Depth 32
[IO.File]::WriteAllText($SettingsFile, $json, (New-Object Text.UTF8Encoding $false))

# ---- 4. Database: trust the server, add it to favourites, V = squad leader net -----------------
New-Item -ItemType Directory -Force (Split-Path $DatabaseFile) | Out-Null
if (Test-Path $DatabaseFile) { Copy-Item $DatabaseFile "$DatabaseFile.before-wardogs" -Force }
$db = [WardogsSqlite]::Open($DatabaseFile)
try {
    # Same table definitions Mumble uses, so a fresh database looks exactly like one Mumble made.
    [void]$db.Exec('CREATE TABLE IF NOT EXISTS `servers` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `name` TEXT, `hostname` TEXT, `port` INTEGER DEFAULT 64738, `username` TEXT, `password` TEXT, `url` TEXT)')
    [void]$db.Exec('CREATE TABLE IF NOT EXISTS `cert` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `hostname` TEXT, `port` INTEGER, `digest` TEXT)')
    [void]$db.Exec('CREATE UNIQUE INDEX IF NOT EXISTS `cert_host_port` ON `cert`(`hostname`,`port`)')
    [void]$db.Exec('CREATE TABLE IF NOT EXISTS `shortcut` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `digest` BLOB, `type` INTEGER, `shortcut` BLOB, `target` BLOB, `suppress` INTEGER)')
    [void]$db.Exec('CREATE INDEX IF NOT EXISTS `shortcut_host_port` ON `shortcut`(`digest`)')

    [void]$db.Exec('REPLACE INTO `cert` (`hostname`,`port`,`digest`) VALUES (?,?,?)', $ServerHost, $ServerPort, $CertSha1)
    Say 'Server certificate trusted (no security warning on connect).'

    if ($db.Exec('SELECT COUNT(*) FROM `servers` WHERE `hostname` = ? AND `port` = ?', $ServerHost, $ServerPort) -eq 0) {
        [void]$db.Exec('INSERT INTO `servers` (`name`,`hostname`,`port`,`username`,`password`) VALUES (?,?,?,?,?)', $ServerTitle, $ServerHost, $ServerPort, '', '')
        Say "Added '$ServerTitle' to your Mumble favourites."
    }

    $digest = HexBytes $PubKeySha1
    if ($db.Exec('SELECT COUNT(*) FROM `shortcut` WHERE `digest` = ? AND `type` = ?', $digest, $WhisperShout) -gt 0) {
        Say 'Squad leader key already set - keeping yours.'
    } else {
        [void]$db.Exec('INSERT INTO `shortcut` (`digest`,`type`,`shortcut`,`target`,`suppress`) VALUES (?,?,?,?,?)',
            $digest, $WhisperShout, [byte[]](ButtonList $LeaderKey $false), [byte[]](ShoutTarget $false), 0)
        Say 'Squad leader net set to V.'
    }
} finally { $db.Close() }

# ---- 5. Desktop icon that connects straight to the server --------------------------------------
$url = "mumble://${ServerHost}:${ServerPort}/?version=1.2.0&title=$([Uri]::EscapeDataString($ServerTitle))"
if ($mumbleExe -and -not $SkipDesktopShortcut) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Wardogs Command Net.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = $mumbleExe
    $lnk.Arguments = $url
    $lnk.IconLocation = "$mumbleExe,0"
    $lnk.Description = 'Connect to Wardogs Command Net'
    $lnk.Save()
    Say "Desktop icon 'Wardogs Command Net' created."
}

Write-Host ''
Write-Host 'All set!' -ForegroundColor Green
Write-Host '  - Double-click "Wardogs Command Net" on your desktop and type your name.'
Write-Host '  - Hold B to talk to your squad.'
Write-Host '  - To lead a squad: right-click the top channel > Add, type a squad name, OK.'
Write-Host '    As squad leader, hold V to talk to the other squad leaders.'
Write-Host '  - Change keys any time: Configure > Settings > Shortcuts.'
Write-Host ''
