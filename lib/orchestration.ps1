# Invoke-Up / Invoke-Down / Invoke-Status - ties every STEP above together in order.

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
function Invoke-Up {
    Assert-Admin
    Invoke-SetupWizard
    Set-HttpsFlag  # wizard may have just set PublicUrl/CertPath/CertKeyPath itself
    Set-Layout      # wizard may have just changed InstallRoot itself
    # Runs after the wizard (not before) so a port conflict is checked against whatever
    # HttpPort/DbPort the user actually ends up with, not whatever they started with.
    Test-PreexistingInfrastructure
    Show-SetupSummary
    $rootPreexisted = Test-Path $Script:Root
    New-Item -ItemType Directory -Force -Path $Script:ProvDir, $Script:DownloadDir | Out-Null
    $state = Get-State
    if (-not $rootPreexisted -and -not $state.rootCreated) { $state.rootCreated = $true; Save-State $state }

    $Script:WikiAdminPassword = if ($WikiAdminPassword) { $WikiAdminPassword } else { New-RandomPassword }

    if (Confirm-Step 'Install/verify Apache + mod_fcgid binaries.') { Install-ApacheBinaries }
    if (Confirm-Step 'Install/verify PHP.') { Install-Php }
    if (Confirm-Step 'Write php.ini (extensions, OPcache/APCu, upload limits).') { Set-PhpIni }
    if (Confirm-Step 'Write Apache config (vhost, mod_fcgid, gzip, cache headers) and (re)start the Apache service.') { Set-ApacheConfig -State $state }
    if (Confirm-Step "Install/start MySQL$(if ($UseExternalDb) { " (skipped - using external DB at $DbHost`:$DbPort)" }).") { Install-MySql -State $state }
    if (Confirm-Step 'Install/verify the embedded Python runtime.') { Install-Python }
    if ($InstallPdfTools -and (Confirm-Step 'Install/verify PdfHandler tools (Ghostscript, ImageMagick, Poppler).')) { Install-PdfTools }

    if (Confirm-Step 'Download/verify MediaWiki core.') { Get-MediaWikiCore }
    if (Confirm-Step 'Install SemanticMediaWiki.') { Install-SemanticMediaWiki }
    if (Confirm-Step 'Install SemanticResultFormats and SemanticBreadcrumbLinks.') { Install-SemanticGithubComponents }
    $sso = Get-SsoConfig
    $extensionsToInstall = $Script:ZipExtensions + @(if ($sso.Enabled) { 'PluggableAuth', 'OpenIDConnect' })
    if (Confirm-Step "Install extensions: $($extensionsToInstall -join ', ').") {
        Write-Step 'Installing extensions (GitHub zip archives + composer where needed)...'
        Install-ZipComponents -Names $extensionsToInstall -SubDir 'extensions' -RepoPrefix 'mediawiki-extensions-' -MarkerFile 'extension.json'
    }
    if (Confirm-Step 'Install the external Mermaid extension.') { Install-Mermaid }
    if (Confirm-Step "Install skins: $($Script:ZipSkins -join ', ').") {
        Write-Step 'Installing skins (GitHub zip archives)...'
        Install-ZipComponents -Names $Script:ZipSkins -SubDir 'skins' -RepoPrefix 'mediawiki-skins-' -MarkerFile 'skin.json'
    }
    if (Confirm-Step 'Create/verify the wiki database and run the web installer if needed.') { Install-MediaWikiDatabase }
    if (Confirm-Step 'Configure file uploads directory and permissions.') { Set-UploadsAndPermissions }
    if (Confirm-Step 'Apply caching/performance settings to LocalSettings.php.') { Set-PerformanceAndCaching }
    if (Confirm-Step 'Run update.php (database schema for core + all extensions).') { Complete-Installation }
    if ($SeedDevelopmentContent -and (Confirm-Step 'Create the Development namespace and seed mock pages.')) { Seed-DevelopmentContent }

    if ($DisableJobRunner) {
        if (Confirm-Step 'Remove the background job-runner scheduled task.') { Unregister-JobRunnerTask }
    } elseif ($EnableJobRunner) {
        if (Confirm-Step 'Register the background job-runner scheduled task.') { Register-JobRunnerTask }
    }
    if ($DisableLogRotation) {
        if (Confirm-Step 'Remove the log-rotation scheduled task.') { Unregister-LogRotationTask }
    } elseif ($EnableLogRotation) {
        if (Confirm-Step 'Register the log-rotation scheduled task.') { Register-LogRotationTask }
    }
    if ($DisableBackups) {
        if (Confirm-Step 'Remove the automated-backup scheduled task.') { Unregister-BackupTask }
    } elseif ($EnableBackups) {
        if (Confirm-Step "Register the automated-backup scheduled task ($BackupRetentionDays days retention).") { Register-BackupTask }
    }

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
    Write-Step "Tearing down$(if ($KeepData) { ' (stop only, -KeepData set)' } else { ' (FULL WIPE)' })..."

    # --- Apache: only ever stopped/removed if THIS install created it. A pre-existing Apache
    # (coexisting with after Confirm-Override) is never stopped, let alone removed, by Down.
    if ($state.apacheServiceCreated -and (Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue)) {
        if (Confirm-Step "Stop$(if (-not $KeepData) { ' and uninstall' }) the Apache service '$($Script:ApacheServiceName)' (created by this install).") {
            Stop-Service -Name $Script:ApacheServiceName -Force -ErrorAction SilentlyContinue
            if (-not $KeepData) {
                $httpdExe = Join-Path $Script:ApacheDir 'bin\httpd.exe'
                if (Test-Path $httpdExe) { & $httpdExe -k uninstall -n $Script:ApacheServiceName 2>&1 | Out-Null }
            }
        }
    } elseif ($state.apacheIsForeign) {
        Write-Note "Apache service '$($Script:ApacheServiceName)' pre-existed - leaving it running, untouched."
    }

    # --- MySQL: same rule - external (-UseExternalDb) or foreign (pre-existing, name-collided)
    # instances are never stopped, removed, or have anything dropped from them by Down. Only a
    # MySQL this install actually created gets stopped/removed (its data goes with the rest of
    # $Script:Root below anyway, since that's this install's own isolated copy).
    if ($UseExternalDb -or $state.mysqlIsForeign) {
        Write-Note 'MySQL is external/pre-existing - leaving its service and databases untouched.'
    } elseif ($state.mysqlServiceCreated -and (Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue)) {
        if (Confirm-Step "Stop$(if (-not $KeepData) { ' and uninstall' }) the MySQL service '$($Script:MysqlServiceName)' (created by this install).") {
            Stop-Service -Name $Script:MysqlServiceName -Force -ErrorAction SilentlyContinue
            if (-not $KeepData) {
                $mysqldExe = Join-Path $Script:MysqlDir 'bin\mysqld.exe'
                if (Test-Path $mysqldExe) { & $mysqldExe --remove $Script:MysqlServiceName 2>&1 | Out-Null }
            }
        }
    }

    if (-not $KeepData) {
        if (Confirm-Step 'Remove any job-runner/log-rotation/backup scheduled tasks.') {
            Unregister-JobRunnerTask
            Unregister-LogRotationTask
            Unregister-BackupTask
        }
    }

    if (-not $KeepData -and $state.rootCreated -and (Test-Path $Script:Root)) {
        if (Confirm-Step "Delete $($Script:Root) and everything under it (this install's data, credentials, LocalSettings.php)." ) {
            Write-Note "Deleting $($Script:Root) (this script created it)."
            Remove-Item -Recurse -Force $Script:Root -ErrorAction SilentlyContinue
        }
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
