# STEP 4: MySQL - either a native local install (default) or connecting to -UseExternalDb.

# ---------------------------------------------------------------------------
# STEP 4: MySQL (native, direct zip download - no installer, no service manager)
# ---------------------------------------------------------------------------
function ConvertTo-MySqlLiteral {
    param([AllowEmptyString()][string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace("'", "''")
    return "'$escaped'"
}

function Install-MySql {
    param([hashtable]$State)

    if ($UseExternalDb) {
        Write-Step "Using external MySQL at ${DbHost}:${DbPort} (skipping local install)..."
        $mysqlExe = (Get-Command mysql.exe, mysql -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $mysqlExe) { throw "-UseExternalDb requires a 'mysql' client on PATH to create the wiki's database/user - install MySQL client tools, or drop -UseExternalDb to let this script provision its own." }
        if (-not $ExternalDbAdminPassword) { throw '-UseExternalDb requires -ExternalDbAdminPassword (credentials for an account that can CREATE DATABASE/USER on it).' }
        if (-not $DbUserPassword) { $DbUserPassword = Get-SavedPassword 'DB user pass' }
        if (-not $DbUserPassword) { $DbUserPassword = New-RandomPassword }
        $Script:DbUserPassword = $DbUserPassword
        Save-DbCredentials -RootPass $null -UserPass $DbUserPassword
        if ($ExternalDbUserHost) {
            if ($ExternalDbUserHost -match "['\\`"]") { throw '-ExternalDbUserHost cannot contain SQL quoting characters.' }
            $dbUserHost = $ExternalDbUserHost
        } elseif ($DbHost -in @('127.0.0.1', 'localhost', '::1')) {
            $dbUserHost = 'localhost'
        } elseif ($Environment -eq 'Prod') {
            throw '-ExternalDbUserHost is required for external Prod databases; avoid granting the wiki account to every host.'
        } else {
            $dbUserHost = '%'
        }
        $dbUserHostSql = ConvertTo-MySqlLiteral $dbUserHost
        $dbUserPasswordSql = ConvertTo-MySqlLiteral $DbUserPassword
        $sql = @"
CREATE DATABASE IF NOT EXISTS $($Script:DbName) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$($Script:DbUser)'@$dbUserHostSql;
ALTER USER '$($Script:DbUser)'@$dbUserHostSql IDENTIFIED BY $dbUserPasswordSql;
GRANT ALL PRIVILEGES ON $($Script:DbName).* TO '$($Script:DbUser)'@$dbUserHostSql;
FLUSH PRIVILEGES;
"@
        $sql | & $mysqlExe -h $DbHost -P $DbPort -u $ExternalDbAdminUser "-p$ExternalDbAdminPassword" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "External MySQL database/user provisioning failed with exit code $LASTEXITCODE." }
        return
    }

    $foreign = (Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue) -and (-not $State.mysqlServiceCreated)
    if ($foreign) {
        Confirm-Override -What "Windows service '$($Script:MysqlServiceName)'" -Detail 'A service with this exact name already exists and was not created by this script.'
    }
    $State.mysqlIsForeign = $foreign
    Save-State $State

    if (Test-Path (Join-Path $Script:MysqlDir 'bin\mysqld.exe')) {
        Write-Note 'MySQL binaries already present.'
    } else {
        Write-Step 'Downloading + extracting MySQL Community Server (zip, no installer)...'
        $zip = Join-Path $Script:DownloadDir (Split-Path $MySqlZipUrl -Leaf)
        Get-RemoteFile -Url $MySqlZipUrl -Destination $zip -VendorPageOnFailure 'https://dev.mysql.com/downloads/mysql/ (choose "Windows (x86, 64-bit), ZIP Archive")'
        Expand-ToDir -ZipPath $zip -TargetDir $Script:MysqlDir
    }

        $dataDir = Join-Path $Script:MysqlDir 'data'
    $iniPath = Join-Path $Script:MysqlDir 'my.ini'
    if (-not (Test-Path $iniPath)) {
        # Perf tuning sized for a single-box wiki (not a shared/multi-tenant DB server):
        # innodb_buffer_pool_size is the single biggest MySQL perf lever - large enough to
        # hold the working set (page/revision tables) in memory instead of hitting disk.
        $totalMemMB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
        $bufferPoolMB = [math]::Max(256, [math]::Min(2048, [math]::Floor($totalMemMB * 0.25)))
        $flushAtCommit = if ($Environment -eq 'Prod') { 1 } else { 2 }
        $performanceSchema = if ($Environment -eq 'Prod') { 'ON' } else { 'OFF' }
        @"
[mysqld]
port=$DbPort
basedir=$($Script:MysqlDir)
datadir=$dataDir
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

# --- Perf tuning for a single-box MediaWiki install ---
innodb_buffer_pool_size=${bufferPoolMB}M
innodb_log_file_size=128M
innodb_flush_log_at_trx_commit=$flushAtCommit
innodb_flush_method=unbuffered
max_connections=150
table_open_cache=2000
thread_cache_size=16
tmp_table_size=64M
max_heap_table_size=64M
# Diagnostics/monitoring overhead not needed on a small single-box install - frees RAM.
performance_schema=$performanceSchema
"@ | Set-Content $iniPath
    }

    $mysqldExe = Join-Path $Script:MysqlDir 'bin\mysqld.exe'
    if (-not (Test-Path $dataDir)) {
        Write-Step 'Initializing MySQL data directory...'
        & $mysqldExe --defaults-file=$iniPath --initialize-insecure --datadir=$dataDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "MySQL data directory initialization failed with exit code $LASTEXITCODE." }
    }

    if (-not (Get-Service -Name $Script:MysqlServiceName -ErrorAction SilentlyContinue)) {
        Write-Step "Registering MySQL Windows service '$($Script:MysqlServiceName)'..."
        & $mysqldExe --install $Script:MysqlServiceName --defaults-file=$iniPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "MySQL service installation failed with exit code $LASTEXITCODE." }
        $State.mysqlServiceCreated = $true
        Save-State $State
    }
    Set-Service -Name $Script:MysqlServiceName -StartupType Automatic
    Start-Service -Name $Script:MysqlServiceName -ErrorAction Stop

    $mysqlExe = Join-Path $Script:MysqlDir 'bin\mysql.exe'
    Write-Note 'Waiting for MySQL to accept connections...'
    # Poll the TCP port, not an authenticated query - once root's password has been set (below),
    # a passwordless login attempt fails even though the server is up and healthy.
    $deadline = (Get-Date).AddSeconds(60)
    $ready = $false
    do {
        Start-Sleep -Seconds 2
        $ready = (Test-NetConnection -ComputerName 'localhost' -Port $DbPort -WarningAction SilentlyContinue).TcpTestSucceeded
    } until ($ready -or (Get-Date) -gt $deadline)
    if (-not $ready) { throw 'MySQL service did not become ready in time - check logs under the mysql\data directory.' }

    # Root/mediawiki-user passwords may already have been set by a prior partial run - reuse them
    # (from the credentials file, written early below) rather than re-running with fresh passwords
    # we then can't authenticate with next time.
    if (-not $DbRootPassword) { $DbRootPassword = Get-SavedPassword 'DB root pass' }
    if (-not $DbUserPassword) { $DbUserPassword = Get-SavedPassword 'DB user pass' }

    $rootAuthArgs = @('-uroot', '--skip-password')
    if ($DbRootPassword) {
        & $mysqlExe -uroot "-p$DbRootPassword" -e 'SELECT 1' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $rootAuthArgs = @('-uroot', "-p$DbRootPassword") }
    }

    if (-not $DbRootPassword) { $DbRootPassword = New-RandomPassword }
    if (-not $DbUserPassword) { $DbUserPassword = New-RandomPassword }
    $Script:DbRootPassword = $DbRootPassword
    $Script:DbUserPassword = $DbUserPassword

    Save-DbCredentials -RootPass $DbRootPassword -UserPass $DbUserPassword

    $rootPasswordSql = ConvertTo-MySqlLiteral $DbRootPassword
    $dbUserPasswordSql = ConvertTo-MySqlLiteral $DbUserPassword
    $sql = @"
ALTER USER 'root'@'localhost' IDENTIFIED BY $rootPasswordSql;
CREATE DATABASE IF NOT EXISTS $($Script:DbName) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$($Script:DbUser)'@'localhost';
ALTER USER '$($Script:DbUser)'@'localhost' IDENTIFIED BY $dbUserPasswordSql;
GRANT ALL PRIVILEGES ON $($Script:DbName).* TO '$($Script:DbUser)'@'localhost';
FLUSH PRIVILEGES;
"@
    $sql | & $mysqlExe @rootAuthArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Local MySQL database/user provisioning failed with exit code $LASTEXITCODE." }
}
