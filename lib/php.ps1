# STEP 3: PHP (direct download, php-cgi via mod_fcgid, APCu for object/opcode caching)

# ---------------------------------------------------------------------------
# STEP 3: PHP (direct download, php-cgi via mod_fcgid, APCu for object/opcode caching)
# ---------------------------------------------------------------------------
function Install-Php {
    if (Test-Path (Join-Path $Script:PhpDir 'php.exe')) {
        Write-Note 'PHP already present.'
    } else {
        Write-Step 'Downloading + extracting PHP (windows.php.net)...'
        $zip = Join-Path $Script:DownloadDir 'php.zip'
        Get-RemoteFile -Url $PhpZipUrl -Destination $zip -VendorPageOnFailure 'https://windows.php.net/download/'
        New-Item -ItemType Directory -Force -Path $Script:PhpDir | Out-Null
        Expand-Archive -Path $zip -DestinationPath $Script:PhpDir -Force

        Write-Step 'Downloading + installing APCu extension (object/opcode cache)...'
        $apcuZip = Join-Path $Script:DownloadDir 'apcu.zip'
        try {
            Get-RemoteFile -Url $ApcuZipUrl -Destination $apcuZip -VendorPageOnFailure 'https://windows.php.net/downloads/pecl/releases/apcu/'
            $apcuTmp = Join-Path $Script:DownloadDir 'apcu_extracted'
            Expand-Archive -Path $apcuZip -DestinationPath $apcuTmp -Force
            $dll = Get-ChildItem $apcuTmp -Filter 'php_apcu.dll' -Recurse | Select-Object -First 1
            if ($dll) { Copy-Item $dll.FullName (Join-Path $Script:PhpDir 'ext\php_apcu.dll') -Force }
            Remove-Item $apcuTmp -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "APCu download failed ($($_.Exception.Message)) - falling back to CACHE_DB for the object cache. MediaWiki still works, just without APCu's speed."
        }
    }

    # The windows.php.net zip ships no CA bundle, so PHP's curl/openssl extensions can't verify
    # ANY outbound HTTPS connection out of the box (e.g. "SSL certificate ... unable to get local
    # issuer certificate") - breaks OpenIDConnect's Entra calls, and would break any other
    # extension that calls out over HTTPS. Outside the "already present" branch above so an
    # existing install missing this (e.g. from before this fix) still gets it. Set-PhpIni points
    # curl.cainfo/openssl.cafile at this.
    $caPath = Join-Path $Script:PhpDir 'cacert.pem'
    if (-not (Test-Path $caPath)) {
        Write-Step 'Downloading CA certificate bundle (curl.se) for PHP outbound HTTPS calls...'
        Get-RemoteFile -Url 'https://curl.se/ca/cacert.pem' -Destination $caPath -VendorPageOnFailure 'https://curl.se/docs/caextract.html'
    }
}

function Set-PhpIni {
    Write-Step 'Configuring php.ini (extensions, OPcache/APCu, upload limits)...'
    $iniPath = Join-Path $Script:PhpDir 'php.ini'
    $srcIni = Join-Path $Script:PhpDir 'php.ini-production'
    if (-not (Test-Path $iniPath)) { Copy-Item $srcIni $iniPath }
    $ini = Get-Content $iniPath -Raw
    $extDir = Join-Path $Script:PhpDir 'ext'

    function Set-IniValue {
        param([string]$Content, [string]$Key, [string]$Value)
        # Matched on key+value together (not key alone) - several calls share the same key
        # (e.g. "extension" for mysqli/intl/apcu/...) and must coexist as separate lines rather
        # than each replacing the previous module's line.
        $line = "$Key = $Value"
        $pattern = "(?m)^\s*$([regex]::Escape($line))\s*$"
        if ($Content -match $pattern) { return $Content }
        return $Content + "`r`n$line`r`n"
    }

    $ini = Set-IniValue $ini 'extension_dir' "`"$extDir`""
    $caPath = Join-Path $Script:PhpDir 'cacert.pem'
    if (Test-Path $caPath) {
        $ini = Set-IniValue $ini 'curl.cainfo' "`"$caPath`""
        $ini = Set-IniValue $ini 'openssl.cafile' "`"$caPath`""
    }
    foreach ($ext in @('openssl', 'mysqli', 'intl', 'mbstring', 'curl', 'gd', 'xml', 'fileinfo')) {
        if (Test-Path (Join-Path $extDir "php_$ext.dll")) { $ini = Set-IniValue $ini 'extension' $ext }
    }
    # opcache is a Zend Extension, not an ordinary extension - loading it via "extension=" fails
    # with "Invalid library (appears to be a Zend Extension...)".
    if (Test-Path (Join-Path $extDir 'php_opcache.dll')) { $ini = Set-IniValue $ini 'zend_extension' 'opcache' }
    $Script:ApcuAvailable = Test-Path (Join-Path $extDir 'php_apcu.dll')
    if ($Script:ApcuAvailable) {
        $ini = Set-IniValue $ini 'extension' 'apcu'
        $ini += "`r`napc.enable_cli = 0`r`n"
    }

    $ini = Set-IniValue $ini 'opcache.enable' '1'
    $ini = Set-IniValue $ini 'opcache.enable_cli' '0'
    $ini = Set-IniValue $ini 'opcache.memory_consumption' '256'
    $ini = Set-IniValue $ini 'opcache.interned_strings_buffer' '16'
    $ini = Set-IniValue $ini 'opcache.max_accelerated_files' '20000'
    $ini = Set-IniValue $ini 'opcache.validate_timestamps' $(if ($Environment -eq 'Prod') { '0' } else { '1' })
    $ini = Set-IniValue $ini 'opcache.revalidate_freq' '2'
    $ini = Set-IniValue $ini 'upload_max_filesize' '64M'
    $ini = Set-IniValue $ini 'post_max_size' '64M'
    $ini = Set-IniValue $ini 'memory_limit' '256M'
    $ini = Set-IniValue $ini 'max_execution_time' '120'
    $ini = Set-IniValue $ini 'date.timezone' 'UTC'

    Set-Content -Path $iniPath -Value $ini -Encoding UTF8
    Write-Note "php.ini: $iniPath (APCu: $(if ($Script:ApcuAvailable) { 'enabled' } else { 'unavailable, using CACHE_DB fallback' }))"
}

