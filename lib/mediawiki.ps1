# STEP 6-10: MediaWiki core, extensions/skins, SemanticMediaWiki, the web installer, uploads/caching settings, and update.php.

# ---------------------------------------------------------------------------
# STEP 6: MediaWiki core (GitHub zip archive - no git dependency) + Composer
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

# STEP 7: curated extensions + skin(s) - both are plain GitHub zip archives fetched the same
# way, differing only in subfolder/repo-prefix/marker-file, so one function handles both. Skins
# need this same treatment as extensions: see the empty-placeholder-dir note in Get-MediaWikiCore
# for why core's own bundled skins/ folder isn't already real code.
function Install-ZipComponents {
    param([string[]]$Names, [string]$SubDir, [string]$RepoPrefix, [string]$MarkerFile)
    foreach ($name in $Names) {
        $dir = Join-Path $Script:WwwDir "$SubDir\$name"
        if (Test-Path (Join-Path $dir $MarkerFile)) { Write-Note "$name already present, skipping."; continue }
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        Write-Note "Downloading $name ($MwBranch)..."
        try {
            Get-GitHubZip -Owner 'wikimedia' -Repo "$RepoPrefix$name" -Branch $MwBranch -TargetDir $dir
        } catch {
            Write-Warn "could not download $name for branch $MwBranch - skipping. ($($_.Exception.Message))"
            continue
        }
        if (Test-Path (Join-Path $dir 'composer.json')) {
            Invoke-Composer -ComposerArgs @('install', '--no-dev') -WorkingDir $dir
        }
    }
}

# STEP 7c: SemanticMediaWiki - Composer-only install (upstream's own recommended method, not a
# plain GitHub zip like the other extensions above).
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

# Newer MediaWiki versions dispatch maintenance scripts through maintenance\run.php <name>;
# older ones ran e.g. maintenance\update.php directly - shared by both the installer and update.php.
function Invoke-MaintenanceScript {
    param([string]$LegacyName, [string[]]$ModernArgs, [string[]]$ExtraArgs, [string]$FailureMessage, [switch]$LogOutput)
    $phpExe = Join-Path $Script:PhpDir 'php.exe'
    Push-Location $Script:WwwDir
    try {
        # The outer @(...) is load-bearing: without it, PowerShell silently unwraps a single-
        # element array (the legacy branch, one arg) to a bare string when it flows out of an
        # if/else used as an expression - splatting a string then splits it into characters.
        $runner = @(if (Test-Path 'maintenance\run.php') { @('maintenance\run.php') + $ModernArgs } else { "maintenance\$LegacyName" })
        if ($LogOutput) {
            & $phpExe @runner @ExtraArgs 2>&1 | Tee-Object -Variable out | Out-Null
            Add-Content $Script:LogFile $out
        } else {
            & $phpExe @runner @ExtraArgs
            if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
        }
    } finally { Pop-Location }
}

