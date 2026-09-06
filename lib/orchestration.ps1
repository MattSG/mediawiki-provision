# Invoke-Up / Invoke-Down / Invoke-Status - ties every STEP above together in order.

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
function Invoke-Up {
    Assert-Admin
    Test-PreexistingInfrastructure
    Invoke-SetupWizard
    $rootPreexisted = Test-Path $Script:Root
    New-Item -ItemType Directory -Force -Path $Script:ProvDir, $Script:DownloadDir | Out-Null
    $state = Get-State
    if (-not $rootPreexisted -and -not $state.rootCreated) { $state.rootCreated = $true; Save-State $state }

    $Script:WikiAdminPassword = if ($WikiAdminPassword) { $WikiAdminPassword } else { New-RandomPassword }

    Install-ApacheBinaries
    Install-Php
    Set-PhpIni
    Set-ApacheConfig -State $state
    Install-MySql -State $state
    Install-Python

    Get-MediaWikiCore
    Install-SemanticMediaWiki
    $sso = Get-SsoConfig
    $extensionsToInstall = $Script:ZipExtensions + @(if ($sso.Enabled) { 'PluggableAuth', 'OpenIDConnect' })
    Write-Step 'Installing extensions (GitHub zip archives + composer where needed)...'
    Install-ZipComponents -Names $extensionsToInstall -SubDir 'extensions' -RepoPrefix 'mediawiki-extensions-' -MarkerFile 'extension.json'
    Write-Step 'Installing skins (GitHub zip archives)...'
    Install-ZipComponents -Names $Script:ZipSkins -SubDir 'skins' -RepoPrefix 'mediawiki-skins-' -MarkerFile 'skin.json'
    Install-MediaWikiDatabase
    Set-UploadsAndPermissions
    Set-PerformanceAndCaching
    Complete-Installation

    if ($DisableJobRunner) { Unregister-JobRunnerTask } elseif ($EnableJobRunner) { Register-JobRunnerTask }
    if ($DisableLogRotation) { Unregister-LogRotationTask } elseif ($EnableLogRotation) { Register-LogRotationTask }
    if ($DisableBackups) { Unregister-BackupTask } elseif ($EnableBackups) { Register-BackupTask }

    $wikiUrl = if ($Script:UseHttps) { $PublicUrl } else { "http://localhost:$HttpPort/" }
    $lines = @(
        "Generated $(Get-Date -Format o)",
        "Wiki URL:        $wikiUrl",
        "Wiki admin user: $WikiAdminUser",
        "Wiki admin pass: $($Script:WikiAdminPassword)"
    )
    if ($Script:DbRootPassword) { $lines += "DB root pass:    $($Script:DbRootPassword)" }
    $lines += "DB user pass:    $($Script:DbUserPassword)"
    $lines += "Install root:    $($Script:Root)  (back this whole folder up)"
    $lines -join "`r`n" | Set-Content -Path $Script:CredFile
    icacls $Script:CredFile /inheritance:r /grant:r "$($env:USERNAME):F" "SYSTEM:F" | Out-Null

    Write-Step 'Done.'
    Write-Note "Wiki:        $wikiUrl"
    Write-Note "Admin user:  $WikiAdminUser"
    Write-Note "Credentials: $($Script:CredFile)"

    Write-Host "`n--- Production checklist ---" -ForegroundColor Cyan
    Write-Host "[$(if ($Environment -eq 'Prod') {'x'} else {' '})] -Environment Prod set (disables debug output, enables opcache timestamp skip)"
    Write-Host "[$(if ($Script:UseHttps) {'x'} else {' '})] HTTPS configured (plain HTTP redirects to it when set)"
    Write-Host "[ ] Log in and change the generated admin password above to one you'll remember"
    Write-Host "[$(if (Get-ScheduledTask -TaskName 'RunJobs' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {'x'} else {' '})] Background job runner (-EnableJobRunner) - notifications/deferred work processed on a schedule, not just on page views"
    Write-Host "[$(if (Get-ScheduledTask -TaskName 'LogRotation' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {'x'} else {' '})] Log rotation (-EnableLogRotation)"
    Write-Host "[$(if (Get-ScheduledTask -TaskName 'Backup' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {'x'} else {' '})] Automated backups (-EnableBackups) - DB dump + LocalSettings.php/images, see -BackupPath"
    if ($sso.Enabled) { Write-Host '  -> SSO is enabled: if this was set up against a test/throwaway Entra app registration, rotate or delete it before real use' -ForegroundColor Yellow }
    Write-Host "Scheduled tasks (if any) live under Task Scheduler folder '$($Script:TaskFolder)'."
}

