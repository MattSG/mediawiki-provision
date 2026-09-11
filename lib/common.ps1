# Logging, state persistence, credentials, admin/override checks, and generic download/extract helpers shared by every other module.

function Write-Step { param([string]$Message) $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message; Write-Host $l -ForegroundColor Cyan; Add-Content -Path $Script:LogFile -Value $l -ErrorAction SilentlyContinue }
function Write-Note { param([string]$Message) $l = "         {0}" -f $Message; Write-Host $l -ForegroundColor DarkGray; Add-Content -Path $Script:LogFile -Value $l -ErrorAction SilentlyContinue }
function Write-Warn { param([string]$Message) $l = "WARNING: {0}" -f $Message; Write-Host $l -ForegroundColor Yellow; Add-Content -Path $Script:LogFile -Value $l -ErrorAction SilentlyContinue }

# Per-step gate for Up/Down: prints what's about to happen and asks yes/no/quit before running it.
# Skipped entirely under -NonInteractive/-Force (same convention as the wizard) so unattended/CI
# runs never block on a prompt. 'n' skips just this one step and continues; 'q' aborts the whole run.
function Confirm-Step {
    param([string]$Summary)
    if ($Force -or $NonInteractive) { return $true }
    Write-Host "`n--> $Summary" -ForegroundColor Cyan
    $blankStreak = 0
    while ($true) {
        $resp = Read-Host '    Proceed? [Y]es / [n]o (skip this step) / [q]uit'
        if ([string]::IsNullOrEmpty($resp) -or $resp -match '^[Yy]') { return $true }
        if ($resp -match '^[Nn]') { Write-Note "Skipped: $Summary"; return $false }
        if ($resp -match '^[Qq]') { Write-Host 'Aborted by user.' -ForegroundColor Yellow; exit 1 }
        $blankStreak++
        if ($blankStreak -ge 5) { throw 'Halted: no interactive input available to answer this prompt.' }
        Write-Host "Enter Y, n, or q." -ForegroundColor Yellow
    }
}

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
    if (Test-Path $Script:CredFile) {
        $lines += Get-Content $Script:CredFile | Where-Object { $_ -notmatch '^(?:Generated |DB root pass:|DB user pass:)' }
    }
    $lines -join "`r`n" | Set-Content -Path $Script:CredFile
    icacls $Script:CredFile /inheritance:r /grant:r "$($env:USERNAME):F" "SYSTEM:F" | Out-Null
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
# Numbered-choice prompt helper - returns the 1-based index of what the user picked, re-prompting
# on anything else (no silent "wrong input just does the first option"). Read-Host returns an
# empty string forever once stdin hits EOF (piped input exhausted, redirected from /dev/null,
# etc.) rather than throwing - without a bound this would spin forever re-printing the menu, so
# a run of consecutive blank reads is treated as "no one is there to answer" and aborts instead.
function Read-Choice {
    param([string[]]$Options)
    $blankStreak = 0
    while ($true) {
        for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host "  $($i + 1)) $($Options[$i])" }
        $resp = Read-Host 'Choice'
        if ($resp -match '^\d+$' -and [int]$resp -ge 1 -and [int]$resp -le $Options.Count) { return [int]$resp }
        if ([string]::IsNullOrEmpty($resp)) {
            $blankStreak++
            if ($blankStreak -ge 5) { throw 'Halted: no interactive input available to answer this prompt.' }
        } else {
            $blankStreak = 0
        }
        Write-Host "Enter a number 1-$($Options.Count)." -ForegroundColor Yellow
    }
}

