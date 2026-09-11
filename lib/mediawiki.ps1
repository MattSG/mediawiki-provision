# STEP 6-10: MediaWiki core, extensions/skins, SemanticMediaWiki, the web installer, uploads/caching settings, and update.php.

# ---------------------------------------------------------------------------
# STEP 6: MediaWiki core (GitHub zip archive - no git dependency) + Composer
# ---------------------------------------------------------------------------
function Get-GitHubZip {
    param([string]$Owner, [string]$Repo, [string]$Branch, [string]$TargetDir, [ValidateSet('heads', 'tags')][string]$RefType = 'heads')
    $zip = Join-Path $Script:DownloadDir "$Repo-$Branch.zip"
    $url = "https://github.com/$Owner/$Repo/archive/refs/$RefType/$Branch.zip"
    Get-RemoteFile -Url $url -Destination $zip -VendorPageOnFailure "https://github.com/$Owner/$Repo/branches"
    Expand-ToDir -ZipPath $zip -TargetDir $TargetDir
}

function Get-ComposerPhar {
    $pharPath = Join-Path $Script:ProvDir 'composer.phar'
    if (Test-Path $pharPath) { return $pharPath }
    Write-Step 'Downloading composer.phar...'
    Get-RemoteFile -Url $ComposerPharUrl -Destination $pharPath -VendorPageOnFailure 'https://getcomposer.org/download/'
    return $pharPath
}

function Invoke-Composer {
    param([string[]]$ComposerArgs, [string]$WorkingDir)
    $phpExe = Join-Path $Script:PhpDir 'php.exe'
    $phar = Get-ComposerPhar
    Push-Location $WorkingDir
    try {
        & $phpExe $phar @ComposerArgs --no-interaction 2>&1 | Tee-Object -Variable out | Out-Null
        $exitCode = $LASTEXITCODE
        Add-Content $Script:LogFile $out
        if ($exitCode -ne 0) { throw "Composer failed with exit code $exitCode in $WorkingDir. See provision.log." }
    }
    finally { Pop-Location }
}

function Test-ComposerInstallRequired {
    param([string]$Dir)
    $composerPath = Join-Path $Dir 'composer.json'
    if (-not (Test-Path $composerPath)) { return $false }
    $composer = Get-Content $composerPath -Raw | ConvertFrom-Json
    $require = $composer.PSObject.Properties['require']
    if ($null -eq $require) { return $false }
    $packages = @($require.Value.PSObject.Properties.Name | Where-Object { $_ -notmatch '^(?:php$|ext-|lib-|composer-(?:plugin|runtime)-api$|composer/installers$)' })
    return $packages.Count -gt 0
}

function Test-ZipComponentReady {
    param([string]$Dir, [string]$MarkerFile, [string]$ExpectedVersion = $null)
    if (-not (Test-Path (Join-Path $Dir $MarkerFile))) { return $false }
    if ($ExpectedVersion) {
        $versionMarker = Join-Path $Dir '.provision-version'
        if (-not (Test-Path $versionMarker) -or (Get-Content $versionMarker -Raw).Trim() -ne $ExpectedVersion) { return $false }
    }
    if (-not (Test-ComposerInstallRequired -Dir $Dir)) { return $true }
    if (-not (Test-Path (Join-Path $Dir '.composer-installed'))) {
        return Test-Path (Join-Path $Dir 'vendor\autoload.php') # Accept installs made before the success marker existed.
    }
    $lockPath = Join-Path $Dir 'composer.lock'
    if (Test-Path $lockPath) {
        try { $lock = Get-Content $lockPath -Raw | ConvertFrom-Json } catch { return $false }
        if (@($lock.packages).Count -gt 0 -and -not (Test-Path (Join-Path $Dir 'vendor\autoload.php'))) { return $false }
    }
    return $true
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
        if (Test-ZipComponentReady -Dir $dir -MarkerFile $MarkerFile) { Write-Note "$name already present, skipping."; continue }
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        Write-Note "Downloading $name ($MwBranch)..."
        try {
            Get-GitHubZip -Owner 'wikimedia' -Repo "$RepoPrefix$name" -Branch $MwBranch -TargetDir $dir
        } catch {
            throw "Could not download required component '$name' for branch '$MwBranch': $($_.Exception.Message)"
        }
        if (Test-ComposerInstallRequired -Dir $dir) {
            Invoke-Composer -ComposerArgs @('install', '--no-dev') -WorkingDir $dir
            New-Item -ItemType File -Path (Join-Path $dir '.composer-installed') -Force | Out-Null
        }
    }
}