function Invoke-Down {
    $state = Get-State
    if (-not $DbRootPassword) { $DbRootPassword = Get-SavedPassword 'DB root pass' }
    Write-Step "Tearing down$(if ($KeepData) { ' (stop only, -KeepData set)' } else { ' (FULL WIPE)' })..."

    # --- Apache ---
    if (Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $Script:ApacheServiceName -Force -ErrorAction SilentlyContinue
        if (-not $KeepData -and $state.apacheServiceCreated) {
            $httpdExe = Join-Path $Script:ApacheDir 'bin\httpd.exe'
            if (Test-Path $httpdExe) { & $httpdExe -k uninstall -n $Script:ApacheServiceName 2>&1 | Out-Null }
        }
    }

    # --- MySQL ---
    if ($UseExternalDb) {
        if (-not $KeepData -and $ExternalDbAdminPassword) {
            $mysqlExe = (Get-Command mysql.exe, mysql -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if ($mysqlExe) {
                Write-Note "Dropping only the '$($Script:DbName)' database/user on the external MySQL (it isn't ours to touch otherwise)."
                "DROP DATABASE IF EXISTS $($Script:DbName); DROP USER IF EXISTS '$($Script:DbUser)'@'%'; DROP USER IF EXISTS '$($Script:DbUser)'@'localhost';" | & $mysqlExe -h $DbHost -P $DbPort -u $ExternalDbAdminUser "-p$ExternalDbAdminPassword" 2>$null
            }
        }
    } elseif (Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue) {
        if (-not $KeepData -and $state.mysqlIsForeign) {
            $mysqlExe = Join-Path $Script:MysqlDir 'bin\mysql.exe'
            if ((Test-Path $mysqlExe) -and $DbRootPassword) {
                Write-Note "Dropping only the '$($Script:DbName)' database/user (MySQL instance pre-existed - leaving it running)."
                "DROP DATABASE IF EXISTS $($Script:DbName); DROP USER IF EXISTS '$($Script:DbUser)'@'localhost';" | & $mysqlExe -uroot -p"$DbRootPassword" 2>$null
            }
        } else {
            Stop-Service -Name $Script:MysqlServiceName -Force -ErrorAction SilentlyContinue
            if (-not $KeepData -and $state.mysqlServiceCreated) {
                $mysqldExe = Join-Path $Script:MysqlDir 'bin\mysqld.exe'
                if (Test-Path $mysqldExe) { & $mysqldExe --remove $Script:MysqlServiceName 2>&1 | Out-Null }
            }
        }
    }

    if (-not $KeepData) {
        Unregister-JobRunnerTask
        Unregister-LogRotationTask
        Unregister-BackupTask
    }

    if (-not $KeepData -and $state.rootCreated -and (Test-Path $Script:Root)) {
        Write-Note "Deleting $($Script:Root) (this script created it)."
        Remove-Item -Recurse -Force $Script:Root -ErrorAction SilentlyContinue
    }
    Write-Step 'Down.'
}

# Runs one backup on demand (-Action Backup) - the same function the scheduled backup task calls.
function Invoke-Backup {
    # No Assert-Admin here (unlike Up/Down): the scheduled backup task runs as NT AUTHORITY\SYSTEM,
    # which has full effective privileges but is not itself a member of BUILTIN\Administrators, so
    # WindowsPrincipal.IsInRole(Administrator) reports false for it - Assert-Admin would wrongly
    # reject every scheduled run. Backup only reads DB/files and writes to BackupPath, no admin
    # operation (service install, etc.) needed.
    Invoke-WikiBackup
}

function Invoke-Status {
    Write-Host "`nApache service:" -ForegroundColor Yellow
    Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue | Format-Table Name, Status -AutoSize
    Write-Host 'MySQL service:' -ForegroundColor Yellow
    Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue | Format-Table Name, Status -AutoSize
    Write-Host "Site check: http://localhost:$HttpPort/" -ForegroundColor Yellow
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$HttpPort/" -UseBasicParsing -TimeoutSec 5
        Write-Host "  HTTP $($resp.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "  unreachable: $($_.Exception.Message)" -ForegroundColor Red
    }
}

