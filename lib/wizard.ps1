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
    if (-not $PSBoundParameters.ContainsKey('EnableEntraSso')) {
        $resp = Read-Host 'Enable Entra ID (Azure AD) SSO login? [y/N]'
        if ($resp -match '^[Yy]') {
            $Script:EnableEntraSso = $true
            if (-not $Script:EntraTenantId) { $Script:EntraTenantId = Read-Host 'Entra tenant ID' }
            if (-not $Script:EntraClientId) { $Script:EntraClientId = Read-Host 'Entra application (client) ID' }
            if (-not $Script:EntraClientSecret) { $Script:EntraClientSecret = Read-Host 'Entra client secret' -AsSecureString }
        }
    }
    Write-Host ''
}
