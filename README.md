# mediawiki-provision

One-click PowerShell 7 script that provisions a complete, self-hosted MediaWiki
instance on a vanilla Windows machine (tested against Windows Server 2016) using
only native binaries — no Chocolatey, no Docker, no IIS. It can also fully tear
itself down.

## What it installs

- **Apache** (Apache Lounge build) + **mod_fcgid**, serving PHP via FastCGI
- **PHP 8.2** with OPcache + APCu tuned for MediaWiki
- **MySQL 8.4** (zip install, registered as a Windows service)
- **MediaWiki** (`REL1_43`) with caching/perf best practices (`CACHE_ACCEL`/APCu,
  file cache for anonymous views, gzip, ResourceLoader max-age tuning)
- A curated "vanilla plus" extension set: ParserFunctions, Scribunto, Cite,
  CategoryTree, InputBox, Interwiki, Nuke, RenameUser, ConfirmEdit, WikiEditor,
  VisualEditor, PageForms, ReplaceText, CodeMirror, TemplateData,
  TemplateWizard, LabeledSectionTransclusion, AbuseFilter, CheckUser, Math,
  and SemanticMediaWiki (SyntaxHighlight_GeSHi is added automatically if a
  Python interpreter is found on `PATH`)
- File uploads enabled with correct directory permissions

Everything the script creates (Apache, PHP, MySQL, the wiki, cache, logs,
download cache) lives under one root folder (`C:\MediaWikiStack` by default)
so the whole install can be backed up or wiped as a unit.

## Usage

```powershell
# Provision everything and start the wiki
.\provision-mediawiki.ps1 -Action Up

# Check status
.\provision-mediawiki.ps1 -Action Status

# Tear down (stops services, removes anything this script created, deletes
# the install root)
.\provision-mediawiki.ps1 -Action Down

# Keep data/services, just stop them
.\provision-mediawiki.ps1 -Action Down -KeepData
```

Credentials (wiki admin, DB root, DB app user) are written to
`<InstallRoot>\_provisioning\credentials.generated.txt` and locked down to the
invoking user via `icacls`.

### Safety: pre-existing Apache/MySQL

If a Windows service already exists with the same name the script would use
(`MediaWikiApache` / `MediaWikiMySQL`), the script halts with a confirmation
prompt rather than silently modifying it. Pass `-Force` to override. Down only
ever uninstalls/removes a service or the install root if this script is the
one that created it (tracked in `_provisioning\install-state.json`).

### Key parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-InstallRoot` | `C:\MediaWikiStack` | Root folder for everything |
| `-HttpPort` | `8080` | Apache listen port |
| `-DbPort` | `3306` | MySQL port |
| `-MwBranch` | `REL1_43` | MediaWiki core/extension branch |
| `-Environment` | `Dev` | `Dev` or `Prod` (toggles OPcache timestamp validation, exception detail) |
| `-Force` | | Override pre-existing Apache/MySQL service checks |
| `-KeepData` | | On `Down`, stop services without deleting anything |

Vendor download URLs (Apache Lounge, PHP, APCu, MySQL) are pinned to specific
versions via `-ApacheZipUrl`/`-PhpZipUrl`/etc. parameters — override these if
a vendor's file has moved.

## Requirements

- Windows with PowerShell 7+
- Administrator privileges
- Internet access (downloads Apache, PHP, MySQL, MediaWiki core/extensions,
  Composer)
