# CB launcher investigation

Research into the CB Servers launcher ([cbservers.xyz](https://cbservers.xyz/),
[CBServers/cb-launcher](https://github.com/CBServers/cb-launcher), GPL-3.0) and the
public files it uses, done to add the older Call of Duty games and their community
clients to this installer.

| Document | What it covers |
| --- | --- |
| [provenance.md](provenance.md) | Every resource, where it comes from, who publishes it, and whether the installer uses it, with evidence |
| [inventory.md](inventory.md) / `inventory.json` | Every file of the published launcher: path, size, SHA-1, SHA-256, version |
| [manifests.md](manifests.md) / `audit.json` | All 25 client manifests audited file by file |
| [cod1-uo-cod2.md](cod1-uo-cod2.md) | Fresh scrape for Call of Duty, United Offensive and Call of Duty 2: their five manifests, game configuration, full-game manifests and launcher files, with nothing downloaded |
| [cdn-report.md](cdn-report.md) | Hosts, mirrors, the two manifest formats, how updates and resumes work |
| [games.md](games.md) | Every game: identifiers, Steam app IDs, executables, modes, exact launch arguments, clients |
| [languages.md](languages.md) | The launcher's language system and how it compares with this installer's |
| [executables-and-keys.md](executables-and-keys.md) | How the launcher handles `BlackOps3.exe` / `BlackOps4.exe` and the CD-key registry values |
| [horizonmw.md](horizonmw.md) | HorizonMW: sources, files, dependencies, integration status |
| [unavailable.md](unavailable.md) | What the installer does not download, why, and the legitimate route |

The two tools that produce the data can be re-run at any time:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-CbManifestAudit.ps1    # audit.json, manifests.md
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Get-CbLauncherInventory.ps1  # inventory.json, inventory.md
```
