# STEP 2: Apache (direct download, mod_fcgid, no IIS anywhere), including the HTTPS vhost when -PublicUrl/-CertPath/-CertKeyPath are set.

# ---------------------------------------------------------------------------
# STEP 2: Apache (direct download, mod_fcgid, no IIS anywhere)
# ---------------------------------------------------------------------------
function Install-ApacheBinaries {
    if (Test-Path (Join-Path $Script:ApacheDir 'bin\httpd.exe')) { Write-Note 'Apache binaries already present.'; return }
    Write-Step 'Downloading + extracting Apache HTTP Server (Apache Lounge)...'
    # Cache filename derived from the URL (not a fixed name like "httpd.zip") so bumping the
    # version in -ApacheZipUrl naturally invalidates the old cached download instead of silently
    # reusing it.
    $zip = Join-Path $Script:DownloadDir (Split-Path $ApacheZipUrl -Leaf)
    Get-RemoteFile -Url $ApacheZipUrl -Destination $zip -VendorPageOnFailure 'https://www.apachelounge.com/download.html'
    Expand-ToDir -ZipPath $zip -TargetDir $Script:ApacheDir

    Write-Step 'Downloading + extracting mod_fcgid (Apache Lounge)...'
    $fcgidZip = Join-Path $Script:DownloadDir (Split-Path $ModFcgidZipUrl -Leaf)
    Get-RemoteFile -Url $ModFcgidZipUrl -Destination $fcgidZip -VendorPageOnFailure 'https://www.apachelounge.com/download.html'
    $fcgidTmp = Join-Path $Script:DownloadDir 'mod_fcgid_extracted'
    Expand-Archive -Path $fcgidZip -DestinationPath $fcgidTmp -Force
    $fcgidSo = Get-ChildItem $fcgidTmp -Recurse -Filter 'mod_fcgid.so' | Select-Object -First 1
    if (-not $fcgidSo) { throw 'mod_fcgid.so not found in downloaded archive - check the zip layout / -ModFcgidZipUrl.' }
    Copy-Item $fcgidSo.FullName (Join-Path $Script:ApacheDir 'modules\mod_fcgid.so') -Force
    Remove-Item $fcgidTmp -Recurse -Force -ErrorAction SilentlyContinue
}