# STEP 7c: SemanticMediaWiki - Composer-only install (upstream's own recommended method, not a
# plain GitHub zip like the other extensions above).
function Install-SemanticMediaWiki {
    $smwDir = Join-Path $Script:WwwDir 'extensions\SemanticMediaWiki'
    $smwMarker = Join-Path $smwDir '.composer-installed'
    $smwVersion = '7.2.1'
    if ((Test-Path (Join-Path $smwDir 'extension.json')) -and (Test-Path $smwMarker) -and
        (Test-Path (Join-Path $smwDir '.provision-version')) -and
        (Get-Content (Join-Path $smwDir '.provision-version') -Raw).Trim() -eq $smwVersion) {
        Write-Note 'SemanticMediaWiki already present, skipping.'
        return
    }
    Write-Step 'Installing SemanticMediaWiki via Composer (upstream-recommended method)...'
    $composerLocal = Join-Path $Script:WwwDir 'composer.local.json'
    $composerConfig = if (Test-Path $composerLocal) { Get-Content $composerLocal -Raw | ConvertFrom-Json } else { [pscustomobject]@{ require = [pscustomobject]@{} } }
    if (-not $composerConfig.require) { $composerConfig | Add-Member -NotePropertyName require -NotePropertyValue ([pscustomobject]@{}) }
    $composerConfig.require | Add-Member -Force -NotePropertyName 'mediawiki/semantic-media-wiki' -NotePropertyValue $smwVersion
    foreach ($package in @('mediawiki/semantic-result-formats', 'mediawiki/semantic-breadcrumb-links')) {
        $composerConfig.require.PSObject.Properties.Remove($package)
    }
    $composerConfig | ConvertTo-Json -Depth 5 | Set-Content $composerLocal
    Invoke-Composer -ComposerArgs @('update', 'mediawiki/semantic-media-wiki', '--no-dev') -WorkingDir $Script:WwwDir
    if (-not (Test-Path (Join-Path $smwDir 'extension.json'))) { throw 'SemanticMediaWiki did not install via Composer - check provision.log.' }
    New-Item -ItemType File -Path $smwMarker -Force | Out-Null
    Set-Content -Path (Join-Path $smwDir '.provision-version') -Value $smwVersion
}

function Install-SemanticGithubComponents {
    foreach ($component in @(
        @{ Name = 'SemanticResultFormats'; Repo = 'SemanticResultFormats'; Tag = '5.2.0' },
        @{ Name = 'SemanticBreadcrumbLinks'; Repo = 'SemanticBreadcrumbLinks'; Tag = '3.0.1' }
    )) {
        $dir = Join-Path $Script:WwwDir "extensions\$($component.Name)"
        if (Test-ZipComponentReady -Dir $dir -MarkerFile 'extension.json' -ExpectedVersion $component.Tag) { Write-Note "$($component.Name) already present, skipping."; continue }
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        Get-GitHubZip -Owner 'SemanticMediaWiki' -Repo $component.Repo -Branch $component.Tag -RefType 'tags' -TargetDir $dir
        if (Test-ComposerInstallRequired -Dir $dir) {
            Invoke-Composer -ComposerArgs @('install', '--no-dev', '--no-security-blocking') -WorkingDir $dir
            New-Item -ItemType File -Path (Join-Path $dir '.composer-installed') -Force | Out-Null
        }
        Set-Content -Path (Join-Path $dir '.provision-version') -Value $component.Tag
    }
}

