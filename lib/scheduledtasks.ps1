# Optional production QoL: background job processing, log rotation, and backups, each its own
# Task Scheduler task under $Script:TaskFolder. All idempotent (register only if not already
# present) and independently reversible via the matching Unregister-* function.
#
# A bare "pwsh.exe" as the task action relies on PATH resolution in the SYSTEM account's own
# environment, which isn't guaranteed to include it - resolve the full path once, up front.
$Script:PwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $Script:PwshExe) { $Script:PwshExe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }

function Register-JobRunnerTask {
    if (Get-ScheduledTask -TaskName 'RunJobs' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {
        Write-Note 'Job-runner scheduled task already registered.'; return
    }
    Write-Step "Registering scheduled task for background job processing (every $JobRunnerIntervalMinutes min)..."
    $phpExe = Join-Path $Script:PhpDir 'php.exe'
    $action = New-ScheduledTaskAction -Execute $phpExe -Argument 'maintenance\run.php runJobs --maxjobs=200' -WorkingDirectory $Script:WwwDir
    # [TimeSpan]::MaxValue serializes to a duration Task Scheduler's XML schema rejects
    # ("out of range") - 10 years is effectively "forever" for this purpose and well within range.
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $JobRunnerIntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
    Register-ScheduledTask -TaskName 'RunJobs' -TaskPath $Script:TaskFolder -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest | Out-Null
}

function Unregister-JobRunnerTask {
    if (Get-ScheduledTask -TaskName 'RunJobs' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {
        Write-Note 'Removing job-runner scheduled task...'
        Unregister-ScheduledTask -TaskName 'RunJobs' -TaskPath $Script:TaskFolder -Confirm:$false
    }
}

function Register-LogRotationTask {
    if (Get-ScheduledTask -TaskName 'LogRotation' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {
        Write-Note 'Log rotation scheduled task already registered.'; return
    }
    Write-Step 'Registering scheduled log rotation task (daily, 30 days retention)...'
    $scriptPath = Join-Path $Script:ProvDir 'rotate-logs.ps1'
    @"
`$logsDir = '$($Script:LogsDir)'
`$cutoff = (Get-Date).AddDays(-30)
Get-ChildItem `$logsDir -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { `$_.Length -gt 20MB } | ForEach-Object {
    Move-Item `$_.FullName "`$(`$_.FullName).`$(Get-Date -Format yyyyMMdd).old" -Force
}
Get-ChildItem `$logsDir -Filter '*.old' -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt `$cutoff | Remove-Item -Force
"@ | Set-Content -Path $scriptPath
    $action = New-ScheduledTaskAction -Execute $Script:PwshExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At '03:00'
    Register-ScheduledTask -TaskName 'LogRotation' -TaskPath $Script:TaskFolder -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest | Out-Null
}

function Unregister-LogRotationTask {
    if (Get-ScheduledTask -TaskName 'LogRotation' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {
        Write-Note 'Removing log rotation scheduled task...'
        Unregister-ScheduledTask -TaskName 'LogRotation' -TaskPath $Script:TaskFolder -Confirm:$false
    }
    Remove-Item (Join-Path $Script:ProvDir 'rotate-logs.ps1') -Force -ErrorAction SilentlyContinue
}

# Runs one backup (DB dump + LocalSettings.php/images archive) - callable directly
# (`-Action Backup`) or from the scheduled task. External-DB backups need a `mysqldump` client
# on PATH and -ExternalDbAdminPassword; a local install always has its own mysqldump.exe.
function Send-BackupFailureAlert {
    param([string]$ErrorMessage)
    $recipients = @($BackupAlertRecipients | ForEach-Object { $_ -split '[,;]' } | ForEach-Object Trim | Where-Object { $_ })
    if (-not $recipients) { return }
    if (-not $MailRelay) { Write-Warn 'Backup failed, but no MailRelay is configured for alert delivery.'; return }
    try {
        $from = if ($MailFrom) { $MailFrom } elseif ($MailUsername) { $MailUsername } else { "mediawiki@$env:COMPUTERNAME" }
        $mailArgs = @{
            To = $recipients
            From = $from
            Subject = "MediaWiki backup failed on $env:COMPUTERNAME"
            Body = "The MediaWiki backup failed at $(Get-Date -Format o).`r`n`r`n$ErrorMessage"
            SmtpServer = $MailRelay
            Port = $MailPort
        }
        if ($MailUsername -and $MailPassword) {
            $mailArgs.Credential = [pscredential]::new($MailUsername, $MailPassword)
            $mailArgs.UseSsl = ($MailPort -eq 465 -or $MailPort -eq 587)
        }
        Send-MailMessage @mailArgs -ErrorAction Stop
        Write-Note "Backup failure alert sent to $($recipients -join ', ')."
    } catch {
        Write-Warn "Backup failure alert could not be sent: $($_.Exception.Message)"
    }
}

function Invoke-WikiBackupCore {
    Write-Step "Backing up to $BackupPath..."
    New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    $mysqldumpExe = if ($UseExternalDb) {
        (Get-Command mysqldump.exe, mysqldump -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    } else {
        Join-Path $Script:MysqlDir 'bin\mysqldump.exe'
    }
    $dbPass = if ($UseExternalDb) { $ExternalDbAdminPassword } else { Get-SavedPassword 'DB root pass' }
    $dbUser = if ($UseExternalDb) { $ExternalDbAdminUser } else { 'root' }
    if ($mysqldumpExe -and (Test-Path $mysqldumpExe) -and $dbPass) {
        $dumpFile = Join-Path $BackupPath "db-$stamp.sql"
        & $mysqldumpExe -h $DbHost -P $DbPort -u $dbUser "-p$dbPass" $Script:DbName 2>$null | Set-Content -Path $dumpFile -Encoding UTF8
        $dumpExit = $LASTEXITCODE
        if ($dumpExit -ne 0 -or -not (Test-Path $dumpFile) -or (Get-Item $dumpFile).Length -eq 0) {
            Remove-Item $dumpFile -Force -ErrorAction SilentlyContinue
            throw "Database backup failed (mysqldump exit code $dumpExit)."
        }
        Write-Note "Database dump: $dumpFile"
    } else {
        throw 'Could not locate mysqldump or database credentials for the backup.'
    }

    $filesZip = Join-Path $BackupPath "files-$stamp.zip"
    $toArchive = @(Join-Path $Script:WwwDir 'LocalSettings.php') + @(Join-Path $Script:WwwDir 'images') | Where-Object { Test-Path $_ }
    if ($toArchive) {
        Compress-Archive -Path $toArchive -DestinationPath $filesZip -Force
        Write-Note "Files archive: $filesZip"
    }

    Get-ChildItem $BackupPath -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddDays(-$BackupRetentionDays) | Remove-Item -Force
    icacls $BackupPath /inheritance:r /grant:r "$($env:USERNAME):F" "SYSTEM:F" | Out-Null
}

function Invoke-WikiBackup {
    try { Invoke-WikiBackupCore }
    catch {
        Send-BackupFailureAlert -ErrorMessage $_.Exception.Message
        throw
    }
}

function Register-BackupTask {
    if (Get-ScheduledTask -TaskName 'Backup' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {
        Write-Note 'Backup scheduled task already registered.'; return
    }
    Write-Step "Registering scheduled daily backup task ($BackupRetentionDays days retention)..."
    $extraArgs = if ($UseExternalDb) { " -UseExternalDb -DbHost `"$DbHost`" -DbPort $DbPort -ExternalDbAdminUser `"$ExternalDbAdminUser`"" } else { '' }
    if ($MailRelay -and $BackupAlertRecipients) {
        $recipients = $BackupAlertRecipients -join ','
        $extraArgs += " -MailRelay `"$MailRelay`" -MailPort $MailPort -BackupAlertRecipients `"$recipients`""
        if ($MailUsername) { $extraArgs += " -MailUsername `"$MailUsername`"" }
        if ($MailFrom) { $extraArgs += " -MailFrom `"$MailFrom`"" }
    }
    $argument = "-NoProfile -ExecutionPolicy Bypass -File `"$Script:SelfPath`" -Action Backup -InstallRoot `"$Script:Root`" -BackupPath `"$BackupPath`" -BackupRetentionDays $BackupRetentionDays -NonInteractive$extraArgs"
    $action = New-ScheduledTaskAction -Execute $Script:PwshExe -Argument $argument
    $trigger = New-ScheduledTaskTrigger -Daily -At '02:00'
    Register-ScheduledTask -TaskName 'Backup' -TaskPath $Script:TaskFolder -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest | Out-Null
    # -ExternalDbAdminPassword deliberately isn't passed to the scheduled task (plaintext in the
    # task definition, visible via Task Scheduler UI) - external-DB backups need it supplied some
    # other way (e.g. edit the task's action to read it from a locked-down file) if automated.
}

function Unregister-BackupTask {
    if (Get-ScheduledTask -TaskName 'Backup' -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue) {
        Write-Note 'Removing backup scheduled task...'
        Unregister-ScheduledTask -TaskName 'Backup' -TaskPath $Script:TaskFolder -Confirm:$false
    }
}
