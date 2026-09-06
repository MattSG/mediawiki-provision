#Requires -Version 7.0
<#
.SYNOPSIS
  Companion to provision-mediawiki.ps1's -PublicUrl/-CertPath/-CertKeyPath HTTPS mode - generates
  a self-signed certificate, trusts it in this machine's Root store, and adds a hosts file entry
  so a chosen hostname resolves here. Lets you fully exercise -Environment Prod's HTTPS path
  locally. NOT for production use - production should use a real CA-issued certificate instead.

.PARAMETER HostName
  The hostname to mock, e.g. wiki.local.test. Default: wiki.local.test

.PARAMETER OutDir
  Where the generated cert/key PEM files are written. Default: C:\MediaWikiStack\_provisioning\certs

.PARAMETER Remove
  Undo: removes the hosts entry, removes the cert from the Root trust store, deletes the PEM files.

.EXAMPLE
  ./setup-local-https-test.ps1
  Then pass the printed values to provision-mediawiki.ps1:
    ./provision-mediawiki.ps1 -Environment Prod -PublicUrl https://wiki.local.test -CertPath ... -CertKeyPath ...

.EXAMPLE
  ./setup-local-https-test.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$HostName = 'wiki.local.test',
    [string]$OutDir = 'C:\MediaWikiStack\_provisioning\certs',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$metaFile = Join-Path $OutDir 'meta.json'

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated (Administrator) PowerShell 7 session.'
    }
}
Assert-Admin

if ($Remove) {
    if (Test-Path $metaFile) {
        $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
        $cert = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $meta.Thumbprint
        if ($cert) { Remove-Item $cert.PSPath -Force; Write-Host "Removed trusted cert $($meta.Thumbprint) from LocalMachine\Root." }
        $hostName = $meta.HostName
    } else {
        $hostName = $HostName
        Write-Warning "No metadata file found at $metaFile - only removing the hosts entry for '$HostName'."
    }
    if (Test-Path $hostsFile) {
        $lines = Get-Content $hostsFile | Where-Object { $_ -notmatch "^\s*127\.0\.0\.1\s+$([regex]::Escape($hostName))\s*$" }
        Set-Content -Path $hostsFile -Value $lines -Encoding ASCII
        Write-Host "Removed hosts entry for '$hostName'."
    }
    Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Done.'
    return
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "Generating self-signed certificate for '$HostName'..."
$cert = New-SelfSignedCertificate -DnsName $HostName -CertStoreLocation 'Cert:\LocalMachine\My' `
    -NotAfter (Get-Date).AddYears(2) -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 2048

$certPath = Join-Path $OutDir 'cert.pem'
$keyPath = Join-Path $OutDir 'key.pem'
[IO.File]::WriteAllText($certPath, $cert.ExportCertificatePem())
$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
[IO.File]::WriteAllText($keyPath, $rsa.ExportPkcs8PrivateKeyPem())
icacls $keyPath /inheritance:r /grant:r "$($env:USERNAME):F" "SYSTEM:F" | Out-Null
Write-Host "Wrote $certPath / $keyPath"

# New-SelfSignedCertificate only puts the cert in the personal (My) store - copy it into Root so
# the local machine (and browsers using the Windows trust store) actually trust it.
$rootStore = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
$rootStore.Open('ReadWrite')
$rootStore.Add($cert)
$rootStore.Close()
Write-Host "Trusted $($cert.Thumbprint) in LocalMachine\Root."

if (-not (Select-String -Path $hostsFile -Pattern "^\s*127\.0\.0\.1\s+$([regex]::Escape($HostName))\s*$" -Quiet)) {
    Add-Content -Path $hostsFile -Value "127.0.0.1`t$HostName" -Encoding ASCII
    Write-Host "Added hosts entry: 127.0.0.1 $HostName"
} else {
    Write-Host "hosts entry for '$HostName' already present."
}

@{ HostName = $HostName; Thumbprint = $cert.Thumbprint } | ConvertTo-Json | Set-Content $metaFile

Write-Host "`nDone. Run provision-mediawiki.ps1 with:" -ForegroundColor Green
Write-Host "  -Environment Prod -PublicUrl https://$HostName -CertPath `"$certPath`" -CertKeyPath `"$keyPath`""
Write-Host "`nTo undo: ./setup-local-https-test.ps1 -Remove"
