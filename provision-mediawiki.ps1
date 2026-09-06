#Requires -Version 7.0
<#
.SYNOPSIS
  One-click provision/teardown of MediaWiki on a vanilla Windows Server (2016+) machine
  using ONLY what ships with Windows + PowerShell 7 - no Chocolatey, no Docker, no other
  package manager. Everything is a direct binary download (Invoke-WebRequest/Expand-Archive),
  installed under one centralized root folder so backups are a single directory copy.

  Stack: Apache (mod_fcgid, no IIS) + PHP (php-cgi) + MySQL (native Windows zip) + MediaWiki
  latest stable + SemanticMediaWiki + a curated "vanilla plus" extension set, with APCu
  object/opcode caching and MediaWiki performance best practices baked into LocalSettings.php.

  Every prerequisite Up installs is checked for pre-existence first and recorded in
  <InstallRoot>\_provisioning\install-state.json. Down reads that file and reverses ONLY
  what this script itself added - an Apache/MySQL instance that was already on the machine
  for something else is detected and the script halts for confirmation (-Force to skip)
  rather than silently modifying it.

.PARAMETER Action
  Up      - install/configure everything and start the wiki (default)
  Down    - full teardown: removes every service/file this script installed under
            InstallRoot. Pass -KeepData to just stop services instead.
  Status  - report current state of services and the site
  Restart - Down (keeping data) then Up

.PARAMETER InstallRoot
  Single centralized folder everything lives under (apache/php/mysql/www/cache/logs/
  _provisioning) - back the whole tree up by copying this one directory. Default: C:\MediaWikiStack

.EXAMPLE
  ./provision-mediawiki.ps1
  Full one-click native install, port 8080.

.EXAMPLE
  ./provision-mediawiki.ps1 -Action Down
  Full teardown - services removed, InstallRoot deleted.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Up', 'Down', 'Status', 'Restart')]
    [string]$Action = 'Up',

    [switch]$KeepData,

    [string]$InstallRoot = 'C:\MediaWikiStack',
    [string]$SiteName = 'MyWiki',
    [string]$WikiAdminUser = 'Admin',
    [string]$WikiAdminPassword = $null,
    [string]$DbRootPassword = $null,
    [string]$DbUserPassword = $null,
    [int]$HttpPort = 8080,
    [int]$DbPort = 3306,

    # Wikimedia's extension mirrors are tagged by REL branch, e.g. REL1_43. Bump this when a
    # newer stable branch is out - everything else derives from it via GitHub zip archives.
    [string]$MwBranch = 'REL1_43',

    # Direct-download URLs. Vendor pages (Apache Lounge / windows.php.net / MySQL) change
    # exact filenames over time with no stable "latest" redirect - if a download 404s, visit
    # the vendor page shown in the error, copy the current link, and pass the override here.
    [string]$ApacheZipUrl    = 'https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.66-251206-Win64-VS17.zip',
    [string]$ModFcgidZipUrl  = 'https://www.apachelounge.com/download/VS17/modules/mod_fcgid-2.3.10-win64-VS17.zip',
    [string]$PhpZipUrl       = 'https://downloads.php.net/~windows/releases/php-8.2.33-nts-Win32-vs16-x64.zip',
    [string]$ApcuZipUrl      = 'https://downloads.php.net/~windows/pecl/releases/apcu/5.1.28/php_apcu-5.1.28-8.2-nts-vs16-x64.zip',
    [string]$MySqlZipUrl     = 'https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.11-winx64.zip',

    [switch]$Force,

    [ValidateSet('Dev', 'Prod')]
    [string]$Environment = 'Dev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Centralized layout - everything lives under $InstallRoot for easy backup.
# ---------------------------------------------------------------------------
$Script:Root         = $InstallRoot
$Script:ApacheDir    = Join-Path $Script:Root 'apache'
$Script:PhpDir       = Join-Path $Script:Root 'php'
$Script:MysqlDir     = Join-Path $Script:Root 'mysql'
$Script:WwwDir       = Join-Path $Script:Root 'www'
$Script:CacheDir     = Join-Path $Script:Root 'cache'
$Script:LogsDir      = Join-Path $Script:Root 'logs'
$Script:ProvDir      = Join-Path $Script:Root '_provisioning'
$Script:DownloadDir  = Join-Path $Script:ProvDir 'downloads'
$Script:LogFile      = Join-Path $Script:ProvDir 'provision.log'
$Script:StateFile    = Join-Path $Script:ProvDir 'install-state.json'
$Script:CredFile     = Join-Path $Script:ProvDir 'credentials.generated.txt'

$Script:ApacheServiceName = 'MediaWikiApache'
$Script:MysqlServiceName  = 'MediaWikiMySQL'
$Script:DbName            = 'mediawiki'
$Script:DbUser            = 'mediawiki'
$Script:DbHost            = '127.0.0.1'
$Script:MarkerBegin       = '# === provision-mediawiki.ps1 managed block: BEGIN (do not edit by hand) ==='
$Script:MarkerEnd         = '# === provision-mediawiki.ps1 managed block: END ==='

