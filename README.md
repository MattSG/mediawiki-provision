# mediawiki-provision

One-click PowerShell 7 script that provisions a complete, self-hosted MediaWiki
instance on a vanilla Windows machine (tested against Windows Server 2016) using
only native binaries — no Chocolatey, no Docker, no IIS. It can also fully tear
itself down.

## Layout

`provision-mediawiki.ps1` is a thin entry point: parameter definitions, path
layout, the curated extension/skin lists, and dispatch. It dot-sources the
actual implementation from `lib/`, one file per concern:

| File | Responsibility |
|---|---|
| `lib/common.ps1` | Logging, state persistence, credentials, admin/pre-existing-infra checks, generic download/extract helpers |
| `lib/wizard.ps1` | Interactive first-install setup wizard |
| `lib/sso.ps1` | Entra ID SSO config persistence |
| `lib/apache.ps1` | Apache install + config (incl. HTTPS vhost) |
| `lib/php.ps1` | PHP install + php.ini tuning |
| `lib/mysql.ps1` | MySQL install, or `-UseExternalDb` connection |
| `lib/python.ps1` | Python (embeddable) for SyntaxHighlight |
| `lib/pdf.ps1` | Optional Ghostscript/ImageMagick/Poppler installation for PdfHandler |
| `lib/mediawiki.ps1` | Core, extensions/skins, installer, caching/perf settings |
| `lib/scheduledtasks.ps1` | Optional job-runner/log-rotation/backup Task Scheduler tasks |
| `lib/orchestration.ps1` | `Invoke-Up` / `Invoke-Down` / `Invoke-Status` / `Invoke-Backup` |

`setup-local-https-test.ps1` is a separate, standalone script for local HTTPS
testing (see below) — it never runs as part of `Up`/`Down`.

## What it installs

- **Apache** (Apache Lounge build) + **mod_fcgid**, serving PHP via FastCGI
- **PHP 8.3** with OPcache + APCu tuned for MediaWiki, plus a CA certificate
  bundle so PHP's curl/openssl extensions can verify outbound HTTPS calls
  (the windows.php.net zip ships none — needed for SSO, and any extension
  that calls out over HTTPS)
- **MySQL 8.4** (zip install, registered as a Windows service) — or point at
  an existing MySQL instance with `-UseExternalDb`
- **Python** (official embeddable zip, no installer/PATH change) purely so
  SyntaxHighlight_GeSHi's bundled Pygments zipapp has an interpreter to run
- **PdfHandler** requires Ghostscript, ImageMagick, and Poppler (`pdfinfo` and
  `pdftotext`). Pass `-InstallPdfTools` (or set `InstallPdfTools = $true` in
  the config file) to install pinned Windows builds under `pdf-tools\`; the
  generated PdfHandler settings use absolute paths, so no machine-wide `PATH`
  change is required. The PDF URL parameters also accept local mirrors.
- **MediaWiki** (`REL1_43`) with caching/perf best practices (`CACHE_ACCEL`/APCu,
  file cache for anonymous views, gzip, ResourceLoader max-age tuning)
- The curated development/documentation extension set is defined above
  `$Script:ZipExtensions` in `provision-mediawiki.ps1`; SemanticMediaWiki,
  SemanticResultFormats, SemanticBreadcrumbLinks, and Mermaid are installed via
  Composer or their upstream GitHub repository.
- File uploads enabled with correct directory permissions
- Optional logo (`-LogoPath`) and Entra ID SSO login (see below)

Everything the script creates (Apache, PHP, MySQL, Python, the wiki, cache,
logs, download cache) lives under one root folder (`C:\MediaWikiStack` by
default) so the whole install can be backed up or wiped as a unit. Both
Windows services are set to start automatically on boot.

## Usage

```powershell
# Provision everything and start the wiki - prompts for site name/admin
# user/logo/SSO on first install (see Interactive setup below)
.\provision-mediawiki.ps1 -Action Up