function Set-ApacheConfig {
    param([hashtable]$State)
    $foreign = (Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue) -and (-not $State.apacheServiceCreated)
    if ($foreign) {
        Confirm-Override -What "Windows service '$($Script:ApacheServiceName)'" -Detail 'A service with this exact name already exists and was not created by this script.'
    }
    $State.apacheIsForeign = $foreign
    Save-State $State

    Write-Step 'Writing Apache config (vhost, mod_fcgid, gzip, cache headers)...'
    # httpd -t validates DocumentRoot exists at config-load time even before MediaWiki's own
    # files land there later in Invoke-Up - an empty placeholder is enough to pass validation.
    New-Item -ItemType Directory -Force -Path $Script:WwwDir | Out-Null
    $phpCgi = Join-Path $Script:PhpDir 'php-cgi.exe'
    $vhostPath = Join-Path $Script:ApacheDir 'conf\extra\httpd-mediawiki.conf'
    $mainConf = Join-Path $Script:ApacheDir 'conf\httpd.conf'

    # Base conf shipped by Apache Lounge already has module lines for rewrite/deflate/expires/
    # headers commented in by default; ensure they're active and point ServerRoot at our copy.
    $conf = Get-Content $mainConf -Raw
    $conf = $conf -replace '(?m)^\s*#\s*(LoadModule (rewrite|deflate|expires|headers)_module.*)$', '$1'
    $conf = $conf -replace '(?m)^ServerRoot\s+.*$', "ServerRoot ""$($Script:ApacheDir -replace '\\','/')"""
    # Apache Lounge's shipped httpd.conf hardcodes the DocumentRoot/<Directory> it was built
    # with (e.g. C:/Apache24-64/htdocs) - httpd validates this path exists at config-load time
    # even though our own vhost (below) is what actually serves requests, so point it at our
    # MediaWiki root instead of leaving a dangling reference to a path that was never extracted here.
    $wwwSlash = $Script:WwwDir -replace '\\', '/'
    $conf = $conf -replace '(?m)^DocumentRoot\s+.*$', "DocumentRoot ""$wwwSlash"""
    $conf = $conf -replace '(?m)^(\s*<Directory\s+")[^"]*("[^>]*>)', "`${1}$wwwSlash`${2}"
    $conf = $conf -replace '(?m)^Listen\s+80\s*$', "Listen $HttpPort"
    if ($conf -notmatch 'LoadModule fcgid_module') { $conf += "`r`nLoadModule fcgid_module modules/mod_fcgid.so" }
    if ($Script:UseHttps) {
        $conf = $conf -replace '(?m)^\s*#\s*(LoadModule ssl_module.*)$', '$1'
        if ($conf -notmatch '(?m)^Listen\s+443\s*$') { $conf += "`r`nListen 443" }
    }

    # --- Perf tuning: Apache Lounge builds use the winnt MPM (one process, many threads) on
    # Windows - ThreadsPerChild is the main lever; mod_fcgid's own request-queue/process-reuse
    # settings avoid re-spawning php-cgi.exe per request, which is the #1 killer of FastCGI perf.
    if ($conf -notmatch '<IfModule mpm_winnt_module>') {
        $conf += @"

<IfModule mpm_winnt_module>
    ThreadsPerChild 150
    MaxConnectionsPerChild 0
</IfModule>
KeepAlive On
MaxKeepAliveRequests 200
KeepAliveTimeout 5

<IfModule fcgid_module>
    FcgidMaxRequestsPerProcess 500
    FcgidMinProcessesPerClass 2
    FcgidMaxProcessesPerClass 20
    FcgidIOTimeout 60
    FcgidBusyTimeout 60
</IfModule>
"@
    }
    if ($conf -notmatch 'Include conf/extra/httpd-mediawiki\.conf') { $conf += "`r`nInclude conf/extra/httpd-mediawiki.conf`r`n" }
    Set-Content -Path $mainConf -Value $conf -Encoding UTF8

    New-Item -ItemType Directory -Force -Path $Script:LogsDir | Out-Null
    # Apache's own config parser treats a bare backslash as an escape character even inside
    # quoted directive values on Windows - always use forward slashes in httpd.conf paths.
    $phpCgiSlash = $phpCgi -replace '\\', '/'
    $phpDirSlash = $Script:PhpDir -replace '\\', '/'
    $hostName = if ($Script:UseHttps) { ([Uri]$PublicUrl).Host } else { $null }
    $httpBody = if ($Script:UseHttps) {
        # HTTPS is configured - plain HTTP redirects to it rather than serving content over both,
        # so nothing sensitive (login, session cookies) ever goes out unencrypted.
        "    Redirect permanent `"/`" `"$PublicUrl/`""
    } else {
        @"
    DocumentRoot "$($Script:WwwDir -replace '\\','/')"
    <Directory "$($Script:WwwDir -replace '\\','/')">
        Options FollowSymLinks ExecCGI
        AllowOverride All
        Require all granted
        DirectoryIndex index.php
    </Directory>

    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/plain text/css application/javascript application/json
    </IfModule>
    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType image/png "access plus 30 days"
        ExpiresByType image/jpeg "access plus 30 days"
        ExpiresByType text/css "access plus 7 days"
        ExpiresByType application/javascript "access plus 7 days"
    </IfModule>
"@
    }
    $vhost = @"
$($Script:MarkerBegin)
<IfModule fcgid_module>
  FcgidInitialEnv PHPRC "$phpDirSlash"
  AddHandler fcgid-script .php
  FcgidWrapper "$phpCgiSlash" .php
</IfModule>

<VirtualHost *:$HttpPort>
$httpBody

    ErrorLog "$($Script:LogsDir -replace '\\','/')/mediawiki-error.log"
    CustomLog "$($Script:LogsDir -replace '\\','/')/mediawiki-access.log" common
</VirtualHost>
"@
    if ($Script:UseHttps) {
        $vhost += @"

<VirtualHost *:443>
    ServerName $hostName
    DocumentRoot "$($Script:WwwDir -replace '\\','/')"
    <Directory "$($Script:WwwDir -replace '\\','/')">
        Options FollowSymLinks ExecCGI
        AllowOverride All
        Require all granted
        DirectoryIndex index.php
    </Directory>
    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/plain text/css application/javascript application/json
    </IfModule>
    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType image/png "access plus 30 days"
        ExpiresByType image/jpeg "access plus 30 days"
        ExpiresByType text/css "access plus 7 days"
        ExpiresByType application/javascript "access plus 7 days"
    </IfModule>

    SSLEngine on
    SSLCertificateFile "$($CertPath -replace '\\','/')"
    SSLCertificateKeyFile "$($CertKeyPath -replace '\\','/')"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    ErrorLog "$($Script:LogsDir -replace '\\','/')/mediawiki-ssl-error.log"
    CustomLog "$($Script:LogsDir -replace '\\','/')/mediawiki-ssl-access.log" common
</VirtualHost>
"@
    }
    $vhost += "`n$($Script:MarkerEnd)"
    Set-Content -Path $vhostPath -Value $vhost -Encoding UTF8

    $httpdExe = Join-Path $Script:ApacheDir 'bin\httpd.exe'
    & $httpdExe -t
    if ($LASTEXITCODE -ne 0) { throw 'Apache config test failed (httpd -t) - see output above.' }

    if (-not (Get-Service -Name $Script:ApacheServiceName -ErrorAction SilentlyContinue)) {
        & $httpdExe -k install -n $Script:ApacheServiceName | Out-Null
        $State.apacheServiceCreated = $true
        Save-State $State
    }
    Set-Service -Name $Script:ApacheServiceName -StartupType Automatic
    Restart-Service -Name $Script:ApacheServiceName -Force
    Write-Note "Apache service '$($Script:ApacheServiceName)' running on port $HttpPort."
}