# Checked interactively for both Apache and MySQL: a same-named service existing elsewhere is
# survivable (this script's own services are isolated under InstallRoot on their own port), but
# something already LISTENING on the port this script needs WILL fail outright - either way, ask
# what to do rather than a bare "continue anyway", since on a real server this is genuinely likely
# (MySQL/a web server already installed with their usual defaults: 3306/80/443).
function Test-PreexistingInfrastructure {
    if ($Force -or $NonInteractive) { return }

    $apacheLike = Get-Service | Where-Object { $_.DisplayName -like '*Apache*' -and $_.Name -ne $Script:ApacheServiceName }
    $httpPortBusy = (Test-NetConnection -ComputerName 'localhost' -Port $HttpPort -WarningAction SilentlyContinue).TcpTestSucceeded
    while ($apacheLike -or $httpPortBusy) {
        Write-Host "`n!!! EXISTING APACHE/WEB SERVER DETECTED !!!" -ForegroundColor Red
        if ($apacheLike) { Write-Host "  Service(s): $($apacheLike.Name -join ', ')" -ForegroundColor Yellow }
        if ($httpPortBusy) { Write-Host "  Port $HttpPort is already in use - this WILL fail to bind as-is." -ForegroundColor Red }
        switch (Read-Choice @(
            "Continue anyway (fine if it's just a same-ish-named service, not an actual port clash)"
            'Use a different HTTP port for this install'
            'Abort so I can clear it down / reconfigure it myself first'
        )) {
            1 { break }
            2 {
                $resp = Read-Host "New HTTP port [$HttpPort]"
                if ($resp -match '^\d+$') { $Script:HttpPort = [int]$resp }
            }
            3 { throw 'Halted: existing Apache/web server needs to be dealt with first.' }
        }
        $apacheLike = Get-Service | Where-Object { $_.DisplayName -like '*Apache*' -and $_.Name -ne $Script:ApacheServiceName }
        $httpPortBusy = (Test-NetConnection -ComputerName 'localhost' -Port $HttpPort -WarningAction SilentlyContinue).TcpTestSucceeded
    }

    if ($Script:UseHttps -and (Test-NetConnection -ComputerName 'localhost' -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded) {
        Write-Host "`n!!! PORT 443 ALREADY IN USE !!!" -ForegroundColor Red
        Write-Host '  (e.g. IIS, another web server, or a previous HTTPS setup) - the HTTPS vhost will fail to start.' -ForegroundColor Red
        switch (Read-Choice @('Continue anyway', 'Skip HTTPS for this run (HTTP only)', 'Abort so I can clear it down myself first')) {
            2 { $Script:PublicUrl = $null; $Script:CertPath = $null; $Script:CertKeyPath = $null; Set-HttpsFlag }
            3 { throw 'Halted: something else already owns port 443.' }
        }
    }

    if ($UseExternalDb) { return }
    $mysqlLike = Get-Service | Where-Object { $_.DisplayName -like '*MySQL*' -and $_.Name -ne $Script:MysqlServiceName }
    $dbPortBusy = (Test-NetConnection -ComputerName 'localhost' -Port $DbPort -WarningAction SilentlyContinue).TcpTestSucceeded
    while ($mysqlLike -or $dbPortBusy) {
        Write-Host "`n!!! EXISTING MYSQL DETECTED !!!" -ForegroundColor Red
        if ($mysqlLike) { Write-Host "  Service(s): $($mysqlLike.Name -join ', ')" -ForegroundColor Yellow }
        if ($dbPortBusy) { Write-Host "  Port $DbPort is already in use - this WILL fail to bind as-is." -ForegroundColor Red }
        switch (Read-Choice @(
            "Continue anyway (fine if it's just a same-ish-named service, not an actual port clash)"
            'Use THIS existing MySQL instead of installing a separate one'
            'Use a different port for a new, separate MySQL install'
            'Abort so I can clear it down / reconfigure it myself first'
        )) {
            1 { break }
            2 {
                $Script:UseExternalDb = $true
                $Script:DbHost = (Read-Host "Database host [$DbHost]"); if (-not $Script:DbHost) { $Script:DbHost = $DbHost }
                $resp = Read-Host "Database port [$DbPort]"; if ($resp -match '^\d+$') { $Script:DbPort = [int]$resp }
                $Script:ExternalDbAdminUser = (Read-Host "Admin username on that database [$ExternalDbAdminUser]"); if (-not $Script:ExternalDbAdminUser) { $Script:ExternalDbAdminUser = $ExternalDbAdminUser }
                $Script:ExternalDbAdminPassword = Read-Host 'Admin password on that database'
                return
            }
            3 {
                $resp = Read-Host "New MySQL port [$DbPort]"
                if ($resp -match '^\d+$') { $Script:DbPort = [int]$resp }
            }
            4 { throw 'Halted: existing MySQL needs to be dealt with first.' }
        }
        $mysqlLike = Get-Service | Where-Object { $_.DisplayName -like '*MySQL*' -and $_.Name -ne $Script:MysqlServiceName }
        $dbPortBusy = (Test-NetConnection -ComputerName 'localhost' -Port $DbPort -WarningAction SilentlyContinue).TcpTestSucceeded
    }
}

function Get-RemoteFile {
    param([string]$Url, [string]$Destination, [string]$VendorPageOnFailure)
    if (Test-Path $Destination) { Write-Note "Already downloaded: $(Split-Path $Destination -Leaf)"; return }

    # A local path or UNC share (e.g. \\fileserver\mirrors\httpd.zip, or a plain drive-letter
    # path) instead of a URL - for a server that can't reach the internet at all. No proxy/TLS
    # concerns apply; just copy it.
    if ($Url -match '^(?:[A-Za-z]:\\|\\\\|file:///)') {
        $localPath = $Url -replace '^file:///', ''
        if (-not (Test-Path $localPath)) { throw "Configured local/UNC source not found: $localPath" }
        Write-Note "Copying $localPath ..."
        Copy-Item -Path $localPath -Destination $Destination -Force
        return
    }

    Write-Note "Downloading $Url ..."
    try {
        # Some vendors (Apache Lounge, MySQL's CDN) reject requests without TLS1.2 explicitly
        # negotiated and/or a browser-like User-Agent - plain Invoke-WebRequest defaults fail
        # against them with an opaque "Operation is not valid..." / 403 error.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $proxyArgs = @{}
        if ($ProxyUrl) {
            $proxyArgs['Proxy'] = $ProxyUrl
            if ($ProxyUseDefaultCredentials) { $proxyArgs['ProxyUseDefaultCredentials'] = $true }
            elseif ($ProxyCredential) { $proxyArgs['ProxyCredential'] = $ProxyCredential }
        }
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } -MaximumRedirection 5 @proxyArgs
    } catch {
        Remove-Item $Destination -ErrorAction SilentlyContinue
        $proxyHint = if ($ProxyUrl) { " (via proxy $ProxyUrl)" } else { '' }
        throw "Download failed: $Url$proxyHint`n  Vendor pages change exact filenames over time - check $VendorPageOnFailure for the current link and re-run with the matching -*Url override. If this server can't reach the internet directly, pass -ProxyUrl for a corporate proxy, or point the -*Url parameter at a local path/UNC share instead.`n  Original error: $($_.Exception.Message)"
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