# STEP 8: MediaWiki's own web/CLI installer - creates LocalSettings.php and the database schema.
function Install-MediaWikiDatabase {
    if (Test-Path (Join-Path $Script:WwwDir 'LocalSettings.php')) { Write-Note 'LocalSettings.php already exists - skipping web installer.'; return }
    Write-Step 'Running MediaWiki installer...'
    $serverUrl = if ($Script:UseHttps) { $PublicUrl } else { "http://localhost:$HttpPort" }
    Invoke-MaintenanceScript -LegacyName 'install.php' -ModernArgs @('install') -ExtraArgs @(
        "--dbname=$($Script:DbName)", "--dbserver=${DbHost}:$DbPort",
        "--dbuser=$($Script:DbUser)", "--dbpass=$Script:DbUserPassword",
        "--server=$serverUrl", '--scriptpath=', '--lang=en',
        "--pass=$Script:WikiAdminPassword", $SiteName, $WikiAdminUser
    ) -FailureMessage 'MediaWiki installer failed - see output above.'
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

# STEP 9: file-upload directories/permissions, then caching/perf settings + the wfLoadSkin/
# wfLoadExtension block, written into LocalSettings.php's managed block (see Add-ManagedSettingsBlock).
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

    # Logo (optional): copied into www/resources/assets so it's served the same way as core's
    # own bundled assets, referenced via $wgResourceBasePath so it survives $wgScriptPath changes.
    $logoLine = ''
    if ($LogoPath -and (Test-Path $LogoPath)) {
        $assetsDir = Join-Path $Script:WwwDir 'resources\assets'
        New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
        $logoFile = "wiki-logo$([IO.Path]::GetExtension($LogoPath))"
        Copy-Item $LogoPath (Join-Path $assetsDir $logoFile) -Force
        $logoLine = "`$wgLogos = [ '1x' => `"`$wgResourceBasePath/resources/assets/$logoFile`" ];"
    }

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
`$wgServer            = '$(if ($Script:UseHttps) { $PublicUrl } else { "http://localhost:$HttpPort" })';
$debugLine
$logoLine

// --- File uploads (images dir created + permissioned by the provisioning script) ---
`$wgEnableUploads     = true;
`$wgUseImageMagick    = false; // GD (already enabled in php.ini) handles thumbnailing - no extra binary needed
`$wgUploadDirectory   = "`$IP/images";
`$wgUploadPath        = "`$wgScriptPath/images";
`$wgFileExtensions    = array_merge( `$wgFileExtensions, [ 'png', 'jpg', 'jpeg', 'gif', 'svg', 'pdf', 'webp' ] );
`$wgMaxUploadSize      = 64 * 1024 * 1024; // matches php.ini upload_max_filesize/post_max_size

// --- Skins ---
"@
    foreach ($skin in $Script:ZipSkins) {
        if (Test-Path (Join-Path $Script:WwwDir "skins\$skin")) { $block += "`nwfLoadSkin( '$skin' );" }
    }
    $block += "`n`n// --- Extensions (curated `"vanilla plus`" set) ---"
    foreach ($ext in $Script:ZipExtensions) {
        if (Test-Path (Join-Path $Script:WwwDir "extensions\$ext")) { $block += "`nwfLoadExtension( '$ext' );" }
    }
    if (Test-Path (Join-Path $Script:WwwDir 'extensions\SemanticMediaWiki')) {
        # enableSemantics() alone is deprecated in modern SMW - it now requires the explicit
        # wfLoadExtension call first (see extensions/SemanticMediaWiki/docs/INSTALL.md).
        $block += "`nwfLoadExtension( 'SemanticMediaWiki' );`nenableSemantics( 'localhost:$HttpPort' );"
    }
    $syntaxHighlightDir = Join-Path $Script:WwwDir 'extensions\SyntaxHighlight_GeSHi'
    $pythonExe = Join-Path $Script:PythonDir 'python.exe'
    if ((Test-Path $syntaxHighlightDir) -and (Test-Path $pythonExe)) {
        # SyntaxHighlight's bundled `pygmentize` is a self-contained Python zipapp (shebang
        # #!/usr/bin/env python3) - Windows can't execute that directly, so point $wgPygmentizePath
        # at a small .bat wrapper that runs it through our own embedded python.exe instead.
        $wrapperPath = Join-Path $Script:PythonDir 'pygmentize.bat'
        $pygmentizePath = Join-Path $syntaxHighlightDir 'pygments\pygmentize'
        "@echo off`r`n`"$pythonExe`" `"$pygmentizePath`" %*" | Set-Content -Path $wrapperPath -Encoding ASCII
        $block += "`n`$wgPygmentizePath = '$wrapperPath';"
    }

    $sso = Get-SsoConfig
    if ($sso.Enabled) {
        # Local admin login stays available (EnableLocalLogin) so a misconfigured tenant can't
        # lock everyone out. Entra-side setup: register an App Registration with redirect URI
        # <PublicUrl or http://localhost:HttpPort>/index.php/Special:PluggableAuthLogin, a client
        # secret under Certificates & secrets, and the default openid/profile/email delegated
        # permissions (granted by default) - see docs comment at the top of lib/sso.ps1.
        $block += @"

wfLoadExtension( 'PluggableAuth' );
wfLoadExtension( 'OpenIDConnect' );
// Named (not numeric-push) key - PluggableAuth uses this key as the login button's label, so
// a plain `$wgPluggableAuth_Config[] = ...` renders a button literally labeled "0".
`$wgPluggableAuth_Config['Entra ID'] = [
    'plugin' => 'OpenIDConnect',
    'data' => [
        'providerURL'  => 'https://login.microsoftonline.com/$($sso.TenantId)/v2.0',
        'clientID'     => '$($sso.ClientId)',
        'clientsecret' => '$($sso.ClientSecret)',
    ]
];
`$wgPluggableAuth_EnableLocalLogin = true;
"@
    }

    $block += "`n$($Script:MarkerEnd)"
    Add-ManagedSettingsBlock -Block $block
}

# STEP 10: update.php (applies core + every installed extension's schema changes) - the last
# step before the credentials file is written and Invoke-Up reports the wiki as ready.
function Complete-Installation {
    Write-Step 'Running update.php (schema for core + all extensions)...'
    Invoke-MaintenanceScript -LegacyName 'update.php' -ModernArgs @('update') -ExtraArgs @('--quick') -LogOutput
}

