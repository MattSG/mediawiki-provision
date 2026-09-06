# Interactive setup wizard - only asks for values not already given via parameters, and only
# on a fresh install (LocalSettings.php doesn't exist yet) since these are one-time site-identity
# choices, not something to re-prompt for on every idempotent re-run. -NonInteractive or -Force
# skip it entirely (pass everything you want via parameters in that case).
function Invoke-SetupWizard {
    if ($NonInteractive -or $Force) { return }
    if (Test-Path (Join-Path $Script:WwwDir 'LocalSettings.php')) { return }

    Write-Host "`n=== MediaWiki setup - press Enter to accept the default shown in [brackets] ===" -ForegroundColor Cyan

    if (-not $PSBoundParameters.ContainsKey('ProxyUrl') -and -not $PSBoundParameters.ContainsKey('ApacheZipUrl')) {
        $resp = Read-Host 'Does this server have direct internet access to download everything it needs? [Y/n]'
        if ($resp -match '^[Nn]') {
            $resp = Read-Host 'Use a corporate proxy? [y/N]'
            if ($resp -match '^[Yy]') {
                $Script:ProxyUrl = Read-Host 'Proxy URL (e.g. http://proxy.company.com:8080)'
                if ($Script:ProxyUrl) {
                    $resp = Read-Host 'Use your current Windows credentials for the proxy? [Y/n]'
                    if ($resp -notmatch '^[Nn]') { $Script:ProxyUseDefaultCredentials = $true }
                    else { $Script:ProxyCredential = Get-Credential -Message 'Proxy credentials' }
                }
            }
            $resp = Read-Host 'Do you have local files or a network share pre-staged with the required downloads instead? [y/N]'
            if ($resp -match '^[Yy]') {
                Write-Host 'Enter a local path or UNC share for each (Enter to keep downloading it normally):' -ForegroundColor DarkGray
                foreach ($item in @(
                    @{ Name = 'ApacheZipUrl'; Label = 'Apache httpd zip' }
                    @{ Name = 'ModFcgidZipUrl'; Label = 'mod_fcgid zip' }
                    @{ Name = 'PhpZipUrl'; Label = 'PHP zip' }
                    @{ Name = 'ApcuZipUrl'; Label = 'APCu extension zip' }
                    @{ Name = 'MySqlZipUrl'; Label = 'MySQL zip' }
                    @{ Name = 'PythonZipUrl'; Label = 'Python embeddable zip' }
                    @{ Name = 'ComposerPharUrl'; Label = 'composer.phar' }
                    @{ Name = 'CaBundleUrl'; Label = 'CA certificate bundle' }
                )) {
                    $resp = Read-Host "  $($item.Label)"
                    if ($resp) { Set-Variable -Name $item.Name -Value $resp -Scope Script }
                }
                Write-Host 'Note: MediaWiki core + the ~17 extension/skin zips still come from GitHub and are not' -ForegroundColor DarkGray
                Write-Host 'individually overridable - pre-stage those under _provisioning\downloads\ instead (see README).' -ForegroundColor DarkGray
            }
        }
    }

    if (-not $PSBoundParameters.ContainsKey('InstallRoot')) {
        $resp = Read-Host "Install folder - everything lives under here for easy backup [$InstallRoot]"
        if ($resp) { $Script:InstallRoot = $resp }
    }
    Set-Layout  # so anything below this point (e.g. the HTTPS section's cert directory) uses
                # wherever InstallRoot actually ended up, not the pre-wizard default.
    if (-not $PSBoundParameters.ContainsKey('HttpPort')) {
        $resp = Read-Host "HTTP port [$HttpPort]"
        if ($resp -match '^\d+$') { $Script:HttpPort = [int]$resp }
    }
    if (-not $PSBoundParameters.ContainsKey('UseExternalDb')) {
        $resp = Read-Host 'Use an existing MySQL instance instead of installing one here? [y/N]'
        if ($resp -match '^[Yy]') {
            $Script:UseExternalDb = $true
            $Script:DbHost = Read-Host "Database host [$DbHost]" | ForEach-Object { if ($_) { $_ } else { $DbHost } }
            $resp = Read-Host "Database port [$DbPort]"
            if ($resp -match '^\d+$') { $Script:DbPort = [int]$resp }
            $Script:ExternalDbAdminUser = Read-Host "Admin username on that database [$ExternalDbAdminUser]" | ForEach-Object { if ($_) { $_ } else { $ExternalDbAdminUser } }
            $Script:ExternalDbAdminPassword = Read-Host 'Admin password on that database'
        } else {
            $resp = Read-Host "MySQL port [$DbPort]"
            if ($resp -match '^\d+$') { $Script:DbPort = [int]$resp }
        }
    }
    if (-not $PSBoundParameters.ContainsKey('SiteName')) {
        $resp = Read-Host "Wiki name/title [$SiteName]"
        if ($resp) { $Script:SiteName = $resp }
    }
    if (-not $PSBoundParameters.ContainsKey('WikiAdminUser')) {
        $resp = Read-Host "Admin username [$WikiAdminUser]"
        if ($resp) { $Script:WikiAdminUser = $resp }
    }
    if (-not $PSBoundParameters.ContainsKey('LogoPath')) {
        $resp = Read-Host 'Path to a logo image file (optional, Enter to skip)'
        if ($resp) {
            if (Test-Path $resp) { $Script:LogoPath = $resp }
            else { Write-Warn "Logo file not found: $resp - skipping." }
        }
    }
    if (-not $PSBoundParameters.ContainsKey('Environment')) {
        $resp = Read-Host "Is this a production or dev/test install? [prod/dev] [$Environment]"
        if ($resp -match '^[Pp]') { $Script:Environment = 'Prod' } elseif ($resp -match '^[Dd]') { $Script:Environment = 'Dev' }
    }
    if (-not $PSBoundParameters.ContainsKey('PublicUrl') -and -not $Script:UseHttps) {
        $resp = Read-Host 'Set up HTTPS now? [y/N]'
        if ($resp -match '^[Yy]') {
            $hostname = Read-Host 'Public hostname (e.g. wiki.company.com)'
            if ($hostname) {
                $resp = Read-Host 'Do you already have a real certificate (.pem) for it? [y/N] (N generates + locally trusts a self-signed one, for testing only)'
                if ($resp -match '^[Yy]') {
                    $Script:CertPath = Read-Host 'Path to certificate .pem file'
                    $Script:CertKeyPath = Read-Host 'Path to certificate private key .pem file'
                } else {
                    Write-Host "Generating + trusting a self-signed certificate for '$hostname'..." -ForegroundColor DarkGray
                    $helper = Join-Path (Split-Path $Script:SelfPath -Parent) 'setup-local-https-test.ps1'
                    $certDir = Join-Path $Script:ProvDir 'certs'
                    & $helper -HostName $hostname -OutDir $certDir
                    $Script:CertPath = Join-Path $certDir 'cert.pem'
                    $Script:CertKeyPath = Join-Path $certDir 'key.pem'
                }
                $Script:PublicUrl = "https://$hostname"
            }
        }
    }
    if (-not $PSBoundParameters.ContainsKey('EnableEntraSso')) {
        $resp = Read-Host 'Enable Entra ID (Azure AD) SSO login? [y/N]'
        if ($resp -match '^[Yy]') {
            $Script:EnableEntraSso = $true
            if (-not $Script:EntraTenantId) { $Script:EntraTenantId = Read-Host 'Entra tenant ID' }
            if (-not $Script:EntraClientId) { $Script:EntraClientId = Read-Host 'Entra application (client) ID' }
            if (-not $Script:EntraClientSecret) { $Script:EntraClientSecret = Read-Host 'Entra client secret' -AsSecureString }
        }
    }

    Write-Host "`n--- Optional production QoL (all skippable, all reversible later via -Disable*) ---" -ForegroundColor Cyan
    if (-not $PSBoundParameters.ContainsKey('EnableJobRunner')) {
        $resp = Read-Host 'Run background jobs (notifications etc.) on a schedule instead of only on page views? [Y/n]'
        if ($resp -notmatch '^[Nn]') { $Script:EnableJobRunner = $true }
    }
    if (-not $PSBoundParameters.ContainsKey('EnableLogRotation')) {
        $resp = Read-Host 'Enable automatic log rotation? [Y/n]'
        if ($resp -notmatch '^[Nn]') { $Script:EnableLogRotation = $true }
    }
    if (-not $PSBoundParameters.ContainsKey('EnableBackups')) {
        $resp = Read-Host 'Enable daily automated backups (DB dump + LocalSettings.php/images)? [y/N]'
        if ($resp -match '^[Yy]') {
            $Script:EnableBackups = $true
            $resp = Read-Host "Backup retention in days [$BackupRetentionDays]"
            if ($resp -match '^\d+$') { $Script:BackupRetentionDays = [int]$resp }
        }
    }
    Write-Host ''
}