function Install-Mermaid {
    $dir = Join-Path $Script:WwwDir 'extensions\Mermaid'
    $mermaidVersion = '6.0.2'
    if (Test-ZipComponentReady -Dir $dir -MarkerFile 'extension.json' -ExpectedVersion $mermaidVersion) { Write-Note 'Mermaid already present, skipping.'; return }
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Get-GitHubZip -Owner 'SemanticMediaWiki' -Repo 'Mermaid' -Branch $mermaidVersion -RefType 'tags' -TargetDir $dir
    if (Test-ComposerInstallRequired -Dir $dir) {
        Invoke-Composer -ComposerArgs @('install', '--no-dev', '--no-security-blocking') -WorkingDir $dir
        New-Item -ItemType File -Path (Join-Path $dir '.composer-installed') -Force | Out-Null
    }
    Set-Content -Path (Join-Path $dir '.provision-version') -Value $mermaidVersion
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
            $exitCode = $LASTEXITCODE
            Add-Content $Script:LogFile $out
        } else {
            & $phpExe @runner @ExtraArgs
            $exitCode = $LASTEXITCODE
        }
        if ($exitCode -ne 0) { throw $FailureMessage }
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

function Normalize-ManagedLocalSettings {
    $path = Join-Path $Script:WwwDir 'LocalSettings.php'
    $content = Get-Content $path -Raw
    $marker = [regex]::Escape($Script:MarkerBegin)
    $match = [regex]::Match($content, "(?s)\A(.*?)$marker")
    if (-not $match.Success) { return }

    # Remove only directives owned by this script. Keep installer output and unrelated admin settings.
    $prefix = $match.Groups[1].Value
    $ownedKeys = @(
        'wgMainCacheType', 'wgSessionCacheType', 'wgMessageCacheType', 'wgParserCacheType',
        'wgCacheDirectory', 'wgUseFileCache', 'wgFileCacheDirectory', 'wgUseGzip',
        'wgResourceLoaderMaxage', 'wgResourceLoaderStorageEnabled', 'wgJobRunRate', 'wgUseCdn',
        'wgEnableAPI', 'wgEnableWriteAPI', 'wgDefaultSkin', 'wgServer', 'wgAllowUserCss',
        'wgAllowUserJs', 'wgShowExceptionDetails', 'wgShowSQLErrors', 'wgShowDBErrorBacktrace',
        'wgDevelopmentWarnings', 'wgEnableUploads', 'wgUseImageMagick', 'wgUploadDirectory',
        'wgUploadPath', 'wgFileExtensions', 'wgMaxUploadSize', 'wgMaxShellMemory',
        'wgMaxShellFileSize', 'wgMaxShellTime', 'wgMaxShellWallClockTime', 'wgPygmentizePath'
    )
    foreach ($key in $ownedKeys) {
        $keyPattern = [regex]::Escape($key)
        $directivePattern = '(?m)^\s*\$' + $keyPattern + '\s*=.*(?:\r?\n|$)'
        $prefix = [regex]::Replace($prefix, $directivePattern, '')
    }
    foreach ($skin in $Script:ZipSkins) {
        $skinPattern = [regex]::Escape($skin)
        $prefix = [regex]::Replace($prefix, "(?mi)^\s*wfLoadSkin\(\s*'$skinPattern'\s*\);\s*(?:\r?\n|$)", '')
    }
    $prefix = [regex]::Replace($prefix, '(?:\r?\n){3,}', "`r`n`r`n")
    Set-Content -Path $path -Value ($prefix + $content.Substring($match.Groups[1].Length)) -Encoding UTF8
}

function ConvertTo-PhpPath {
    param([string]$Path)
    return ($Path -replace '\\', '/')
}

function ConvertTo-PhpString {
    param([AllowEmptyString()][string]$Value)
    return ($Value -replace '\\', '\\\\' -replace "'", "\\'")
}

