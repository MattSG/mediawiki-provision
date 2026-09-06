# Logging, state persistence, credentials, admin/override checks, and generic download/extract helpers shared by every other module.

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

# Recovers a password from a previous run's credentials file (e.g. "DB root pass: ...") - used
# so a re-run after a partial failure reuses what's actually in effect instead of generating a
# fresh value it then can't authenticate with.
function Get-SavedPassword {
    param([string]$Label)
    if (-not (Test-Path $Script:CredFile)) { return $null }
    $m = Select-String -Path $Script:CredFile -Pattern "^${Label}:\s*(.+)$"
    if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    return $null
}

# Written as soon as passwords are known (not just at the very end of Invoke-Up) so a script
# failure partway through a later step still leaves what's actually in effect discoverable on
# the next re-run. RootPass is $null for -UseExternalDb (no local root account to record).
function Save-DbCredentials {
    param([string]$RootPass, [string]$UserPass)
    $lines = @("Generated $(Get-Date -Format o)")
    if ($RootPass) { $lines += "DB root pass:    $RootPass" }
    $lines += "DB user pass:    $UserPass"
    $lines -join "`r`n" | Set-Content -Path $Script:CredFile
    icacls $Script:CredFile /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
}

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

# Runs once, before anything is touched, to catch generic pre-existing Apache/MySQL on this
# machine that Confirm-Override's exact-service-name check wouldn't (e.g. IIS's own Apache,
# or a MySQL instance under a different service name already listening on DbPort). This is a
# heads-up prompt, not a hard block - Confirm-Override still runs later if our specific service
# names collide.
function Test-PreexistingInfrastructure {
    if ($Force -or $NonInteractive) { return }
    $findings = [System.Collections.Generic.List[string]]::new()

    $apacheLike = Get-Service | Where-Object { $_.DisplayName -like '*Apache*' -and $_.Name -ne $Script:ApacheServiceName }
    if ($apacheLike) { $findings.Add("Existing Apache-like service(s): $($apacheLike.Name -join ', ')") }
    if ((Test-NetConnection -ComputerName 'localhost' -Port $HttpPort -WarningAction SilentlyContinue).TcpTestSucceeded) {
        $findings.Add("Port $HttpPort is already in use by something.")
    }

    if (-not $UseExternalDb) {
        $mysqlLike = Get-Service | Where-Object { $_.DisplayName -like '*MySQL*' -and $_.Name -ne $Script:MysqlServiceName }
        if ($mysqlLike) { $findings.Add("Existing MySQL-like service(s): $($mysqlLike.Name -join ', ')") }
        if ((Test-NetConnection -ComputerName 'localhost' -Port $DbPort -WarningAction SilentlyContinue).TcpTestSucceeded) {
            $findings.Add("Port $DbPort is already in use by something (pass -UseExternalDb to point the wiki at it instead of installing a new MySQL).")
        }
    }

    if ($findings.Count -eq 0) { return }
    Write-Host "`n!!! PRE-EXISTING APACHE/MYSQL DETECTED !!!" -ForegroundColor Red
    $findings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "This script installs its own isolated Apache/MySQL under $InstallRoot on port(s) $HttpPort/$DbPort - it will not touch what's listed above unless a service name collides (handled separately). Continuing is usually safe." -ForegroundColor Yellow
    $resp = Read-Host "`nType YES to continue, anything else halts (or re-run with -Force/-NonInteractive to skip this prompt)"
    if ($resp -ne 'YES') { throw 'Halted: did not confirm continuing alongside pre-existing Apache/MySQL.' }
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

