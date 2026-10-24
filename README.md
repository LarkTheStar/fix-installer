# Call of Duty HQ Setup Utility

<div align="center">

**Made for LuaTools <3**  
*by Lark*

A PowerShell utility for installing the Call of Duty HQ fix, managing language packs, switching the active language, and restoring backed-up files.

</div>

> **Please read before running:** the installer modifies files in your Call of Duty HQ directory. Back up important files and review the script before executing it, especially if you use the one-line PowerShell command below.

## Features

- **Install Fix** — downloads the fix archive from this repository's `1.0.0` release, stages its files, and backs up replaced originals in a timestamped `og files` folder.
- **Install Language Pack** — installs any of the 13 supported language packs.
- **Remove Language Pack** — removes a tracked language while retaining files still needed by other installed packs. Original files are restored when the final language owning a file is removed.
- **Active Language Preset** — switches the existing `language=` value in `sp26\steam_settings\configs.user.ini` without reinstalling language files. English and currently installed packs are shown as choices.
- **Remove Fix / Restore Originals** — restores backed-up originals and removes files introduced by the fix, based on the selected backup and the fix archive's file list.
- **Launch `!start_sp26.bat`** — optionally starts the batch file from the Call of Duty HQ folder.
- **Split archive support** — Japanese, Korean, and Simplified Chinese are downloaded as parts and concatenated in order before extraction/staging.
- **Path and file safety checks** — validates archive paths and refuses certain unsafe destinations. The language manager tracks file ownership and checks for unexpected changes before removal.

## Requirements

- Windows with PowerShell.
- A Steam installation of **Call of Duty HQ** (Steam AppID `1938090`).
- Internet access to download the fix and language-pack release assets.
- Enough free disk space for the selected downloads and temporary staging. Japanese, Korean, and Simplified Chinese each reconstruct to a ZIP of roughly 2.2 GiB before installation, so allow additional temporary space.
- Permission to write to the selected game folder.

The script attempts to locate the Steam library automatically. You can confirm the detected folder, select among multiple detections, or enter the game directory manually.

## Run from PowerShell (IEX)

After `install.ps1` has been committed to the repository's `main` branch, run this command in PowerShell:

```powershell
irm https://raw.githubusercontent.com/LarkTheStar/fix-installer/main/install.ps1 | iex
```

This downloads the current `install.ps1` from GitHub and executes it immediately. **Only run this command if you trust the repository and have reviewed the source.** To inspect the script first, open [install.ps1](./install.ps1) in GitHub, or download it and review it in a text editor before running it.

If your default branch is not `main`, update the URL to match your branch. The file in the repository must be named `install.ps1` for the command above to work as written.

## Main menu

When the utility starts, it offers:

1. Install Fix
2. Install Language Pack
3. Remove Language Pack
4. Active Language Preset
5. Remove Fix / Restore Originals
6. Launch `!start_sp26.bat`
7. Exit

Follow the prompts and review confirmation messages before allowing changes. Close the game before installing or removing packs, or changing files the game may be using.

## Supported language packs

The script downloads these assets from the repository's `Language-1.0.0` release:

| Language | `language=` value | Archive format |
|---|---|---|
| Arabic | `arabic` | Single ZIP |
| French | `french` | Single ZIP |
| German | `german` | Single ZIP |
| Italian | `italian` | Single ZIP |
| Japanese | `japanese` | Two parts, reassembled automatically |
| Korean | `koreana` | Two parts, reassembled automatically |
| Polish | `polish` | Single ZIP |
| Portuguese (Brazil) | `brazilian` | Single ZIP |
| Russian | `russian` | Single ZIP |
| Simplified Chinese | `schinese` | Two parts, reassembled automatically |
| Spanish (Latin America) | `latam` | Single ZIP |
| Spanish (Spain) | `spanish` | Single ZIP |
| Traditional Chinese | `tchinese` | Single ZIP |

English is included with the game and is offered as an active preset; it is not downloaded as a language pack by this utility.

### How the language manager handles files

Language management state is stored under:

```text
Call of Duty HQ\language files\language-pack-manager\state.json
```

Language-related original-file backups are kept under the language manager's directory, separately from `og files`. The state file records which packs are installed and which language packs own managed paths. This allows shared files to remain while another installed pack needs them.

- Removing the currently active language switches the preset to English before removing that pack's files.
- Removing one language should retain shared files still owned by other installed packs.
- When the final language owning a file is removed, the manager restores the original file where a backup exists, or removes the file if it was introduced by the language pack.
- If the manager detects that a managed file has changed outside the utility, removal may be refused to avoid overwriting that change.
- Backups and manager state are deliberately retained for recovery. **Do not manually delete `language files\language-pack-manager` or its `state.json` while language packs are managed.**

The split language assets are raw byte chunks, not independent ZIPs. The installer concatenates them in the listed order, checks that the reconstructed archive can be opened, and then stages its files. Do not rename or reorder the release parts.

## Fix backups and removal

During fix installation, the script warns that matching files may be replaced and stores originals in a timestamped subfolder under `og files`.

Fix removal asks for confirmation and keeps the selected backup after restoration. Its selection logic looks for non-empty backup folders smaller than 20 MB and favors the oldest qualifying folder. If several backup folders exist, read the displayed path carefully before confirming. Keep backup folders until you have verified the game works as expected.

## Troubleshooting

- **Steam folder not detected:** enter the full path to the `Call of Duty HQ` folder when prompted.
- **Download fails:** confirm that your internet connection works and that the release assets are still available in this repository.
- **A language does not appear in the preset menu:** only English and packs recorded as installed by the language manager are listed. Check the install result and the manager's `state.json`.
- **Removal is refused due to an unexpected file change:** do not force-delete the file or manager state. Review the message and preserve a backup before making manual changes.
- **The game still shows the old language:** close the game, select the desired preset, confirm that the `language=` value in `sp26\steam_settings\configs.user.ini` matches the intended language, then launch the game again.

If reporting a problem, include the complete PowerShell error or output, which menu option you selected, and which language or operation was involved. Do not post personal paths or other private information unless you are comfortable sharing them.

## Testing notes

The maintainer has tested the normal install, in-game language switching, shared-file retention during removal, automatic fallback to English, final-language removal, and the split-archive installation path. Additional languages have also been tested. Unusual interruption/recovery scenarios may not all have been tested, so keep backups and report reproducible issues.

## Credits

**Made for LuaTools <3**  
**By Lark**
