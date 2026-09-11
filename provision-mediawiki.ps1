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
    [string]$MailRelay = $null,
    [ValidateRange(1, 65535)][int]$MailPort = 587,
    [string]$MailUsername = $null,
    [securestring]$MailPassword = $null,
    [string]$MailFrom = $null,
    [string]$MailPasswordText = $null,
    [string[]]$BackupAlertRecipients = @(),
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
    [string]$GhostscriptUrl = 'https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10071/gs10071w64.exe',
    [string]$ImageMagickUrl = 'https://download.imagemagick.org/archive/binaries/ImageMagick-7.1.2-31-Q16-x64-static.exe',
    [string]$ImageMagickZipUrl = $null,
    [string]$PdfMetadataToolsZipUrl = 'https://dl.xpdfreader.com/xpdf-tools-win-4.06.zip',
    [string]$PopplerZipUrl = $null,
    [hashtable]$DownloadChecksums = @{},
    [switch]$AllowUnverifiedDownloads,

    # Corporate proxy for every download this script makes (Apache/PHP/MySQL/Python zips, GitHub
    # extension/skin archives, composer.phar, the CA bundle). Omit for direct internet access.
    [string]$ProxyUrl = $null,
    [switch]$ProxyUseDefaultCredentials,
    [pscredential]$ProxyCredential = $null,

    [switch]$Force,

    [switch]$SeedDevelopmentContent,
    [switch]$InstallPdfTools,

    [ValidateSet('Dev', 'Prod')]
    [string]$Environment = 'Dev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Built-in hashes pin the default artifact set. Override a value in DownloadChecksums when