function Test-LocalSettingsSyntax {
    $phpExe = Join-Path $Script:PhpDir 'php.exe'
    $settings = Join-Path $Script:WwwDir 'LocalSettings.php'
    & $phpExe -l $settings 2>&1 | Tee-Object -Variable output | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Add-Content $Script:LogFile $output
        throw "Generated LocalSettings.php failed PHP syntax validation. See $Script:LogFile."
    }
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
    $cachePath = ConvertTo-PhpPath $Script:CacheDir

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
// APCu is process-local under Apache/FastCGI; sessions must survive worker changes.
`$wgSessionCacheType  = CACHE_DB;
`$wgMessageCacheType  = $cacheType;
// MediaWiki recommends DB-backed parser output when APCu is the main cache.
`$wgParserCacheType   = CACHE_DB;
`$wgCacheDirectory    = '$cachePath';

// --- Anonymous-view file cache: skips PHP entirely for logged-out page views ---
`$wgUseFileCache      = true;
`$wgFileCacheDirectory = '$cachePath';
`$wgUseGzip           = true;

// --- ResourceLoader / static asset caching ---
`$wgResourceLoaderMaxage['versioned']   = 30 * 24 * 3600;
`$wgResourceLoaderMaxage['unversioned'] = 5 * 60;
`$wgResourceLoaderStorageEnabled = true; // client-side localStorage cache of RL modules

// --- Job queue: a scheduled task runs runJobs periodically (see lib/scheduledtasks.ps1) - 0
// here stops random page views from ALSO inline-spawning a job runner and stealing a php-cgi
// worker for it, which just duplicates work and adds latency to whichever user triggers it.
`$wgJobRunRate = 0;

// --- No CDN/reverse-proxy in front of this single-box install - keep this explicit rather than
// left to the (also-false) default, so it's obvious nothing purge-related is half-configured.
`$wgUseCdn = false;

// --- Sane defaults for a modern wiki ---
`$wgEnableAPI         = true;
`$wgEnableWriteAPI    = true;
`$wgDefaultSkin       = 'vector-2022';
`$wgServer            = '$(if ($Script:UseHttps) { $PublicUrl } else { "http://localhost:$HttpPort" })';
`$wgAllowUserCss      = false;
`$wgAllowUserJs       = false;
$debugLine
// wgShowExceptionDetails alone doesn't cover every debug-leak surface in Prod.
`$wgShowSQLErrors        = $(if ($Environment -eq 'Prod') { 'false' } else { 'true' });
`$wgShowDBErrorBacktrace = $(if ($Environment -eq 'Prod') { 'false' } else { 'true' });
`$wgDevelopmentWarnings  = $(if ($Environment -eq 'Prod') { 'false' } else { 'true' });
$logoLine

$(if ($MailRelay) {
    $mailHost = ConvertTo-PhpString $MailRelay
    $mailUser = ConvertTo-PhpString $MailUsername
    $mailPass = if ($MailPassword) { ConvertTo-PhpString (ConvertFrom-SecureString $MailPassword -AsPlainText) } else { '' }
    @"
// --- Outbound email ---
`$wgEnableEmail = true;
`$wgEnableUserEmail = true;
`$wgSMTP = [
    'host' => '$mailHost',
    'port' => $MailPort$(if ($MailUsername) { ",`r`n    'auth' => true,`r`n    'username' => '$mailUser',`r`n    'password' => '$mailPass'" } else { ",`r`n    'auth' => false" })
];
"@
})