# Unattended - skips the wizard, pass everything you want via parameters
.\provision-mediawiki.ps1 -Action Up -NonInteractive

# Config-driven - copy the example, edit it, then run without the wizard
Copy-Item .\provision.config.example.psd1 .\provision.config.psd1
.\provision-mediawiki.ps1 -ConfigPath .\provision.config.psd1

# Check status
.\provision-mediawiki.ps1 -Action Status

# Tear down (stops services, removes anything this script created, deletes
# the install root)
.\provision-mediawiki.ps1 -Action Down

# Keep data/services, just stop them
.\provision-mediawiki.ps1 -Action Down -KeepData
```

Credentials (wiki admin, DB root/app user) are written to
`<InstallRoot>\_provisioning\credentials.generated.txt`, locked down to the
invoking user via `icacls`. They're written as soon as they're known (not
just at the end) so a run that fails partway through still leaves what's
actually in effect discoverable on the next re-run.

### Config file

`provision.config.example.psd1` contains every configurable option. Copy it to
`provision.config.psd1`, edit the values, and pass `-ConfigPath`. Config values
are used unless the same option is supplied on the command line, so a one-off
override such as `-Action Status` still wins. A config-driven run skips both
the setup wizard and per-step confirmation prompts. Keep passwords and SSO
secrets in a local config file and do not commit it.

For `EntraClientSecret` and `ProxyCredential.Password`, store the encrypted
output of `ConvertFrom-SecureString` rather than plaintext. The encrypted value
can normally only be decrypted by the same Windows account on the same machine.

### Interactive setup

Running `.\provision-mediawiki.ps1 -Action Up` with no other parameters is a
genuinely complete one-shot setup: on a first install (no `LocalSettings.php`
yet) it asks whether this server has direct internet access (and if not,
whether to use a corporate proxy and/or local paths/network shares for each
download - see Restricted/offline servers below), the install folder, HTTP
port, whether to use an existing MySQL instance instead of installing one
(and its own port if not), the wiki name/title, admin username, an optional
logo, Dev/Prod, whether to set up HTTPS right now (offering to generate and
locally trust a self-signed certificate on the spot if you don't have a real
one yet), Entra ID SSO, and each of the optional production tasks below -
then shows a summary of everything it's about to do and waits for you to
confirm before touching anything. Anything you pass explicitly via
parameters isn't asked again. `-NonInteractive` or `-Force` skip the wizard
and summary entirely.

### Per-step confirmation

Beyond the one-time upfront summary, both `Up` and `Down` pause before each
individual step (installing Apache, writing php.ini, installing extensions,
stopping a service, deleting the install root, etc.), printing a one-line
summary of exactly what it's about to do and asking:

```
--> Install/verify Apache + mod_fcgid binaries.
    Proceed? [Y]es / [n]o (skip this step) / [q]uit
```

`Y` (or Enter) runs the step, `n` skips just that one step and continues to
the next, `q` aborts the whole run immediately. Like the wizard, this is
skipped entirely under `-NonInteractive`/`-Force` so unattended/CI runs never
block.

### Safety: pre-existing Apache/MySQL

Two independent checks, both interactive by default (skip with `-Force` /
`-NonInteractive`):

1. **Generic detection** (`Test-PreexistingInfrastructure`, runs after the
   wizard): any Apache- or MySQL-*like* service already on the machine, or
   `HttpPort`/`DbPort`/443 already in use by something else - genuinely
   likely on a real server, since those are exactly the defaults MySQL/IIS/
   another web server would already be using. Gives real choices rather
   than just continue-or-abort: pick a different port on the spot, point
   the wiki at the existing MySQL instead of installing a separate one
   (switches to `-UseExternalDb` interactively, asking for its credentials),
   or abort to deal with it yourself first. A same-named-but-unrelated
   service (not an actual port clash) is safe to continue past as-is.
2. **Exact-name collision** (`Confirm-Override`): if a service already exists
   with the *exact* name this script would use (`MediaWikiApache` /
   `MediaWikiMySQL`), it halts for explicit confirmation before touching it.

`Down` only ever stops, uninstalls, or deletes anything Apache/MySQL-related
if this script is the one that created it (tracked in
`_provisioning\install-state.json`) — a pre-existing MySQL pointed at via
`-UseExternalDb`, or a service this script found already running under its
expected name, is never stopped, removed, or has any database/user dropped
from it. Only `Down`'s deletion of the install root itself (still gated the
same way) removes this install's own data.

### HTTPS

Pass `-PublicUrl https://your.host`, `-CertPath`, and `-CertKeyPath` (PEM
format) together to serve over 443 with a real certificate. Plain HTTP then
301-redirects to the HTTPS URL instead of serving content over both, and the
HTTPS vhost sends `Strict-Transport-Security`. For local testing without a
real certificate, use the companion script:

```powershell
.\setup-local-https-test.ps1                      # generates + trusts a self-signed
                                                   # cert for wiki.local.test, adds a
                                                   # hosts entry, prints the exact args
.\provision-mediawiki.ps1 -Environment Prod -PublicUrl https://wiki.local.test -CertPath ... -CertKeyPath ...
.\setup-local-https-test.ps1 -Remove              # undo (hosts entry + trust store)
```

### External database

`-UseExternalDb -DbHost <host> -ExternalDbAdminUser <user> -ExternalDbAdminPassword <pass>`
points the wiki at an existing MySQL instance instead of installing one —
requires a `mysql` client on `PATH`. `Down` never touches it at all (no
stop, no database/user drop) - the wiki's database/user are left in place
for you to remove manually if you want them gone. For a remote production
database, also set `-ExternalDbUserHost` to the wiki server's exact MySQL
account host; omitting it is rejected to avoid granting the wiki user access
from every host.

### Entra ID (Azure AD) SSO

`-EnableEntraSso -EntraTenantId <tenant> -EntraClientId <app-id> -EntraClientSecret <secure-string>`
installs PluggableAuth + OpenIDConnect and adds a named "Entra ID" login
button alongside the standard username/password form (local login stays
available so a misconfigured tenant can't lock you out). Settings persist
across re-runs like DB passwords do — use `-DisableEntraSso` to turn it back
off.

On the Entra side, register an App Registration with:
- Redirect URI (Web): `<PublicUrl or http://localhost:HttpPort>/index.php?title=Special:PluggableAuthLogin`
  (query-string form — this install has no short-URL rewrite, so verify
  against the exact URL MediaWiki generates if you change that)
- A client secret under Certificates & secrets
- Default openid/profile/email delegated permissions (granted automatically)

### Production QoL: job runner, log rotation, backups

Three independent, optional Task Scheduler tasks, all under one folder
(`\MediaWikiStack\`), all prompted for interactively on first install
(default yes for job runner/log rotation, default no for backups), all
reversible later with the matching `-Disable*` switch:

- `-EnableJobRunner` (+ `-JobRunnerIntervalMinutes`, default 5) — runs
  `maintenance/run.php runJobs` on a schedule instead of relying on lumpy
  request-triggered execution (matters for Echo notifications and other
  deferred work).
- `-EnableLogRotation` — daily task that archives Apache/PHP/MySQL logs over
  20MB and deletes archives older than 30 days.
- `-EnableBackups` (+ `-BackupPath`, `-BackupRetentionDays`, default 14) —
  daily DB dump (`mysqldump`) + `LocalSettings.php`/`images` archive. Run one
  on demand with `.\provision-mediawiki.ps1 -Action Backup`. For
  `-UseExternalDb`, automated backups need a `mysqldump` client on `PATH`;
  the external DB admin password isn't stored in the scheduled task itself
  (it'd be plaintext-visible in Task Scheduler's UI), so wire that up
  separately if you need unattended external-DB backups.

These tasks run as `SYSTEM`, which is why `credentials.generated.txt` is
readable by `SYSTEM` in addition to the invoking user — the backup task
needs the DB password to run `mysqldump` unattended.

### Key parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-InstallRoot` | `C:\MediaWikiStack` | Root folder for everything |
| `-HttpPort` | `8080` | Apache listen port |
| `-DbPort` | `3306` | MySQL port |
| `-MwBranch` | `REL1_43` | MediaWiki core/extension branch |
| `-Environment` | `Dev` | `Dev` or `Prod` (toggles OPcache timestamp validation, exception detail) |
| `-LogoPath` | | Local image file to use as the wiki logo |
| `-Force` | | Override pre-existing-service checks (both kinds above) |
| `-NonInteractive` | | Skip both the wizard and pre-existing-service prompts |
| `-KeepData` | | On `Down`, stop services without deleting anything |
| `-ExternalDbUserHost` | | Exact MySQL account host for a remote external DB in Prod |
| `-InstallPdfTools` | off | Install Ghostscript, ImageMagick, and Poppler for PdfHandler under `InstallRoot` |

Vendor download URLs (Apache Lounge, PHP, APCu, MySQL, Python, Composer, the
CA bundle, and PdfHandler tools) are pinned to specific versions via their URL
parameters — override these if a vendor's file has moved or use local mirrors.

### Restricted/offline servers: proxy and local mirrors

- `-ProxyUrl <url>` (+ `-ProxyUseDefaultCredentials` or `-ProxyCredential`)
  routes every download this script makes through a corporate proxy.
- Any of the `-*Url` parameters above also accepts a local path or UNC share
  (e.g. `-PythonZipUrl \\fileserver\mirrors\python-embed.zip`) instead of a
  URL, for a server with no internet access at all - the file is copied, not
  downloaded.
- The ~17 extension/skin zips and MediaWiki core itself come from GitHub and
  aren't individually overridable that way, but `Get-RemoteFile` always skips
  downloading anything already present at its expected cache path
  (`<InstallRoot>\_provisioning\downloads\<repo>-<branch>.zip`) - pre-stage
  files there with matching names for a fully offline extension set.

### Restoring from a backup

There's no automated restore (backups are just a DB dump + a files archive -
see above) - to restore one:
```powershell
# 1. Stop the wiki so nothing writes to the DB mid-restore
Stop-Service MediaWikiApache

# 2. Restore the database (adjust paths/credentials to your backup)
& 'C:\MediaWikiStack\mysql\bin\mysql.exe' -uroot -p'<DB root pass>' mediawiki `
    -e "source C:\MediaWikiStack\_provisioning\backups\db-<timestamp>.sql"

# 3. Restore LocalSettings.php / images from the matching files-<timestamp>.zip
Expand-Archive 'C:\MediaWikiStack\_provisioning\backups\files-<timestamp>.zip' `
    -DestinationPath 'C:\MediaWikiStack\www' -Force

Start-Service MediaWikiApache
```

## Requirements

- Windows with PowerShell 7+
- Administrator privileges
- Internet access (downloads Apache, PHP, MySQL, Python, MediaWiki core/
  extensions, Composer, a CA bundle) - or see the proxy/local-mirror options
  above for a server without direct internet access

### Before running on a locked-down/corporate server

None of these are things the script can detect or work around itself - worth
checking first if the first run fails in a way that doesn't look like a
script bug:

- **PowerShell execution policy**: if running the script is blocked outright,
  invoke it with `pwsh -ExecutionPolicy Bypass -File provision-mediawiki.ps1
  ...` rather than changing the machine-wide policy.
- **Antivirus/EDR**: some security software quarantines freshly-downloaded/
  extracted executables (httpd.exe, mysqld.exe, php-cgi.exe) or blocks
  outbound connections from processes it hasn't seen before. If a binary that
  was just extracted "goes missing" or a service won't start with no clear
  error, check quarantine/exclusion logs before assuming the script broke it.
- **Outbound network policy**: beyond the proxy support above, some
  environments allow only specific destination domains - see the download
  sources listed in Requirements above if downloads are blocked entirely.
