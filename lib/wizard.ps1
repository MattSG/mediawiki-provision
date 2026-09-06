# Interactive setup wizard - only asks for values not already given via parameters, and only
# on a fresh install (LocalSettings.php doesn't exist yet) since these are one-time site-identity
# choices, not something to re-prompt for on every idempotent re-run. -NonInteractive or -Force
# skip it entirely (pass everything you want via parameters in that case).
function Invoke-SetupWizard {
    if ($NonInteractive -or $Force) { return }
    if (Test-Path (Join-Path $Script:WwwDir 'LocalSettings.php')) { return }

    Write-Host "`n=== MediaWiki setup - press Enter to accept the default shown in [brackets] ===" -ForegroundColor Cyan

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
    Read-Host "`nPress Enter to install, Ctrl+C to abort"
}