// --- File uploads (images dir created + permissioned by the provisioning script) ---
`$wgEnableUploads     = true;
`$wgUseImageMagick    = $(if (Test-Path (Join-Path $Script:WwwDir 'extensions\PdfHandler')) { 'true' } else { 'false' });
`$wgUploadDirectory   = "`$IP/images";
`$wgUploadPath        = "`$wgScriptPath/images";
`$wgFileExtensions    = array_merge( `$wgFileExtensions, [ 'png', 'jpg', 'jpeg', 'gif', 'svg', 'pdf', 'webp' ] );
`$wgMaxUploadSize      = 64 * 1024 * 1024; // matches php.ini upload_max_filesize/post_max_size
// MediaWiki shell limits are KiB (not bytes); these cap PDF helper processes at 512 MiB,
// 64 MiB output, and three minutes of CPU/wall-clock time.
`$wgMaxShellMemory    = 512 * 1024;
`$wgMaxShellFileSize  = 64 * 1024;
`$wgMaxShellTime      = 180;
`$wgMaxShellWallClockTime = 180;

// --- Skins ---
"@
    foreach ($skin in $Script:ZipSkins) {
        if (Test-Path (Join-Path $Script:WwwDir "skins\$skin")) { $block += "`nwfLoadSkin( '$skin' );" }
    }
    $block += "`n`n// --- Extensions (curated `"vanilla plus`" set) ---"
    foreach ($ext in $Script:ZipExtensions) {
        if (Test-Path (Join-Path $Script:WwwDir "extensions\$ext")) { $block += "`nwfLoadExtension( '$ext' );" }
    }
    if (Test-Path (Join-Path $Script:WwwDir 'extensions\Linter')) {
        $block += @"

wfLoadExtension( 'Parsoid', "`$IP/vendor/wikimedia/parsoid/extension.json" );
`$wgParsoidSettings = [ 'useSelser' => true, 'linting' => true ];
`$wgVisualEditorParsoidAutoConfig = false;
"@
    }
    if (Test-Path (Join-Path $Script:WwwDir 'extensions\SemanticMediaWiki')) {
        $block += "`nwfLoadExtension( 'SemanticMediaWiki' );"
        $semanticDomain = if ($Script:UseHttps) { ([Uri]$PublicUrl).Host } else { 'localhost' }
        $block += "`nenableSemantics( '$semanticDomain' );"
    }
    foreach ($ext in @('SemanticResultFormats', 'SemanticBreadcrumbLinks', 'Mermaid')) {
        if ((Test-Path (Join-Path $Script:WwwDir "extensions\$ext")) -and ($block -notmatch "wfLoadExtension\( '$ext' \)")) {
            $block += "`nwfLoadExtension( '$ext' );"
        }
    }
    if (Test-Path (Join-Path $Script:WwwDir 'extensions\PdfHandler')) {
        $pdf = Get-PdfToolPaths
        $pdfTools = @(
            if (-not $pdf.Ghostscript) { 'Ghostscript (gs/gswin64c)' }
            if (-not $pdf.ImageMagick) { 'ImageMagick (magick/convert)' }
            if (-not $pdf.PdfInfo) { 'Poppler pdfinfo' }
            if (-not $pdf.PdfToText) { 'Poppler pdftotext' }
        )
        if ($pdfTools) { throw "PdfHandler requires: $($pdfTools -join ', '). Use -InstallPdfTools or install them on PATH before provisioning." }
        $block += "`n`n// --- PdfHandler executables ---`n`$wgPdfProcessor = '$(ConvertTo-PhpPath $pdf.Ghostscript)';`n`$wgPdfPostProcessor = '$(ConvertTo-PhpPath $pdf.ImageMagick)';`n`$wgPdfInfo = '$(ConvertTo-PhpPath $pdf.PdfInfo)';`n`$wgPdftoText = '$(ConvertTo-PhpPath $pdf.PdfToText)';"
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
        $block += "`n`n// --- SyntaxHighlight ---`n`$wgPygmentizePath = '$(ConvertTo-PhpPath $wrapperPath)';"
    }

    $sso = Get-SsoConfig
    if ($sso.Enabled) {
        # Local admin login stays available (EnableLocalLogin) so a misconfigured tenant can't
        # lock everyone out. Entra-side setup: register an App Registration with redirect URI
        # <PublicUrl or http://localhost:HttpPort>/index.php/Special:PluggableAuthLogin, a client
        # secret under Certificates & secrets, and the default openid/profile/email delegated
        # permissions (granted by default) - see docs comment at the top of lib/sso.ps1.
        $block += @"

// --- Entra ID SSO ---
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
    $hasDevelopmentNamespaces = $SeedDevelopmentContent -or
        (Test-Path (Join-Path $Script:ProvDir 'development-content.seeded')) -or
        (Test-Path (Join-Path $Script:ProvDir 'namespace-homes.seeded'))
    if ($hasDevelopmentNamespaces) {
        $block = $block -replace [regex]::Escape($Script:MarkerEnd), @"

// --- Local development content ---
`$wgExtraNamespaces[100] = 'Development';
`$wgExtraNamespaces[101] = 'Development_talk';
`$wgExtraNamespaces[102] = 'HR';
`$wgExtraNamespaces[103] = 'HR_talk';
`$wgExtraNamespaces[104] = 'Projects';
`$wgExtraNamespaces[105] = 'Projects_talk';
`$wgExtraNamespaces[106] = 'Operations';
`$wgExtraNamespaces[107] = 'Operations_talk';
$($Script:MarkerEnd)
"@
    }
    Add-ManagedSettingsBlock -Block $block
    Normalize-ManagedLocalSettings
    Test-LocalSettingsSyntax
}