# Final recap before any actual work starts - same gate as the wizard (fresh install, interactive)
# so a first-time "one and done" run gets a chance to bail out before ~2-3 minutes of downloads.
function Show-SetupSummary {
    if ($NonInteractive -or $Force) { return }
    if (Test-Path (Join-Path $Script:WwwDir 'LocalSettings.php')) { return }

    Write-Host "`n=== About to provision ===" -ForegroundColor Cyan
    Write-Host "  Site name:     $SiteName"
    Write-Host "  Admin user:    $WikiAdminUser"
    Write-Host "  Environment:   $Environment"
    Write-Host "  URL:           $(if ($Script:UseHttps) { $PublicUrl } else { "http://localhost:$HttpPort/" })"
    Write-Host "  Database:      $(if ($UseExternalDb) { "external ($DbHost`:$DbPort)" } else { 'local MySQL (this script installs it)' })"
    Write-Host "  Entra SSO:     $(if ($EnableEntraSso) { 'enabled' } else { 'disabled' })"
    Write-Host "  Job runner:    $(if ($EnableJobRunner) { 'enabled' } else { 'disabled' })"
    Write-Host "  Log rotation:  $(if ($EnableLogRotation) { 'enabled' } else { 'disabled' })"
    Write-Host "  Backups:       $(if ($EnableBackups) { "enabled ($BackupRetentionDays days retention)" } else { 'disabled' })"
    Write-Host "  Install root:  $Script:Root"
    if ($ProxyUrl) { Write-Host "  Proxy:         $ProxyUrl" }
    $localSources = @('ApacheZipUrl', 'ModFcgidZipUrl', 'PhpZipUrl', 'ApcuZipUrl', 'MySqlZipUrl', 'PythonZipUrl', 'ComposerPharUrl', 'CaBundleUrl') |
        Where-Object { (Get-Variable -Name $_ -ValueOnly) -match '^(?:[A-Za-z]:\\|\\\\|file:///)' }
    if ($localSources) { Write-Host "  Local sources: $($localSources -join ', ')" }
    Read-Host "`nPress Enter to install, Ctrl+C to abort"
}