# Curated "vanilla plus" extension set - everything obtainable as a GitHub zip archive with
# no compiled/native dependency beyond what Composer pulls in pure PHP. Deliberately excluded:
# CirrusSearch (needs a separate Elasticsearch cluster), PdfHandler (needs Ghostscript),
# Mermaid/EmbedVideo (not wikimedia/ GitHub repos - Composer- or non-standard-source only) -
# all are heavier/out-of-scope for a single-box, no-extra-services install.
$Script:ZipExtensions = @(
    'ParserFunctions', 'Scribunto', 'Cite', 'CategoryTree', 'InputBox', 'Interwiki',
    'Nuke', 'RenameUser', 'ConfirmEdit', 'WikiEditor', 'VisualEditor', 'PageForms', 'ReplaceText',
    # --- dev-house QoL additions ---
    'CodeMirror',                  # syntax-aware wikitext editing (no extra dependency)
    'TemplateData',                # template parameter docs, pairs with VisualEditor/PageForms
    'TemplateWizard',              # GUI template-insertion dialog in VisualEditor
    'LabeledSectionTransclusion',  # reuse page sections across docs (reduce duplication)
    'AbuseFilter',                 # rule-based edit safety net (e.g. mass blank/rapid-edit guard)
    'CheckUser',                   # admin audit trail of which account/IP made an edit
    'Math'                         # <math> LaTeX/MathML rendering
)
# SyntaxHighlight_GeSHi needs a Python interpreter (bundles Pygments) - not part of a default
# Windows Server install, so only add it when one is actually on PATH.
if (Get-Command python, python3, py -ErrorAction SilentlyContinue | Select-Object -First 1) {
    $Script:ZipExtensions += 'SyntaxHighlight_GeSHi'
} else {
    Write-Warning 'No Python interpreter found on PATH - skipping SyntaxHighlight_GeSHi (code block highlighting). Install Python and re-run to add it.'
}

function Write-Step { param([string]$Message) $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message; Write-Host $l -ForegroundColor Cyan; Add-Content -Path $Script:LogFile -Value $l -ErrorAction SilentlyContinue }
function Write-Note { param([string]$Message) $l = "         {0}" -f $Message; Write-Host $l -ForegroundColor DarkGray; Add-Content -Path $Script:LogFile -Value $l -ErrorAction SilentlyContinue }
function Write-Warn { param([string]$Message) $l = "WARNING: {0}" -f $Message; Write-Host $l -ForegroundColor Yellow; Add-Content -Path $Script:LogFile -Value $l -ErrorAction SilentlyContinue }

function Get-State {
    if (Test-Path $Script:StateFile) { return Get-Content $Script:StateFile -Raw | ConvertFrom-Json -AsHashtable }
    return @{
        rootCreated          = $false
        apacheServiceCreated = $false
        mysqlServiceCreated  = $false
        apacheIsForeign      = $false
        mysqlIsForeign       = $false
    }
}
function Save-State { param($State) $State | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:StateFile }

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated (Administrator) PowerShell 7 session - service install/Apache require it.'
    }
}