# STEP 10: update.php (applies core + every installed extension's schema changes) - the last
# step before the credentials file is written and Invoke-Up reports the wiki as ready.
function Complete-Installation {
    Write-Step 'Running update.php (schema for core + all extensions)...'
    Invoke-MaintenanceScript -LegacyName 'update.php' -ModernArgs @('update') -ExtraArgs @('--quick') -LogOutput
}

function Seed-DevelopmentContent {
    $marker = Join-Path $Script:ProvDir 'development-content.seeded'
    if (Test-Path $marker) {
        Write-Note 'Development namespace/content already seeded.'
        Seed-NamespaceHomePages
        return
    }

    Write-Step 'Seeding Development namespace mock pages...'
    $dump = Join-Path $Script:ProvDir 'development-content.xml'
    $siteNameXml = [System.Security.SecurityElement]::Escape([string]$SiteName)
    $dbNameXml = [System.Security.SecurityElement]::Escape([string]$Script:DbName)
    $adminUserXml = [System.Security.SecurityElement]::Escape([string]$WikiAdminUser)
    @"
<?xml version="1.0" encoding="UTF-8"?>
<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.10/" xml:lang="en" version="0.10">
  <siteinfo><sitename>$siteNameXml</sitename><dbname>$dbNameXml</dbname><base>http://localhost:$HttpPort/</base><generator>provision-mediawiki.ps1</generator><case>first-letter</case><namespaces><namespace key="0" /></namespaces></siteinfo>
  <page><title>Development:Welcome</title><ns>100</ns><id>1001</id><revision><id>10001</id><timestamp>2026-01-01T00:00:00Z</timestamp><contributor><username>$adminUserXml</username></contributor><comment>Seed development content</comment><text xml:space="preserve">Welcome to the Development namespace.

This is disposable mock content for local development and UI testing.</text></revision></page>
  <page><title>Development:Mock API</title><ns>100</ns><id>1002</id><revision><id>10002</id><timestamp>2026-01-01T00:00:00Z</timestamp><contributor><username>$adminUserXml</username></contributor><comment>Seed development content</comment><text xml:space="preserve">== Mock API ==

* GET `/api/mock/health` → `{"status":"ok"}`
* GET `/api/mock/items` → three sample items
* POST `/api/mock/items` → not implemented in this fixture</text></revision></page>
  <page><title>Development:Sample Project</title><ns>100</ns><id>1003</id><revision><id>10003</id><timestamp>2026-01-01T00:00:00Z</timestamp><contributor><username>$adminUserXml</username></contributor><comment>Seed development content</comment><text xml:space="preserve">== Sample project ==

;Status: Prototype
;Owner: Development team
;Next: Replace this page with real project notes.</text></revision></page>
</mediawiki>
"@ | Set-Content -Path $dump -Encoding UTF8
    Invoke-MaintenanceScript -LegacyName 'importDump.php' -ModernArgs @('importDump') -ExtraArgs @($dump) -FailureMessage 'Development content import failed.' -LogOutput
    New-Item -ItemType File -Path $marker -Force | Out-Null
    Seed-NamespaceHomePages
}

