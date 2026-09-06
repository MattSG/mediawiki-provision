# Entra ID (Azure AD) SSO via the PluggableAuth + OpenIDConnect extensions. Local admin login
# stays available alongside SSO (wgPluggableAuth_EnableLocalLogin) so a misconfigured tenant
# can't lock you out entirely.
#
# What to register on the Entra side:
#   - App registration -> Redirect URI (Web): <PublicUrl or http://localhost:HttpPort>/index.php?title=Special:PluggableAuthLogin
#     (query-string form, not /wiki/Special:... - this install has no short-URL rewrite configured,
#     so MediaWiki generates plain index.php?title=... URLs; verified against a live AADSTS50011
#     redirect-URI-mismatch error - if you enable short URLs later, add that variant too)
#   - A client secret under "Certificates & secrets"
#   - API permissions: Microsoft Graph -> openid, profile, email (delegated) - usually granted by default
$Script:SsoConfigFile = Join-Path $Script:ProvDir 'sso-config.json'

function ConvertFrom-SecureStringPlain {
    param([securestring]$Secure)
    if (-not $Secure) { return $null }
    [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secure))
}

# Persists (on this run's wizard/param answers) or reloads (on a later idempotent re-run) the
# SSO settings - same pattern as Save-DbCredentials/Get-SavedPassword, since LocalSettings.php's
# managed block is regenerated every run and needs these values each time, not just on first install.
function Get-SsoConfig {
    if ($DisableEntraSso) {
        Remove-Item $Script:SsoConfigFile -Force -ErrorAction SilentlyContinue
        return @{ Enabled = $false }
    }
    if ($EnableEntraSso -and $EntraTenantId -and $EntraClientId -and $EntraClientSecret) {
        $cfg = @{
            Enabled      = $true
            TenantId     = $EntraTenantId
            ClientId     = $EntraClientId
            ClientSecret = (ConvertFrom-SecureStringPlain $EntraClientSecret)
        }
        $cfg | ConvertTo-Json | Set-Content -Path $Script:SsoConfigFile
        icacls $Script:SsoConfigFile /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
        return $cfg
    }
    if (Test-Path $Script:SsoConfigFile) { return (Get-Content $Script:SsoConfigFile -Raw | ConvertFrom-Json -AsHashtable) }
    return @{ Enabled = $false }
}
