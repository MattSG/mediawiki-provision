@{
    # Core action and layout
    Action = 'Up'
    InstallRoot = 'C:\MediaWikiStack'
    SiteName = 'DevelopmentWiki'
    WikiAdminUser = 'Admin'
    WikiAdminPassword = $null
    HttpPort = 8080
    Environment = 'Dev'
    KeepData = $false
    Force = $false
    SeedDevelopmentContent = $true
    InstallPdfTools = $false

    # Database: set UseExternalDb = $true to use an existing server.
    DbPort = 3306
    DbRootPassword = $null
    DbUserPassword = $null
    UseExternalDb = $false
    DbHost = '127.0.0.1'
    ExternalDbAdminUser = 'root'
    ExternalDbAdminPassword = $null
    # Required for external Prod DBs; use the wiki host's exact MySQL account host where possible.
    ExternalDbUserHost = $null

    # HTTPS: provide all three values, or leave them null for HTTP.
    PublicUrl = $null
    CertPath = $null
    CertKeyPath = $null

    # Optional logo and download proxy.
    LogoPath = $null
    ProxyUrl = $null
    ProxyUseDefaultCredentials = $false
    # Password must be an encrypted ConvertFrom-SecureString value.
    # ProxyCredential = @{ UserName = 'DOMAIN\user'; Password = '<encrypted value>' }
    ProxyCredential = $null

    # Entra ID SSO. EntraClientSecret must be an encrypted ConvertFrom-SecureString value.
    EnableEntraSso = $false
    DisableEntraSso = $false
    EntraTenantId = $null
    EntraClientId = $null
    EntraClientSecret = $null

    # Scheduled maintenance.
    EnableJobRunner = $false
    DisableJobRunner = $false
    JobRunnerIntervalMinutes = 5
    EnableLogRotation = $false
    DisableLogRotation = $false
    EnableBackups = $false
    DisableBackups = $false
    BackupPath = $null
    BackupRetentionDays = 14

    # MediaWiki branch and direct-download overrides.
    MwBranch = 'REL1_43'
    ApacheZipUrl = 'https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.66-251206-Win64-VS17.zip'
    ModFcgidZipUrl = 'https://www.apachelounge.com/download/VS17/modules/mod_fcgid-2.3.10-win64-VS17.zip'
    PhpZipUrl = 'https://downloads.php.net/~windows/releases/php-8.3.33-nts-Win32-vs16-x64.zip'
    ApcuZipUrl = 'https://downloads.php.net/~windows/pecl/releases/apcu/5.1.28/php_apcu-5.1.28-8.3-nts-vs16-x64.zip'
    MySqlZipUrl = 'https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.11-winx64.zip'
    PythonZipUrl = 'https://www.python.org/ftp/python/3.14.7/python-3.14.7-embed-amd64.zip'
    ComposerPharUrl = 'https://getcomposer.org/composer.phar'
    CaBundleUrl = 'https://curl.se/ca/cacert.pem'
    GhostscriptUrl = 'https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10071/gs10071w64.exe'
    ImageMagickUrl = 'https://download.imagemagick.org/archive/binaries/ImageMagick-7.1.2-31-Q16-x64-static.exe'
    # Legacy override name; use this only for an approved portable archive mirror.
    ImageMagickZipUrl = $null
    PdfMetadataToolsZipUrl = 'https://dl.xpdfreader.com/xpdf-tools-win-4.06.zip'
    # Legacy override name; use this only when an approved Poppler Windows mirror is required.
    PopplerZipUrl = $null
}
