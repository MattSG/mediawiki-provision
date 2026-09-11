# Optional PdfHandler prerequisites, kept under InstallRoot and wired by absolute path.

function Find-PdfExecutable {
    param([string[]]$Names, [string[]]$Roots)
    foreach ($root in @($Roots | Where-Object { $_ -and (Test-Path $_) })) {
        foreach ($name in $Names) {
            $match = Get-ChildItem -Path $root -Filter $name -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) { return $match.FullName }
        }
    }
    foreach ($name in $Names) {
        $match = Get-Command $name -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\System32\\convert\.exe$' } | Select-Object -First 1
        if ($match) { return $match.Source }
    }
    return $null
}

function Get-PdfToolPaths {
    [ordered]@{
        Ghostscript = Find-PdfExecutable @('gswin64c.exe', 'gs.exe') @((Join-Path $Script:PdfToolsDir 'ghostscript'))
        ImageMagick = Find-PdfExecutable @('magick.exe', 'convert.exe') @((Join-Path $Script:PdfToolsDir 'imagemagick'))
        PdfInfo = Find-PdfExecutable @('pdfinfo.exe') @((Join-Path $Script:PdfToolsDir 'poppler'))
        PdfToText = Find-PdfExecutable @('pdftotext.exe') @((Join-Path $Script:PdfToolsDir 'poppler'))
    }
}

function Install-PdfTools {
    Write-Step 'Installing PdfHandler prerequisites (Ghostscript, ImageMagick, PDF metadata tools)...'
    $ghostDir = Join-Path $Script:PdfToolsDir 'ghostscript'
    $imageDir = Join-Path $Script:PdfToolsDir 'imagemagick'
    $popplerDir = Join-Path $Script:PdfToolsDir 'poppler'
    New-Item -ItemType Directory -Force -Path $Script:PdfToolsDir | Out-Null
    $paths = Get-PdfToolPaths

    if (-not $paths.Ghostscript) {
        $installer = Join-Path $Script:DownloadDir (Split-Path $GhostscriptUrl -Leaf)
        Get-RemoteFile -Url $GhostscriptUrl -Destination $installer -VendorPageOnFailure 'https://ghostscript.com/releases/gsdnld.html'
        New-Item -ItemType Directory -Force -Path $ghostDir | Out-Null
        $proc = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$ghostDir") -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "Ghostscript installer failed with exit code $($proc.ExitCode)." }
    }
    if (-not $paths.ImageMagick) {
        if ($ImageMagickZipUrl) {
            $archive = Join-Path $Script:DownloadDir (Split-Path $ImageMagickZipUrl -Leaf)
            Get-RemoteFile -Url $ImageMagickZipUrl -Destination $archive -VendorPageOnFailure 'https://imagemagick.org/download/'
            Expand-ToDir -ZipPath $archive -TargetDir $imageDir
        } else {
            $installer = Join-Path $Script:DownloadDir (Split-Path $ImageMagickUrl -Leaf)
            Get-RemoteFile -Url $ImageMagickUrl -Destination $installer -VendorPageOnFailure 'https://imagemagick.org/download/'
            New-Item -ItemType Directory -Force -Path $imageDir | Out-Null
            $proc = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT', '/NORESTART', "/DIR=$imageDir") -Wait -PassThru
            if ($proc.ExitCode -ne 0) { throw "ImageMagick installer failed with exit code $($proc.ExitCode)." }
        }
    }
    if (-not $paths.PdfInfo -or -not $paths.PdfToText) {
        $metadataUrl = if ($PopplerZipUrl) { $PopplerZipUrl } else { $PdfMetadataToolsZipUrl }
        $archive = Join-Path $Script:DownloadDir (Split-Path $metadataUrl -Leaf)
        Get-RemoteFile -Url $metadataUrl -Destination $archive -VendorPageOnFailure 'https://www.xpdfreader.com/download.html'
        Expand-ToDir -ZipPath $archive -TargetDir $popplerDir
    }

    $paths = Get-PdfToolPaths
    $missing = @(
        if (-not $paths.Ghostscript) { 'Ghostscript (gswin64c)' }
        if (-not $paths.ImageMagick) { 'ImageMagick (magick/convert)' }
        if (-not $paths.PdfInfo) { 'Poppler pdfinfo' }
        if (-not $paths.PdfToText) { 'Poppler pdftotext' }
    )
    if ($missing) { throw "PdfHandler prerequisites were not found after installation: $($missing -join ', ')." }
    Write-Note "PdfHandler tools ready under $Script:PdfToolsDir (Xpdf metadata tools by default)."
}