function New-RandomPassword {
    param([int]$Length = 20)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    -join (1..$Length | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

function Confirm-Override {
    param([string]$What, [string]$Detail)
    if ($Force) { Write-Warn "Overriding existing $What (-Force set): $Detail"; return }
    Write-Host "`n!!! EXISTING $What DETECTED !!!" -ForegroundColor Red
    Write-Host $Detail -ForegroundColor Yellow
    Write-Host 'This was already on the machine before this script ran - teardown will not be able to fully undo changes to it.' -ForegroundColor Yellow
    $resp = Read-Host "`nType YES to override and continue, anything else halts"
    if ($resp -ne 'YES') { throw "Halted: did not confirm override of existing $What. Re-run with -Force to skip this prompt." }
}

function Get-RemoteFile {
    param([string]$Url, [string]$Destination, [string]$VendorPageOnFailure)
    if (Test-Path $Destination) { Write-Note "Already downloaded: $(Split-Path $Destination -Leaf)"; return }
    Write-Note "Downloading $Url ..."
    try {
        # Some vendors (Apache Lounge, MySQL's CDN) reject requests without TLS1.2 explicitly
        # negotiated and/or a browser-like User-Agent - plain Invoke-WebRequest defaults fail
        # against them with an opaque "Operation is not valid..." / 403 error.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } -MaximumRedirection 5
    } catch {
        Remove-Item $Destination -ErrorAction SilentlyContinue
        throw "Download failed: $Url`n  Vendor pages change exact filenames over time - check $VendorPageOnFailure for the current link and re-run with the matching -*Url override.`n  Original error: $($_.Exception.Message)"
    }
}

function Expand-ToDir {
    param([string]$ZipPath, [string]$TargetDir)
    $tmp = Join-Path $Script:DownloadDir ([IO.Path]::GetRandomFileName())
    Expand-Archive -Path $ZipPath -DestinationPath $tmp -Force
    $entries = Get-ChildItem $tmp
    $dirs = @($entries | Where-Object PSIsContainer)
    New-Item -ItemType Directory -Force -Path (Split-Path $TargetDir -Parent) | Out-Null
    # Zip has one real payload folder (typical for GitHub archives / Apache Lounge, which
    # also litters top-level stray files like ReadMe.txt alongside it) - unwrap just that one.
    $source = if ($dirs.Count -eq 1) { $dirs[0].FullName } else { $tmp }
    if (Test-Path $TargetDir) {
        # Target already exists (e.g. www\ pre-created by an earlier step) - merge contents in
        # rather than moving the source folder itself, which would nest it one level too deep.
        Get-ChildItem -Path $source -Force | Move-Item -Destination $TargetDir -Force
    } else {
        Move-Item $source $TargetDir -Force
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Apache (direct download, mod_fcgid, no IIS anywhere)
# ---------------------------------------------------------------------------
function Install-ApacheBinaries {
    param([hashtable]$State)
    if (Test-Path (Join-Path $Script:ApacheDir 'bin\httpd.exe')) { Write-Note 'Apache binaries already present.'; return }
    Write-Step 'Downloading + extracting Apache HTTP Server (Apache Lounge)...'
    $zip = Join-Path $Script:DownloadDir 'httpd.zip'
    Get-RemoteFile -Url $ApacheZipUrl -Destination $zip -VendorPageOnFailure 'https://www.apachelounge.com/download.html'
    Expand-ToDir -ZipPath $zip -TargetDir $Script:ApacheDir

    Write-Step 'Downloading + extracting mod_fcgid (Apache Lounge)...'
    $fcgidZip = Join-Path $Script:DownloadDir 'mod_fcgid.zip'
    Get-RemoteFile -Url $ModFcgidZipUrl -Destination $fcgidZip -VendorPageOnFailure 'https://www.apachelounge.com/download.html'
    $fcgidTmp = Join-Path $Script:DownloadDir 'mod_fcgid_extracted'
    Expand-Archive -Path $fcgidZip -DestinationPath $fcgidTmp -Force
    $fcgidSo = Get-ChildItem $fcgidTmp -Recurse -Filter 'mod_fcgid.so' | Select-Object -First 1
    if (-not $fcgidSo) { throw 'mod_fcgid.so not found in downloaded archive - check the zip layout / -ModFcgidZipUrl.' }
    Copy-Item $fcgidSo.FullName (Join-Path $Script:ApacheDir 'modules\mod_fcgid.so') -Force
    Remove-Item $fcgidTmp -Recurse -Force -ErrorAction SilentlyContinue
}

function Set-ApacheConfig {
    param([hashtable]$State)
    $foreign = (Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue) -and (-not $State.apacheServiceCreated)
    if ($foreign) {
        Confirm-Override -What "Windows service '$($Script:ApacheServiceName)'" -Detail 'A service with this exact name already exists and was not created by this script.'
    }
    $State.apacheIsForeign = $foreign
    Save-State $State

    Write-Step 'Writing Apache config (vhost, mod_fcgid, gzip, cache headers)...'
    # httpd -t validates DocumentRoot exists at config-load time even before MediaWiki's own
    # files land there later in Invoke-Up - an empty placeholder is enough to pass validation.
    New-Item -ItemType Directory -Force -Path $Script:WwwDir | Out-Null
    $phpCgi = Join-Path $Script:PhpDir 'php-cgi.exe'
    $vhostPath = Join-Path $Script:ApacheDir 'conf\extra\httpd-mediawiki.conf'
    $mainConf = Join-Path $Script:ApacheDir 'conf\httpd.conf'

    # Base conf shipped by Apache Lounge already has module lines for rewrite/deflate/expires/
    # headers commented in by default; ensure they're active and point ServerRoot at our copy.
    $conf = Get-Content $mainConf -Raw
    $conf = $conf -replace '(?m)^\s*#\s*(LoadModule (rewrite|deflate|expires|headers)_module.*)$', '$1'
    $conf = $conf -replace '(?m)^ServerRoot\s+.*$', "ServerRoot ""$($Script:ApacheDir -replace '\\','/')"""
    # Apache Lounge's shipped httpd.conf hardcodes the DocumentRoot/<Directory> it was built
    # with (e.g. C:/Apache24-64/htdocs) - httpd validates this path exists at config-load time
    # even though our own vhost (below) is what actually serves requests, so point it at our
    # MediaWiki root instead of leaving a dangling reference to a path that was never extracted here.
    $wwwSlash = $Script:WwwDir -replace '\\', '/'
    $conf = $conf -replace '(?m)^DocumentRoot\s+.*$', "DocumentRoot ""$wwwSlash"""
    $conf = $conf -replace '(?m)^(\s*<Directory\s+")[^"]*("[^>]*>)', "`${1}$wwwSlash`${2}"
    $conf = $conf -replace '(?m)^Listen\s+80\s*$', "Listen $HttpPort"
    if ($conf -notmatch 'LoadModule fcgid_module') { $conf += "`r`nLoadModule fcgid_module modules/mod_fcgid.so" }

    # --- Perf tuning: Apache Lounge builds use the winnt MPM (one process, many threads) on
    # Windows - ThreadsPerChild is the main lever; mod_fcgid's own request-queue/process-reuse
    # settings avoid re-spawning php-cgi.exe per request, which is the #1 killer of FastCGI perf.
    if ($conf -notmatch '<IfModule mpm_winnt_module>') {
        $conf += @"

<IfModule mpm_winnt_module>
    ThreadsPerChild 150
    MaxConnectionsPerChild 0
</IfModule>
KeepAlive On
MaxKeepAliveRequests 200
KeepAliveTimeout 5

<IfModule fcgid_module>
    FcgidMaxRequestsPerProcess 500
    FcgidMinProcessesPerClass 2
    FcgidMaxProcessesPerClass 20
    FcgidIOTimeout 60
    FcgidBusyTimeout 60
</IfModule>
"@
    }
    if ($conf -notmatch 'Include conf/extra/httpd-mediawiki\.conf') { $conf += "`r`nInclude conf/extra/httpd-mediawiki.conf`r`n" }
    Set-Content -Path $mainConf -Value $conf -Encoding UTF8

    New-Item -ItemType Directory -Force -Path $Script:LogsDir | Out-Null
    # Apache's own config parser treats a bare backslash as an escape character even inside
    # quoted directive values on Windows - always use forward slashes in httpd.conf paths.
    $phpCgiSlash = $phpCgi -replace '\\', '/'
    $phpDirSlash = $Script:PhpDir -replace '\\', '/'
    $vhost = @"
$($Script:MarkerBegin)
<IfModule fcgid_module>
  FcgidInitialEnv PHPRC "$phpDirSlash"
  AddHandler fcgid-script .php
  FcgidWrapper "$phpCgiSlash" .php
</IfModule>

<VirtualHost *:$HttpPort>
    DocumentRoot "$($Script:WwwDir -replace '\\','/')"
    <Directory "$($Script:WwwDir -replace '\\','/')">
        Options FollowSymLinks ExecCGI
        AllowOverride All
        Require all granted
        DirectoryIndex index.php
    </Directory>

    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/plain text/css application/javascript application/json
    </IfModule>
    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType image/png "access plus 30 days"
        ExpiresByType image/jpeg "access plus 30 days"
        ExpiresByType text/css "access plus 7 days"
        ExpiresByType application/javascript "access plus 7 days"
    </IfModule>

    ErrorLog "$($Script:LogsDir -replace '\\','/')/mediawiki-error.log"
    CustomLog "$($Script:LogsDir -replace '\\','/')/mediawiki-access.log" common
</VirtualHost>
$($Script:MarkerEnd)
"@
    Set-Content -Path $vhostPath -Value $vhost -Encoding UTF8

    $httpdExe = Join-Path $Script:ApacheDir 'bin\httpd.exe'
    & $httpdExe -t
    if ($LASTEXITCODE -ne 0) { throw 'Apache config test failed (httpd -t) - see output above.' }

    if (-not (Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue)) {
        & $httpdExe -k install -n $Script:ApacheServiceName | Out-Null
        $State.apacheServiceCreated = $true
        Save-State $State
    }
    Restart-Service -Name $Script:ApacheServiceName -Force
    Write-Note "Apache service '$($Script:ApacheServiceName)' running on port $HttpPort."
}

# ---------------------------------------------------------------------------
# PHP (direct download, php-cgi via mod_fcgid, APCu for object/opcode caching)
# ---------------------------------------------------------------------------
function Install-Php {
    if (Test-Path (Join-Path $Script:PhpDir 'php.exe')) { Write-Note 'PHP already present.'; return }
    Write-Step 'Downloading + extracting PHP (windows.php.net)...'
    $zip = Join-Path $Script:DownloadDir 'php.zip'
    Get-RemoteFile -Url $PhpZipUrl -Destination $zip -VendorPageOnFailure 'https://windows.php.net/download/'
    New-Item -ItemType Directory -Force -Path $Script:PhpDir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $Script:PhpDir -Force

    Write-Step 'Downloading + installing APCu extension (object/opcode cache)...'
    $apcuZip = Join-Path $Script:DownloadDir 'apcu.zip'
    try {
        Get-RemoteFile -Url $ApcuZipUrl -Destination $apcuZip -VendorPageOnFailure 'https://windows.php.net/downloads/pecl/releases/apcu/'
        $apcuTmp = Join-Path $Script:DownloadDir 'apcu_extracted'
        Expand-Archive -Path $apcuZip -DestinationPath $apcuTmp -Force
        $dll = Get-ChildItem $apcuTmp -Filter 'php_apcu.dll' -Recurse | Select-Object -First 1
        if ($dll) { Copy-Item $dll.FullName (Join-Path $Script:PhpDir 'ext\php_apcu.dll') -Force }
        Remove-Item $apcuTmp -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warn "APCu download failed ($($_.Exception.Message)) - falling back to CACHE_DB for the object cache. MediaWiki still works, just without APCu's speed."
    }
}

function Set-PhpIni {
    Write-Step 'Configuring php.ini (extensions, OPcache/APCu, upload limits)...'
    $iniPath = Join-Path $Script:PhpDir 'php.ini'
    $srcIni = Join-Path $Script:PhpDir 'php.ini-production'
    if (-not (Test-Path $iniPath)) { Copy-Item $srcIni $iniPath }
    $ini = Get-Content $iniPath -Raw
    $extDir = Join-Path $Script:PhpDir 'ext'

    function Set-IniValue {
        param([string]$Content, [string]$Key, [string]$Value)
        # Matched on key+value together (not key alone) - several calls share the same key
        # (e.g. "extension" for mysqli/intl/apcu/...) and must coexist as separate lines rather
        # than each replacing the previous module's line.
        $line = "$Key = $Value"
        $pattern = "(?m)^\s*$([regex]::Escape($line))\s*$"
        if ($Content -match $pattern) { return $Content }
        return $Content + "`r`n$line`r`n"
    }

    $ini = Set-IniValue $ini 'extension_dir' "`"$extDir`""
    foreach ($ext in @('openssl', 'mysqli', 'intl', 'mbstring', 'curl', 'gd', 'xml', 'fileinfo')) {
        if (Test-Path (Join-Path $extDir "php_$ext.dll")) { $ini = Set-IniValue $ini 'extension' $ext }
    }
    # opcache is a Zend Extension, not an ordinary extension - loading it via "extension=" fails
    # with "Invalid library (appears to be a Zend Extension...)".
    if (Test-Path (Join-Path $extDir 'php_opcache.dll')) { $ini = Set-IniValue $ini 'zend_extension' 'opcache' }
    $Script:ApcuAvailable = Test-Path (Join-Path $extDir 'php_apcu.dll')
    if ($Script:ApcuAvailable) {
        $ini = Set-IniValue $ini 'extension' 'apcu'
        $ini += "`r`napc.enable_cli = 0`r`n"
    }

    $ini = Set-IniValue $ini 'opcache.enable' '1'
    $ini = Set-IniValue $ini 'opcache.enable_cli' '0'
    $ini = Set-IniValue $ini 'opcache.memory_consumption' '256'
    $ini = Set-IniValue $ini 'opcache.interned_strings_buffer' '16'
    $ini = Set-IniValue $ini 'opcache.max_accelerated_files' '20000'
    $ini = Set-IniValue $ini 'opcache.validate_timestamps' $(if ($Environment -eq 'Prod') { '0' } else { '1' })
    $ini = Set-IniValue $ini 'opcache.revalidate_freq' '2'
    $ini = Set-IniValue $ini 'upload_max_filesize' '64M'
    $ini = Set-IniValue $ini 'post_max_size' '64M'
    $ini = Set-IniValue $ini 'memory_limit' '256M'
    $ini = Set-IniValue $ini 'max_execution_time' '120'
    $ini = Set-IniValue $ini 'date.timezone' 'UTC'

    Set-Content -Path $iniPath -Value $ini -Encoding UTF8
    Write-Note "php.ini: $iniPath (APCu: $(if ($Script:ApcuAvailable) { 'enabled' } else { 'unavailable, using CACHE_DB fallback' }))"
}

# ---------------------------------------------------------------------------
# MySQL (native, direct zip download - no installer, no service manager)
# ---------------------------------------------------------------------------
function Install-MySql {
    param([hashtable]$State)
    $foreign = (Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue) -and (-not $State.mysqlServiceCreated)
    if ($foreign) {
        Confirm-Override -What "Windows service '$($Script:MysqlServiceName)'" -Detail 'A service with this exact name already exists and was not created by this script.'
    }
    $State.mysqlIsForeign = $foreign
    Save-State $State

    if (Test-Path (Join-Path $Script:MysqlDir 'bin\mysqld.exe')) {
        Write-Note 'MySQL binaries already present.'
    } else {
        Write-Step 'Downloading + extracting MySQL Community Server (zip, no installer)...'
        $zip = Join-Path $Script:DownloadDir 'mysql.zip'
        Get-RemoteFile -Url $MySqlZipUrl -Destination $zip -VendorPageOnFailure 'https://dev.mysql.com/downloads/mysql/ (choose "Windows (x86, 64-bit), ZIP Archive")'
        Expand-ToDir -ZipPath $zip -TargetDir $Script:MysqlDir
    }

    $dataDir = Join-Path $Script:MysqlDir 'data'
    $iniPath = Join-Path $Script:MysqlDir 'my.ini'
    if (-not (Test-Path $iniPath)) {
        # Perf tuning sized for a single-box wiki (not a shared/multi-tenant DB server):
        # innodb_buffer_pool_size is the single biggest MySQL perf lever - large enough to
        # hold the working set (page/revision tables) in memory instead of hitting disk.
        $totalMemMB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
        $bufferPoolMB = [math]::Max(256, [math]::Min(2048, [math]::Floor($totalMemMB * 0.25)))
        @"
[mysqld]
port=$DbPort
basedir=$($Script:MysqlDir)
datadir=$dataDir
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

# --- Perf tuning for a single-box MediaWiki install ---
innodb_buffer_pool_size=${bufferPoolMB}M
innodb_log_file_size=128M
innodb_flush_log_at_trx_commit=2
max_connections=150
table_open_cache=2000
thread_cache_size=16
tmp_table_size=64M
max_heap_table_size=64M
"@ | Set-Content $iniPath
    }

    $mysqldExe = Join-Path $Script:MysqlDir 'bin\mysqld.exe'
    if (-not (Test-Path $dataDir)) {
        Write-Step 'Initializing MySQL data directory...'
        & $mysqldExe --defaults-file=$iniPath --initialize-insecure --datadir=$dataDir 2>&1 | Out-Null
    }

    if (-not (Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue)) {
        Write-Step "Registering MySQL Windows service '$($Script:MysqlServiceName)'..."
        & $mysqldExe --install $Script:MysqlServiceName --defaults-file=$iniPath | Out-Null
        $State.mysqlServiceCreated = $true
        Save-State $State
    }
    Start-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue

    $mysqlExe = Join-Path $Script:MysqlDir 'bin\mysql.exe'
    Write-Note 'Waiting for MySQL to accept connections...'
    # Poll the TCP port, not an authenticated query - once root's password has been set (below),
    # a passwordless login attempt fails even though the server is up and healthy.
    $deadline = (Get-Date).AddSeconds(60)
    $ready = $false
    do {
        Start-Sleep -Seconds 2
        $ready = (Test-NetConnection -ComputerName 'localhost' -Port $DbPort -WarningAction SilentlyContinue).TcpTestSucceeded
    } until ($ready -or (Get-Date) -gt $deadline)
    if (-not $ready) { throw 'MySQL service did not become ready in time - check logs under the mysql\data directory.' }

    # Root/mediawiki-user passwords may already have been set by a prior partial run - reuse them
    # (from the credentials file, written early below) rather than re-running with fresh passwords
    # we then can't authenticate with next time.
    if (-not $DbRootPassword -and (Test-Path $Script:CredFile)) {
        $m = Select-String -Path $Script:CredFile -Pattern '^DB root pass:\s*(.+)$'
        if ($m) { $DbRootPassword = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $DbUserPassword -and (Test-Path $Script:CredFile)) {
        $m = Select-String -Path $Script:CredFile -Pattern '^DB user pass:\s*(.+)$'
        if ($m) { $DbUserPassword = $m.Matches[0].Groups[1].Value.Trim() }
    }

    $rootAuthArgs = @('-uroot', '--skip-password')
    if ($DbRootPassword) {
        & $mysqlExe -uroot "-p$DbRootPassword" -e 'SELECT 1' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $rootAuthArgs = @('-uroot', "-p$DbRootPassword") }
    }

    if (-not $DbRootPassword) { $DbRootPassword = New-RandomPassword }
    if (-not $DbUserPassword) { $DbUserPassword = New-RandomPassword }
    $Script:DbRootPassword = $DbRootPassword
    $Script:DbUserPassword = $DbUserPassword

    # Written now (not just at the very end of Invoke-Up) so a script failure partway through a
    # later step still leaves the passwords actually in effect discoverable on the next re-run.
    @"
Generated $(Get-Date -Format o)
DB root pass:    $DbRootPassword
DB user pass:    $DbUserPassword
"@ | Set-Content -Path $Script:CredFile
    icacls $Script:CredFile /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null

    $sql = @"
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DbRootPassword';
CREATE DATABASE IF NOT EXISTS $($Script:DbName) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$($Script:DbUser)'@'localhost';
ALTER USER '$($Script:DbUser)'@'localhost' IDENTIFIED BY '$DbUserPassword';
GRANT ALL PRIVILEGES ON $($Script:DbName).* TO '$($Script:DbUser)'@'localhost';
FLUSH PRIVILEGES;
"@
    $sql | & $mysqlExe @rootAuthArgs 2>$null
}

# ---------------------------------------------------------------------------
# MediaWiki core + extensions (GitHub zip archives - no git dependency)
# ---------------------------------------------------------------------------
function Get-GitHubZip {
    param([string]$Owner, [string]$Repo, [string]$Branch, [string]$TargetDir)
    $zip = Join-Path $Script:DownloadDir "$Repo-$Branch.zip"
    $url = "https://github.com/$Owner/$Repo/archive/refs/heads/$Branch.zip"
    Get-RemoteFile -Url $url -Destination $zip -VendorPageOnFailure "https://github.com/$Owner/$Repo/branches"
    Expand-ToDir -ZipPath $zip -TargetDir $TargetDir
}

function Get-ComposerPhar {
    $pharPath = Join-Path $Script:ProvDir 'composer.phar'
    if (Test-Path $pharPath) { return $pharPath }
    Write-Step 'Downloading composer.phar...'
    Get-RemoteFile -Url 'https://getcomposer.org/composer.phar' -Destination $pharPath -VendorPageOnFailure 'https://getcomposer.org/download/'
    return $pharPath
}

function Invoke-Composer {
    param([string[]]$ComposerArgs, [string]$WorkingDir)
    $phpExe = Join-Path $Script:PhpDir 'php.exe'
    $phar = Get-ComposerPhar
    Push-Location $WorkingDir
    try { & $phpExe $phar @ComposerArgs --no-interaction 2>&1 | Tee-Object -Variable out | Out-Null; Add-Content $Script:LogFile $out }
    finally { Pop-Location }
}

function Get-MediaWikiCore {
    param([hashtable]$State)
    if (Test-Path (Join-Path $Script:WwwDir 'includes\WebStart.php')) {
        Write-Note 'MediaWiki core already present.'
    } else {
        Write-Step "Downloading MediaWiki core ($MwBranch)..."
        Get-GitHubZip -Owner 'wikimedia' -Repo 'mediawiki' -Branch $MwBranch -TargetDir $Script:WwwDir

        # Core's own extensions/skins are git submodules; a plain zip download (no git) leaves
        # them as empty placeholder directories. Remove those so Install-ZipExtensions's
        # presence check doesn't mistake an empty placeholder for a real, already-installed copy.
        foreach ($sub in @('extensions', 'skins')) {
            $subDir = Join-Path $Script:WwwDir $sub
            if (Test-Path $subDir) {
                Get-ChildItem $subDir -Directory | Where-Object { (Get-ChildItem $_.FullName -Force | Measure-Object).Count -eq 0 } | Remove-Item -Force
            }
        }
    }

    # Core's vendor/ dir (autoloader + external libraries) isn't part of the GitHub zip - it's
    # only produced by Composer, so this must run even when core was already present from an
    # earlier partial run that didn't get this far.
    if (-not (Test-Path (Join-Path $Script:WwwDir 'vendor\autoload.php'))) {
        Write-Step 'Running composer install for MediaWiki core (production deps)...'
        Invoke-Composer -ComposerArgs @('install', '--no-dev', '--optimize-autoloader') -WorkingDir $Script:WwwDir
    }
}

function Install-ZipExtensions {
    Write-Step 'Installing extensions (GitHub zip archives + composer where needed)...'
    foreach ($ext in $Script:ZipExtensions) {
        $extDir = Join-Path $Script:WwwDir "extensions\$ext"
        if (Test-Path (Join-Path $extDir 'extension.json')) { Write-Note "$ext already present, skipping."; continue }
        if (Test-Path $extDir) { Remove-Item $extDir -Recurse -Force }
        Write-Note "Downloading $ext ($MwBranch)..."
        try {
            Get-GitHubZip -Owner 'wikimedia' -Repo "mediawiki-extensions-$ext" -Branch $MwBranch -TargetDir $extDir
        } catch {
            Write-Warn "could not download $ext for branch $MwBranch - skipping. ($($_.Exception.Message))"
            continue
        }
        if (Test-Path (Join-Path $extDir 'composer.json')) {
            Invoke-Composer -ComposerArgs @('install', '--no-dev') -WorkingDir $extDir
        }
    }
}

function Install-SemanticMediaWiki {
    $smwDir = Join-Path $Script:WwwDir 'extensions\SemanticMediaWiki'
    if (Test-Path $smwDir) { Write-Note 'SemanticMediaWiki already present, skipping.'; return }
    Write-Step 'Installing SemanticMediaWiki via Composer (upstream-recommended method)...'
    $composerLocal = Join-Path $Script:WwwDir 'composer.local.json'
    if (-not (Test-Path $composerLocal)) {
        # ~4.5 doesn't exist (SMW jumps 4.2.0 -> 5.0.0) - allow any current major so Composer can
        # resolve whichever is compatible with the installed MediaWiki core version.
        @{ require = @{ 'mediawiki/semantic-media-wiki' = '^5.0 || ^6.0 || ^7.0' } } | ConvertTo-Json | Set-Content $composerLocal
    }
    Invoke-Composer -ComposerArgs @('update', 'mediawiki/semantic-media-wiki', '--no-dev') -WorkingDir $Script:WwwDir
    if (-not (Test-Path $smwDir)) { Write-Warn 'SemanticMediaWiki did not install via Composer - check provision.log.' }
}

function Install-MediaWikiDatabase {
    if (Test-Path (Join-Path $Script:WwwDir 'LocalSettings.php')) { Write-Note 'LocalSettings.php already exists - skipping web installer.'; return }
    Write-Step 'Running MediaWiki installer...'
    $phpExe = Join-Path $Script:PhpDir 'php.exe'
    Push-Location $Script:WwwDir
    try {
        $runner = if (Test-Path 'maintenance\run.php') { @('maintenance\run.php', 'install') } else { @('maintenance\install.php') }
        $installArgs = $runner + @(
            "--dbname=$($Script:DbName)", "--dbserver=$($Script:DbHost):$DbPort",
            "--dbuser=$($Script:DbUser)", "--dbpass=$Script:DbUserPassword",
            "--server=http://localhost:$HttpPort", '--scriptpath=', '--lang=en',
            "--pass=$Script:WikiAdminPassword", $SiteName, $WikiAdminUser
        )
        & $phpExe @installArgs
        if ($LASTEXITCODE -ne 0) { throw 'MediaWiki installer failed - see output above.' }
    } finally { Pop-Location }
}

function Add-ManagedSettingsBlock {
    param([string]$Block)
    $path = Join-Path $Script:WwwDir 'LocalSettings.php'
    $content = Get-Content $path -Raw
    if ($content -match [regex]::Escape($Script:MarkerBegin)) {
        $pattern = "(?s)$([regex]::Escape($Script:MarkerBegin)).*?$([regex]::Escape($Script:MarkerEnd))"
        $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Block })
    } else {
        $content += "`n$Block`n"
    }
    Set-Content -Path $path -Value $content -Encoding UTF8
}

function Set-UploadsAndPermissions {
    Write-Step 'Configuring file uploads (images dir + permissions)...'
    $imagesDir = Join-Path $Script:WwwDir 'images'
    New-Item -ItemType Directory -Force -Path $imagesDir, "$imagesDir\thumb", "$imagesDir\temp", "$imagesDir\deleted", $Script:CacheDir | Out-Null

    # Apache's service runs as LocalSystem by default (implicitly has access everywhere), but
    # grant explicit Modify rights on every directory PHP/Apache actually write to - correct
    # practice regardless of which account ends up running the service, and makes intent explicit.
    foreach ($dir in @($imagesDir, $Script:CacheDir, $Script:LogsDir)) {
        icacls $dir /grant:r 'NT AUTHORITY\SYSTEM:(OI)(CI)M' 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null
    }
}

function Set-PerformanceAndCaching {
    Write-Step 'Applying caching + performance best-practice settings to LocalSettings.php...'
    New-Item -ItemType Directory -Force -Path $Script:CacheDir | Out-Null
    $debugLine = if ($Environment -eq 'Dev') { '$wgShowExceptionDetails = true;' } else { '$wgShowExceptionDetails = false;' }
    $cacheType = if ($Script:ApcuAvailable) { 'CACHE_ACCEL' } else { 'CACHE_DB' }

    $block = @"
$($Script:MarkerBegin)
// --- Object/parser/session cache: APCu if available, otherwise DB (see provision.log) ---
`$wgMainCacheType    = $cacheType;
`$wgSessionCacheType  = $cacheType;
`$wgMessageCacheType  = $cacheType;
`$wgParserCacheType   = $cacheType;

// --- Anonymous-view file cache: skips PHP entirely for logged-out page views ---
`$wgUseFileCache      = true;
`$wgFileCacheDirectory = '$($Script:CacheDir -replace '\\','\\\\')';
`$wgUseGzip           = true;

// --- ResourceLoader / static asset caching ---
`$wgResourceLoaderMaxage['versioned']   = 30 * 24 * 3600;
`$wgResourceLoaderMaxage['unversioned'] = 5 * 60;

// --- Sane defaults for a modern wiki ---
`$wgEnableAPI         = true;
`$wgEnableWriteAPI    = true;
`$wgDefaultSkin       = 'vector-2022';
$debugLine

// --- File uploads (images dir created + permissioned by the provisioning script) ---
`$wgEnableUploads     = true;
`$wgUseImageMagick    = false; // GD (already enabled in php.ini) handles thumbnailing - no extra binary needed
`$wgUploadDirectory   = "`$IP/images";
`$wgUploadPath        = "`$wgScriptPath/images";
`$wgFileExtensions    = array_merge( `$wgFileExtensions, [ 'png', 'jpg', 'jpeg', 'gif', 'svg', 'pdf', 'webp' ] );
`$wgMaxUploadSize      = 64 * 1024 * 1024; // matches php.ini upload_max_filesize/post_max_size

// --- Extensions (curated "vanilla plus" set) ---
"@
    foreach ($ext in $Script:ZipExtensions) {
        if (Test-Path (Join-Path $Script:WwwDir "extensions\$ext")) { $block += "`nwfLoadExtension( '$ext' );" }
    }
    if (Test-Path (Join-Path $Script:WwwDir 'extensions\SemanticMediaWiki')) {
        # enableSemantics() alone is deprecated in modern SMW - it now requires the explicit
        # wfLoadExtension call first (see extensions/SemanticMediaWiki/docs/INSTALL.md).
        $block += "`nwfLoadExtension( 'SemanticMediaWiki' );`nenableSemantics( 'localhost:$HttpPort' );"
    }
    $block += "`n$($Script:MarkerEnd)"
    Add-ManagedSettingsBlock -Block $block
}

function Complete-Installation {
    Write-Step 'Running update.php (schema for core + all extensions)...'
    $phpExe = Join-Path $Script:PhpDir 'php.exe'
    Push-Location $Script:WwwDir
    try {
        $runner = if (Test-Path 'maintenance\run.php') { @('maintenance\run.php', 'update') } else { @('maintenance\update.php') }
        & $phpExe @runner --quick 2>&1 | Tee-Object -Variable out | Out-Null
        Add-Content $Script:LogFile $out
    } finally { Pop-Location }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
function Invoke-Up {
    Assert-Admin
    $rootPreexisted = Test-Path $Script:Root
    New-Item -ItemType Directory -Force -Path $Script:ProvDir, $Script:DownloadDir | Out-Null
    $state = Get-State
    if (-not $rootPreexisted -and -not $state.rootCreated) { $state.rootCreated = $true; Save-State $state }

    $Script:WikiAdminPassword = if ($WikiAdminPassword) { $WikiAdminPassword } else { New-RandomPassword }

    Install-ApacheBinaries -State $state
    Install-Php
    Set-PhpIni
    Set-ApacheConfig -State $state
    Install-MySql -State $state

    Get-MediaWikiCore -State $state
    Install-SemanticMediaWiki
    Install-ZipExtensions
    Install-MediaWikiDatabase
    Set-UploadsAndPermissions
    Set-PerformanceAndCaching
    Complete-Installation

    @"
Generated $(Get-Date -Format o)
Wiki URL:        http://localhost:$HttpPort/
Wiki admin user: $WikiAdminUser
Wiki admin pass: $($Script:WikiAdminPassword)
DB root pass:    $($Script:DbRootPassword)
DB user pass:    $($Script:DbUserPassword)
Install root:    $($Script:Root)  (back this whole folder up)
"@ | Set-Content -Path $Script:CredFile
    icacls $Script:CredFile /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null

    Write-Step 'Done.'
    Write-Note "Wiki:        http://localhost:$HttpPort/"
    Write-Note "Admin user:  $WikiAdminUser"
    Write-Note "Credentials: $($Script:CredFile)"
}

function Invoke-Down {
    $state = Get-State
    if (-not $DbRootPassword -and (Test-Path $Script:CredFile)) {
        $m = Select-String -Path $Script:CredFile -Pattern '^DB root pass:\s*(.+)$'
        if ($m) { $DbRootPassword = $m.Matches[0].Groups[1].Value.Trim() }
    }
    Write-Step "Tearing down$(if ($KeepData) { ' (stop only, -KeepData set)' } else { ' (FULL WIPE)' })..."

    # --- Apache ---
    if (Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $Script:ApacheServiceName -Force -ErrorAction SilentlyContinue
        if (-not $KeepData -and $state.apacheServiceCreated) {
            $httpdExe = Join-Path $Script:ApacheDir 'bin\httpd.exe'
            if (Test-Path $httpdExe) { & $httpdExe -k uninstall -n $Script:ApacheServiceName 2>&1 | Out-Null }
        }
    }

    # --- MySQL ---
    if (Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue) {
        if (-not $KeepData -and $state.mysqlIsForeign) {
            $mysqlExe = Join-Path $Script:MysqlDir 'bin\mysql.exe'
            if ((Test-Path $mysqlExe) -and $DbRootPassword) {
                Write-Note "Dropping only the '$($Script:DbName)' database/user (MySQL instance pre-existed - leaving it running)."
                "DROP DATABASE IF EXISTS $($Script:DbName); DROP USER IF EXISTS '$($Script:DbUser)'@'localhost';" | & $mysqlExe -uroot -p"$DbRootPassword" 2>$null
            }
        } else {
            Stop-Service -Name $Script:MysqlServiceName -Force -ErrorAction SilentlyContinue
            if (-not $KeepData -and $state.mysqlServiceCreated) {
                $mysqldExe = Join-Path $Script:MysqlDir 'bin\mysqld.exe'
                if (Test-Path $mysqldExe) { & $mysqldExe --remove $Script:MysqlServiceName 2>&1 | Out-Null }
            }
        }
    }

    if (-not $KeepData -and $state.rootCreated -and (Test-Path $Script:Root)) {
        Write-Note "Deleting $($Script:Root) (this script created it)."
        Remove-Item -Recurse -Force $Script:Root -ErrorAction SilentlyContinue
    }
    Write-Step 'Down.'
}

function Invoke-Status {
    Write-Host "`nApache service:" -ForegroundColor Yellow
    Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue | Format-Table Name, Status -AutoSize
    Write-Host 'MySQL service:' -ForegroundColor Yellow
    Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue | Format-Table Name, Status -AutoSize
    Write-Host "Site check: http://localhost:$HttpPort/" -ForegroundColor Yellow
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$HttpPort/" -UseBasicParsing -TimeoutSec 5
        Write-Host "  HTTP $($resp.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "  unreachable: $($_.Exception.Message)" -ForegroundColor Red
    }
}

switch ($Action) {
    'Up'      { Invoke-Up }
    'Down'    { Invoke-Down }
    'Status'  { Invoke-Status }
    'Restart' { $KeepData = $true; Invoke-Down; Invoke-Up }
}
