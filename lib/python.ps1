# STEP 5: Python (embeddable, zip-only) for SyntaxHighlight_GeSHi's bundled Pygments zipapp.

# ---------------------------------------------------------------------------
# STEP 5: Python (embeddable, zip-only - no installer/PATH change) for SyntaxHighlight_GeSHi's
# bundled, self-contained Pygments zipapp.
# ---------------------------------------------------------------------------
function Install-Python {
    $pythonExe = Join-Path $Script:PythonDir 'python.exe'
    if (Test-Path $pythonExe) { Write-Note 'Python already present.'; return }
    Write-Step 'Downloading + extracting Python (embeddable package)...'
    $zip = Join-Path $Script:DownloadDir (Split-Path $PythonZipUrl -Leaf)
    Get-RemoteFile -Url $PythonZipUrl -Destination $zip -VendorPageOnFailure 'https://www.python.org/downloads/windows/ (find the "Windows embeddable package (64-bit)" link)'
    # The embeddable zip has no single top-level folder - extract it flat into PythonDir rather
    # than going through Expand-ToDir's single-folder-unwrap logic.
    Expand-Archive -Path $zip -DestinationPath $Script:PythonDir -Force
    Write-Note "Python: $pythonExe"
}