function Seed-NamespaceHomePages {
    $marker = Join-Path $Script:ProvDir 'namespace-homes.seeded'
    if (Test-Path $marker) { Write-Note 'Namespace home pages already seeded.'; return }

    Write-Step 'Seeding namespace home pages...'
    $dump = Join-Path $Script:ProvDir 'namespace-homes.xml'
    $siteNameXml = [System.Security.SecurityElement]::Escape([string]$SiteName)
    $dbNameXml = [System.Security.SecurityElement]::Escape([string]$Script:DbName)
    $adminUserXml = [System.Security.SecurityElement]::Escape([string]$WikiAdminUser)
    $seedTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    @"
<?xml version="1.0" encoding="UTF-8"?>
<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.10/" xml:lang="en" version="0.10">
  <siteinfo><sitename>$siteNameXml</sitename><dbname>$dbNameXml</dbname><base>http://localhost:$HttpPort/</base><generator>provision-mediawiki.ps1</generator><case>first-letter</case><namespaces><namespace key="0" /></namespaces></siteinfo>
  <page><title>Main Page</title><ns>0</ns><id>1100</id><revision><id>11000</id><timestamp>$seedTimestamp</timestamp><contributor><username>$adminUserXml</username></contributor><comment>Create namespace home hub</comment><text xml:space="preserve">= Wiki home =

Welcome to $siteNameXml.

== Spaces ==

* [[Development:Main Page|Development]]
* [[HR:Main Page|HR]]
* [[Projects:Main Page|Projects]]
* [[Operations:Main Page|Operations]]

== History test ==

Use the page history to compare this revision with the earlier test revisions.</text></revision></page>
  <page><title>Development:Main Page</title><ns>100</ns><id>1101</id><revision><id>11001</id><timestamp>2026-01-01T00:00:00Z</timestamp><contributor><username>$adminUserXml</username></contributor><comment>Seed namespace home</comment><text xml:space="preserve">== Development ==

Development notes, prototypes, and technical experiments.

* [[Development:Welcome|Welcome]]
* [[Development:Mock API|Mock API]]
* [[Development:Sample Project|Sample Project]]</text></revision></page>
  <page><title>HR:Main Page</title><ns>102</ns><id>1102</id><revision><id>11002</id><timestamp>2026-01-01T00:00:00Z</timestamp><contributor><username>$adminUserXml</username></contributor><comment>Seed namespace home</comment><text xml:space="preserve">== HR ==

People operations, onboarding, policies, and team information.</text></revision></page>
  <page><title>Projects:Main Page</title><ns>104</ns><id>1103</id><revision><id>11003</id><timestamp>2026-01-01T00:00:00Z</timestamp><contributor><username>$adminUserXml</username></contributor><comment>Seed namespace home</comment><text xml:space="preserve">== Projects ==

Project briefs, plans, decisions, and delivery notes.</text></revision></page>
  <page><title>Operations:Main Page</title><ns>106</ns><id>1104</id><revision><id>11004</id><timestamp>2026-01-01T00:00:00Z</timestamp><contributor><username>$adminUserXml</username></contributor><comment>Seed namespace home</comment><text xml:space="preserve">== Operations ==

Runbooks, service notes, recurring procedures, and operational records.</text></revision></page>
</mediawiki>
"@ | Set-Content -Path $dump -Encoding UTF8
    Invoke-MaintenanceScript -LegacyName 'importDump.php' -ModernArgs @('importDump') -ExtraArgs @($dump) -FailureMessage 'Namespace home import failed.' -LogOutput
    New-Item -ItemType File -Path $marker -Force | Out-Null
}
