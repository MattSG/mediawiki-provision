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

.PARAMETER ConfigPath
  Path to a PowerShell data file containing parameter values. Config values are used unless
  the same option is supplied on the command line. Using a config file also enables the
  non-interactive path; copy provision.config.example.psd1 to create one.

.EXAMPLE
  ./provision-mediawiki.ps1
  Full one-click native install, port 8080.

.EXAMPLE
  ./provision-mediawiki.ps1 -Action Down
  Full teardown - services removed, InstallRoot deleted.

.NOTES
  Reading order for `-Action Up` (each numbered STEP comment below marks where it happens):
    1. Layout/config setup (script-scoped path variables, curated extension/skin lists)
    2. Apache install + config (native Windows service, no IIS)
    3. PHP install + php.ini tuning
    4. MySQL install + service + database/user provisioning
    5. Python install (embeddable, for SyntaxHighlight's bundled Pygments)
    6. MediaWiki core download + Composer install
    7. SemanticMediaWiki + curated extensions + skin download
    8. MediaWiki web installer (LocalSettings.php + database schema)
    9. Uploads/permissions + caching/perf settings + wfLoadExtension/wfLoadSkin block
    10. update.php + credentials file
  `-Action Down` (Invoke-Down) reverses steps 2-4 and 9, but only for what this script itself
  created (tracked in install-state.json) - see Confirm-Override for the pre-existing-service
  safety check.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Up', 'Down', 'Status', 'Restart', 'Backup')]
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

    [string]$ConfigPath = $null,

    # By default the script provisions its own isolated MySQL under InstallRoot. Set this to
    # point at a MySQL instance that already exists on the network/machine instead - Invoke-Up
    # then skips Install-MySql entirely and just creates the wiki's database/user on it.
    [switch]$UseExternalDb,
    [string]$DbHost = '127.0.0.1',
    [string]$ExternalDbAdminUser = 'root',
    [string]$ExternalDbAdminPassword = $null,
    [string]$ExternalDbUserHost = $null,

    # HTTPS (Prod): when both cert files are given, Apache serves over 443 with them instead of
    # (or alongside) plain HTTP, and $wgServer is set to PublicUrl. PEM format for both files -
    # see setup-local-https-test.ps1 in this repo for a way to generate/trust a matching pair
    # for local testing.
    [string]$PublicUrl = $null,
    [string]$CertPath = $null,
    [string]$CertKeyPath = $null,

    # Skips the pre-existing-Apache/MySQL confirmation prompt (same effect as -Force for that
    # specific prompt) - use for unattended/CI runs. Also skips the interactive setup wizard
    # (site name/logo/SSO) below - pass everything you want via parameters instead.
    [switch]$NonInteractive,

    # Path to a local image file to use as the wiki's logo ($wgLogos). Optional - prompted for
    # interactively on first install if not given; leave blank/skip to use MediaWiki's default.
    [string]$LogoPath = $null,

    # Entra ID (Azure AD) SSO via PluggableAuth + OpenIDConnect. Local admin login still works
    # alongside SSO (see lib/sso.ps1) so a misconfigured tenant can't lock you out. Prompted for
    # interactively if not given and not -NonInteractive.
    [switch]$EnableEntraSso,
    [string]$EntraTenantId = $null,
    [string]$EntraClientId = $null,
    [securestring]$EntraClientSecret = $null,
    # SSO settings persist across re-runs (like DB passwords) so idempotent re-runs don't need
    # -EnableEntraSso repeated every time - this explicitly turns a previously-enabled SSO back off.
    [switch]$DisableEntraSso,

    # Production QoL - all optional, all registered under one Task Scheduler folder
    # (\MediaWikiStack\, see lib/scheduledtasks.ps1). Prompted for interactively on first
    # install if not given and not -NonInteractive; the -Disable* switches turn one back off
    # on a later re-run (idempotent - re-running with none of these just leaves things as they are).
    [switch]$EnableJobRunner,          # runs maintenance/run.php runJobs periodically instead of
    [switch]$DisableJobRunner,         # relying on lumpy request-triggered job execution
    [int]$JobRunnerIntervalMinutes = 5,

    [switch]$EnableLogRotation,        # trims/archives Apache+MySQL+PHP logs so they don't grow forever
    [switch]$DisableLogRotation,

    [switch]$EnableBackups,            # daily DB dump + LocalSettings.php/images archive
    [switch]$DisableBackups,
    [string]$BackupPath = $null,       # default: <InstallRoot>\_provisioning\backups
    [int]$BackupRetentionDays = 14,

    # Wikimedia's extension mirrors are tagged by REL branch, e.g. REL1_43. Bump this when a
    # newer stable branch is out - everything else derives from it via GitHub zip archives.
    [string]$MwBranch = 'REL1_43',

    # Direct-download URLs. Vendor pages (Apache Lounge / windows.php.net / MySQL) change
    # exact filenames over time with no stable "latest" redirect - if a download 404s, visit
    # the vendor page shown in the error, copy the current link, and pass the override here.
    # Each also accepts a local path or UNC share (e.g. \\fileserver\mirrors\httpd.zip) instead
    # of a URL, for a server that can't reach the internet at all - see -ProxyUrl below for the
    # "can reach the internet, but only via a corporate proxy" case instead.
    [string]$ApacheZipUrl    = 'https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.66-251206-Win64-VS17.zip',
    [string]$ModFcgidZipUrl  = 'https://www.apachelounge.com/download/VS17/modules/mod_fcgid-2.3.10-win64-VS17.zip',
    [string]$PhpZipUrl       = 'https://downloads.php.net/~windows/releases/php-8.3.33-nts-Win32-vs16-x64.zip',
    [string]$ApcuZipUrl      = 'https://downloads.php.net/~windows/pecl/releases/apcu/5.1.28/php_apcu-5.1.28-8.3-nts-vs16-x64.zip',
    [string]$MySqlZipUrl     = 'https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.11-winx64.zip',
    [string]$PythonZipUrl    = 'https://www.python.org/ftp/python/3.14.7/python-3.14.7-embed-amd64.zip',
    [string]$ComposerPharUrl = 'https://getcomposer.org/composer.phar',
    [string]$CaBundleUrl     = 'https://curl.se/ca/cacert.pem',

    # Corporate proxy for every download this script makes (Apache/PHP/MySQL/Python zips, GitHub
    # extension/skin archives, composer.phar, the CA bundle). Omit for direct internet access.
    [string]$ProxyUrl = $null,
    [switch]$ProxyUseDefaultCredentials,
    [pscredential]$ProxyCredential = $null,

    [switch]$Force,

    [switch]$SeedDevelopmentContent,

    [ValidateSet('Dev', 'Prod')]
    [string]$Environment = 'Dev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:ExplicitParameterNames = @($PSBoundParameters.Keys)
$Script:SupportedParameterNames = @($PSCmdlet.MyInvocation.MyCommand.Parameters.Keys)

function Import-ProvisionConfig {
    if (-not $ConfigPath) { return }

    $configFile = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
    $config = Import-PowerShellDataFile -LiteralPath $configFile
    if ($config -isnot [hashtable]) { throw "Config file must contain a hashtable: $configFile" }

    foreach ($key in $config.Keys) {
        if ($key -eq 'ConfigPath' -or $Script:SupportedParameterNames -notcontains [string]$key) {
            throw "Unknown configuration option '$key' in $configFile"
        }
        if ($Script:ExplicitParameterNames -contains $key) { continue }

        $value = $config[$key]
        if ($key -eq 'EntraClientSecret' -and $value -is [string] -and $value) {
            $value = ConvertTo-SecureString -String $value
        } elseif ($key -eq 'ProxyCredential' -and $value -is [hashtable]) {
            if (-not $value.UserName -or -not $value.Password) { throw "ProxyCredential requires UserName and Password in $configFile" }
            $value = New-Object System.Management.Automation.PSCredential(
                [string]$value.UserName,
                (ConvertTo-SecureString -String ([string]$value.Password)))
        }
        Set-Variable -Name $key -Value $value -Scope Script
    }

    if ($Action -notin @('Up', 'Down', 'Status', 'Restart', 'Backup')) { throw "Invalid Action in ${configFile}: $Action" }
    if ($Environment -notin @('Dev', 'Prod')) { throw "Invalid Environment in ${configFile}: $Environment" }
    $Script:NonInteractive = $true
    Write-Host "Loaded configuration: $configFile" -ForegroundColor DarkGray
}

Import-ProvisionConfig

# A function (not inline code) because the interactive wizard can also set $PublicUrl/$CertPath/
# $CertKeyPath (offering to generate a local test cert on the spot) - Invoke-Up re-runs this
# right after the wizard so $Script:UseHttps reflects whichever way the values got set.
function Set-HttpsFlag {
    $Script:UseHttps = [bool]($PublicUrl -and $CertPath -and $CertKeyPath)
    if ($Script:UseHttps) {
        if ($PublicUrl -notmatch '^https://') { throw "-PublicUrl must start with https:// when -CertPath/-CertKeyPath are given (got: $PublicUrl)" }
        foreach ($p in @($CertPath, $CertKeyPath)) { if (-not (Test-Path $p)) { throw "Cert file not found: $p" } }
    } elseif ($PublicUrl -or $CertPath -or $CertKeyPath) {
        throw '-PublicUrl, -CertPath, and -CertKeyPath must all be given together for HTTPS, or all omitted.'
    }
}
Set-HttpsFlag

# ---------------------------------------------------------------------------
# STEP 1: Centralized layout - everything lives under $InstallRoot for easy backup.
# ---------------------------------------------------------------------------
# A function (not inline code) for the same reason as Set-HttpsFlag: the wizard can also change
# $InstallRoot itself (offering to set it interactively), so Invoke-Up re-runs this after the
# wizard to make every derived path reflect wherever the user actually chose.
function Set-Layout {
    $Script:Root         = $InstallRoot
    $Script:ApacheDir    = Join-Path $Script:Root 'apache'
    $Script:PhpDir       = Join-Path $Script:Root 'php'
    $Script:MysqlDir     = Join-Path $Script:Root 'mysql'
    $Script:PythonDir    = Join-Path $Script:Root 'python'
    $Script:WwwDir       = Join-Path $Script:Root 'www'
    $Script:CacheDir     = Join-Path $Script:Root 'cache'
    $Script:LogsDir      = Join-Path $Script:Root 'logs'
    $Script:ProvDir      = Join-Path $Script:Root '_provisioning'
    $Script:DownloadDir  = Join-Path $Script:ProvDir 'downloads'
    $Script:LogFile      = Join-Path $Script:ProvDir 'provision.log'
    $Script:StateFile    = Join-Path $Script:ProvDir 'install-state.json'
    $Script:CredFile     = Join-Path $Script:ProvDir 'credentials.generated.txt'
    if (-not $Script:BackupPathSetExplicitly) { $Script:BackupPath = Join-Path $Script:ProvDir 'backups' }
}
$Script:BackupPathSetExplicitly = [bool]$BackupPath
Set-Layout

$Script:ApacheServiceName = 'MediaWikiApache'
$Script:MysqlServiceName  = 'MediaWikiMySQL'
$Script:DbName            = 'mediawiki'
$Script:DbUser            = 'mediawiki'
$Script:MarkerBegin       = '# === provision-mediawiki.ps1 managed block: BEGIN (do not edit by hand) ==='
$Script:MarkerEnd         = '# === provision-mediawiki.ps1 managed block: END ==='
# Every scheduled task this script creates lives under this one Task Scheduler folder.
$Script:TaskFolder        = '\MediaWikiStack\'
$Script:SelfPath          = $PSCommandPath

# Curated development/documentation extension set. Names here must match the extension
# directory and wfLoadExtension() name; SyntaxHighlight is the upstream SyntaxHighlight_GeSHi repo.
$Script:ZipExtensions = @(
    'VisualEditor', 'WikiEditor', 'CodeMirror', 'TemplateData', 'TemplateStyles',
    'ParserFunctions', 'Cite', 'CategoryTree', 'RevisionSlider', 'Echo',
    'DiscussionTools', 'Linter', 'Scribunto', 'UploadWizard',
    'Popups', 'PageImages', 'TextExtracts', 'MultimediaViewer',
    'SyntaxHighlight_GeSHi', 'Math', 'PdfHandler', 'PageForms'
)

# Skins are git submodules in core's own repo too (see the empty-placeholder-dir cleanup in
# Get-MediaWikiCore) - MediaWiki ships with none installed, so at least one must be fetched
# separately or $wgDefaultSkin has nothing to render against ("Whoops! ... no installed skins").
$Script:ZipSkins = @('Vector')

# ---------------------------------------------------------------------------
# Modules - one file per STEP group (see .NOTES above), dot-sourced into this script's own
# scope so their functions and $Script:-scoped variables are shared with each other and with
# the orchestration/dispatch below. Order matters only in that common.ps1 (logging/state/
# download helpers) must load first - everything else is independent until Invoke-Up runs.
# ---------------------------------------------------------------------------
$Script:LibDir = Join-Path $PSScriptRoot 'lib'
foreach ($module in @('common', 'wizard', 'sso', 'scheduledtasks', 'apache', 'php', 'mysql', 'python', 'mediawiki', 'orchestration')) {
    . (Join-Path $Script:LibDir "$module.ps1")
}

switch ($Action) {
    'Up'      { Invoke-Up }
    'Down'    { Invoke-Down }
    'Status'  { Invoke-Status }
    'Restart' { $KeepData = $true; Invoke-Down; Invoke-Up }
    'Backup'  { Invoke-Backup }
}