# deliberately changing a URL/version; -AllowUnverifiedDownloads is an explicit escape hatch.
$builtInDownloadChecksums = @{
    'gs10071w64.exe' = '3A4C28D0AAC47AA7CCCD35A5932C55110376E9DBD966898DDE388B7FABA444A4'
    'httpd-2.4.66-251206-Win64-VS17.zip' = '2CD1F349B6705E43E784E876A233EEB1A859FA6B8ABC693A91F87B35A368F7F9'
    'ImageMagick-7.1.2-31-Q16-x64-static.exe' = '765EEB01E4DEF9AB7DFB8E3989141A6A3FAE578B34309CC72969768CB0D2E917'
    'mediawiki-REL1_43.zip' = '3C644E936C4128CC8DE868F85964D63793B173D7D13F9CE5BF6F35CBCB420AA3'
    'mediawiki-skins-Vector-REL1_43.zip' = '67D5DFC2AD7BE335685E8D1F664859C21F17D35A869B693FCF84D56B981F3057'
    'Mermaid-6.0.2.zip' = '334437EE9ECD29B05A910584C056989FEFCC0598EFBCE5768BC78B491DEC0C86'
    'mod_fcgid-2.3.10-win64-VS17.zip' = 'CF3DED8953863C68FC522EE48F516565E67E18B180B9E5B147668C04FA5DC46D'
    'mysql-8.4.11-winx64.zip' = 'A492371D687D2BAB088B0062581144A0044B8964BAEFDF4FAA579292B423D25C'
    'php_apcu-5.1.28-8.3-nts-vs16-x64.zip' = '1FF653F7A7375F3EBD04D33F5DA611AAD602C80728B00C1A52143BFEC815FA17'
    'php-8.3.33-nts-Win32-vs16-x64.zip' = '534399107056313246F424ADBBB7937337E40FBBF6AA7BC26287BA9CFD2E4A2A'
    'python-3.14.7-embed-amd64.zip' = 'D297E5FF019966817AD8502465176139F2D3D840FA4ED84B13BED399A6AB1F15'
    'SemanticBreadcrumbLinks-3.0.1.zip' = 'E4B5CDD3FCE8EBF2DE3439BC5B774159774AE4B482DD5C84A7EA2137CED2047B'
    'SemanticResultFormats-5.2.0.zip' = 'AD6E0CCA6108FE1594399CA83B8C2B085C062DC45075D1FE777A494583668AA5'
    'xpdf-tools-win-4.06.zip' = '2B6CA45DA794E7854A6468FD6C8063FDE62701F001CE03FA4F603EAB7E15A0B6'
    'composer.phar' = 'C363EE6FF8280297F8FE6586678568FCA5226D70032383F4E0F6D03B39531EB9'
    'cacert.pem' = 'F66DFF1BDF8F96060B8177976F8B7D9254BC89BC4DB933D769F7384D28480BC9'
    'mediawiki-extensions-CategoryTree-REL1_43.zip' = '64330D60678374266C379F37CACEC499990974830FE5F737A26F6113F433A84C'
    'mediawiki-extensions-Cite-REL1_43.zip' = '48D4B3DFE8D14D775C187FE148D58AC672F00B63537C9D10A7DCBA6A10C4B5E9'
    'mediawiki-extensions-CodeMirror-REL1_43.zip' = 'E6AE7D6B2BEF7960C4EEACE097054D9A2D1A378C9B578FAE4798C4733A127CDA'
    'mediawiki-extensions-DiscussionTools-REL1_43.zip' = '4468065A2335F5E54C3B4AB9079247BECFCC99C099CB1A1CB5D2BB8F80D09FD3'
    'mediawiki-extensions-Echo-REL1_43.zip' = '9653AD05FC1F0BAE244416A74F7B67814C51F9C1A06E9D33CA474151A22DA424'
    'mediawiki-extensions-Linter-REL1_43.zip' = '73918D5E5A4221423353F17AA9268C7687A354332E4EBFB083DC76FE1A348692'
    'mediawiki-extensions-Math-REL1_43.zip' = 'A7593EA6CF825FF8A6C94C69E066E90560B91802E34E5A3867A9BDE4D08E69BC'
    'mediawiki-extensions-MultimediaViewer-REL1_43.zip' = '8323D2EBD0615C774A3E4417025277266C619BFEA3557B4AA5CFB3BDF34F1036'
    'mediawiki-extensions-PageForms-REL1_43.zip' = '7242927E46345A0463792D8BC2E1CF3AB9DB8E039ED11BEE0F5B3D2D1A3B16EF'
    'mediawiki-extensions-PageImages-REL1_43.zip' = '16934EE4BFB9198C29EE4EFB7E5F09C2E2E096461EF946824CFFAB1638948BFC'
    'mediawiki-extensions-ParserFunctions-REL1_43.zip' = '6D7784FDD2DF9AB25FAD45EFC24E899FCBF22DC90620D8ACFA1B883E72D67A75'
    'mediawiki-extensions-PdfHandler-REL1_43.zip' = '27394CF5F5EC1F132D3D563E2E961082C3DCB5B9B6F0B95D1D0D3C7B845F1BA0'
    'mediawiki-extensions-Popups-REL1_43.zip' = '4596C114FA9A82AA6066F93D7FB81E45E47409C70E4F743AE28BC265F200F201'
    'mediawiki-extensions-RevisionSlider-REL1_43.zip' = '2550ED202A4FFBA15BFEF2E4FBB57CAD3474FDBEEEBB841CCB12C9CF59102648'
    'mediawiki-extensions-Scribunto-REL1_43.zip' = '6E41856DDBE0E97A8B1100F5407A258380F84557A0CF0137A11B3340CB3C5ADA'
    'mediawiki-extensions-SyntaxHighlight_GeSHi-REL1_43.zip' = '2CE0C4091D1E6088618FE534C73F37AED99335B62340C6B19A3B9E6D71B98665'
    'mediawiki-extensions-TemplateData-REL1_43.zip' = 'A14F7CC94BC6FBE3A0935D2FAB3742660893F76965A1B8777561C23710D84429'
    'mediawiki-extensions-TemplateStyles-REL1_43.zip' = '47ADAD516F5412749202211072DC88419E4C213F2DDF53E6C4E4D68892FDDD90'
    'mediawiki-extensions-TextExtracts-REL1_43.zip' = '364D8318DA2D95464C6A82B4C8C4441D4E204CC017445C381275F509B95F182A'
    'mediawiki-extensions-UploadWizard-REL1_43.zip' = '91F7A495473318D2F1C752E0AC4C5680EF59E609FE789ED6D453C0872B0E28A4'
    'mediawiki-extensions-VisualEditor-REL1_43.zip' = 'BF8E088D2552BDE3DE967CC51ECE0EB56B7DEEABD4E2D094E1E7EA3AFEFEEE67'
    'mediawiki-extensions-WikiEditor-REL1_43.zip' = 'A80C74864FD005E894A056FABFBDE3C0B55B4D38F7EF1B6BC256AFB6E73AFA08'
    'mediawiki-extensions-OOJSPlus-REL1_43.zip' = '17565030952B3B482F2C92202377A9BED3E775961274459EB82992BF295075B0'
    'mediawiki-extensions-BlueSpiceFoundation-REL1_43.zip' = 'DF367E1FAF85983C1D04B8DA8D78C69BAB175590633DA1992BB11CA841645469'
    'mediawiki-extensions-BlueSpiceNamespaceManager-REL1_43.zip' = '3BDBC5FE4AB16B8732817F9B317ED8EF16A444F3B067D0EE55AD93EB9C8C9A1D'
}
foreach ($name in $builtInDownloadChecksums.Keys) { if (-not $DownloadChecksums.ContainsKey($name)) { $DownloadChecksums[$name] = $builtInDownloadChecksums[$name] } }

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
        } elseif ($key -in @('EntraClientSecret', 'MailPassword') -and $value -is [string] -and $value) {
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
if ($MailPasswordText -and -not $MailPassword) { $MailPassword = ConvertTo-SecureString $MailPasswordText -AsPlainText -Force }

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
    $Script:PdfToolsDir  = Join-Path $Script:Root 'pdf-tools'
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
    'OOJSPlus', 'BlueSpiceFoundation', 'BlueSpiceNamespaceManager',
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
foreach ($module in @('common', 'wizard', 'sso', 'scheduledtasks', 'apache', 'php', 'mysql', 'python', 'pdf', 'mediawiki', 'orchestration')) {
    . (Join-Path $Script:LibDir "$module.ps1")
}

function Assert-ProvisionConfig {
    if ($HttpPort -eq $DbPort) { throw 'HttpPort and DbPort must be different.' }
    if (($MailUsername -or $MailPassword) -and -not $MailRelay) { throw 'MailRelay is required when SMTP credentials are configured.' }
    if ($MailRelay -and $MailUsername -and -not $MailPassword) { throw 'MailPassword is required when MailUsername is configured.' }
    if ($MailPassword -and -not $MailUsername) { throw 'MailUsername is required when MailPassword is configured.' }
    foreach ($recipient in @($BackupAlertRecipients | ForEach-Object { $_ -split '[,;]' } | ForEach-Object Trim | Where-Object { $_ })) {
        if ($recipient -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw "Invalid BackupAlertRecipients address: $recipient" }
    }
    if ($DownloadChecksums) {
        foreach ($key in $DownloadChecksums.Keys) {
            if ([string]$DownloadChecksums[$key] -notmatch '^[0-9A-Fa-f]{64}$') { throw "DownloadChecksums[$key] must be a 64-character SHA-256 hex value." }
        }
    }
}

Assert-ProvisionConfig

switch ($Action) {
    'Up'      { Invoke-Up }
    'Down'    { Invoke-Down }
    'Status'  { Invoke-Status }
    'Restart' { $KeepData = $true; Invoke-Down; Invoke-Up }
    'Backup'  { Invoke-Backup }
}
