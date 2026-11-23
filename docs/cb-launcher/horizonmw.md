# HorizonMW

## Sources

| Source | What it holds |
| --- | --- |
| [horizonmw.org/docs/installation](https://horizonmw.org/docs/installation) (served by `https://api.horizonmw.org/docs/pages/installation`) | The official installation guide |
| `https://api.horizonmw.org/downloads/latest` | The official launcher: version 2.0.0, `HMW_Launcher.zip`, 26,444,831 bytes, from `s3.horizonmw.org`. The API publishes no checksum (`"checksum": null`) |
| [HorizonMW/HorizonMW-Client](https://github.com/HorizonMW/HorizonMW-Client) | Client source code, GPL-3.0, based on AuroraMod's h1-mod. Last push October 2024. No GitHub releases |
| `CBServers/updater/updater/h2m.json` | Two files: `d3d11.dll` (110,592 bytes) and `h2m-mod-cb.exe` (1,501,696 bytes). Neither matches any published HorizonMW build |
| CB game-content manifest `manifest/hmw.json` (folder `h2m`) | The HorizonMW files CB distributes. Not fetched |

## The official launcher (2.0.0)

| File | Size | SHA-256 |
| --- | ---: | --- |
| `HMW_Launcher.zip` | 26,444,831 | `ac366929246e0d8a97ea62e094c3661aa673f3835f1e8a2a01ce00904bcf9b94` |
| `HMW Launcher.exe` | 45,439,936 | `acc4ebe3e829741fd7f91e08db33687fddf311bb5bd6513dd6f95e1aa59ac289` |
| `HMW Updater.exe` | 3,575,744 | `a7a2e6d41e025a51564f1e5d9bb94c7378302fed568854b94eff801f3a2fe10b` |
| `av_libglesv2.dll` | 4,440,576 | `caff1be1faee32f7c5bfba9162ee617c347aad40772caa9a1aff794e3a191420` |
| `libHarfBuzzSharp.dll` | 1,607,208 | `a54cfda99ffb965d4daa307c381763051ee638b629bfc0f424feb7a8046a7e36` |
| `libSkiaSharp.dll` | 9,414,216 | `9a0d95e8caaa852c70d085af6a40a744242172ad9ea3fd6bc7599875a8a1dbcd` |
| `version.txt` (`2.0.0`) | 8 | `6d2c7d9bfcc2a2f40f75dbe57096bc8dd8c65511ed9dbe58abd08996f4618ff0` |

## The official guide, step by step, and what the installer does

| Guide | Installer |
| --- | --- |
| Install the Visual C++ runtimes | Checks for the Visual C++ 2015-2022 x64 runtime and gives Microsoft's link when it is missing |
| Own MWR on Steam with Multiplayer installed | The card finds MWR (app 393080) by `h1_mp64_ship.exe` |
| Download the launcher from the download page | Downloads the version the API names (2.0.0 is pinned by SHA-256) |
| Extract it into its own folder, not the game folder | `%LOCALAPPDATA%\HorizonMW\Launcher` |
| Run `HMW Launcher.exe` | Opens it after installing; **Play: HMW Launcher** opens it again |
| Settings > Select Install Directory > the MWR folder | The MWR folder is copied to the clipboard to paste there |
| Verify game files, then Reverify | Done in the launcher (it downloads the mod into the MWR folder) |
| Play, or run `hmw-mod.exe` | **Play** starts `hmw-mod.exe` with `+set name <name>` |

**Updates.** Check for updates compares the installed launcher version with the API.
A new version is downloaded the same way, checked against the size the API reports
(and its checksum, if the API publishes one). The launcher also has its own updater.

**Remove** deletes the launcher. The installer recorded the MWR folder's file list
when it installed the launcher, so it can list exactly what the launcher added there
(the mod), and it asks before deleting those files. `players2` (MWR's settings) and
other clients' files are never touched.

## Requirements and layout

- The client README: "You must legally own Call of Duty: Modern Warfare Remastered to
  run this mod. Cracked/Pirated versions of the game are NOT supported."
- Base game: MWR (Steam app 393080); CB validates the folder by `h1_mp64_ship.exe`.
- Executable `hmw-mod.exe`, name argument `+set name`. CB removes a leftover
  `d3d11.dll` at launch ("CB Extension retired").
- The source in `C:\Projects\HorizonMW-Client` builds with `generate.bat` (premake5,
  vs2022), then `build\h1-mod.sln`. Its client code talks to `ms.s2mod.to` (master
  server, `src/client/tcp/hmw_tcp_utils.cpp`).
