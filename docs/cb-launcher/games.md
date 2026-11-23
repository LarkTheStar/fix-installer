# Games, clients and launch arguments

From `src/launcher/game_config.cpp` in `CBServers/cb-launcher` (identifiers, executables,
modes, arguments, required files) and the Steam store (app IDs, each confirmed by its
store page in November 2026). "Client" is the community client the installer uses;
its status comes from [manifests.md](manifests.md).

## Overview

| Game | CB id | Steam app ID | Files that mark a valid folder | Clients (installer status) |
| --- | --- | --- | --- | --- |
| Call of Duty 4 | `cod4x` | 7940 | `binkw32.dll`, `iw3mp.exe`, `iw3sp.exe` | iw3x (MP, CB's default), CoD4x (MP), IW3SP-Mod (campaign) |
| World at War | `t4` | 10090 | `binkw32.dll`, `CoDWaW.exe`, `CoDWaWmp.exe` | Plutonium |
| Modern Warfare 2 | `iw4x` | 10180 | `binkw32.dll`, `iw4mp.exe`, `iw4sp.exe` | IW4x (MP), AlterWare (campaign, Spec Ops) |
| Black Ops | `t5` | 42700 | `binkw32.dll`, `BlackOps.exe`, `BlackOpsMP.exe` | Plutonium |
| Black Ops II | `t6` | 202970 | `binkw32.dll`, `t6mp.exe`, `t6zm.exe`, `t6sp.exe` | Plutonium (MP, Zombies), T6SP-Mod (campaign) |
| Modern Warfare 3 | `iw5` | 42680 | `binkw32.dll`, `iw5mp.exe`, `iw5sp.exe` | Plutonium (MP), AlterWare (campaign, Spec Ops) |
| Ghosts | `iw6x` | 209160 | `iw6mp64_ship.exe`, `iw6sp64_ship.exe` | IW6x |
| Advanced Warfare | `s1x` | 209650 | `s1_sp64_ship.exe`, `s1_mp64_ship.exe` | S1x |
| Black Ops III | `boiii` | 311210 | `BlackOps3.exe` | BOIII (runs the player's own `BlackOps3.exe`) |
| Infinite Warfare | `iw7-mod` | 292730 | `iw7_ship.exe` | IW7-Mod |
| MW Remastered | `h1-mod` | 393080 | `h1_sp64_ship.exe`, `h1_mp64_ship.exe` | H1-Mod (CB's build or AuroraMod's own release) |
| MW2 Campaign Remastered | `mw2r` | not on Steam (folder picker) | `MW2CR.exe`, `MW2 Campaign Remastered Launcher.exe` | H2-Mod |
| Black Ops 4 | `bo4` | not on Steam (Battle.net; folder picker) | `BlackOps4.exe`, `BlackOps4_boot.exe`, `Black Ops 4 Launcher.exe` | Project BO4: Shield's official launcher, which downloads the client itself |
| HorizonMW | `hmw-mod` | uses MWR (393080) | `h1_mp64_ship.exe` | HorizonMW's official launcher (see [horizonmw.md](horizonmw.md)) |

The Steam store returns no page for app IDs 42690, 42750, 10190, 42710, 202990 and
212910 (separate multiplayer/server packages), so the installer only uses the IDs above.

## Modes and exact command lines

`<name>` is the player name, cleaned and cut to 16 characters, added with the game's
name argument when it has one.

| Game | Mode | Executable (game folder unless noted) | Arguments |
| --- | --- | --- | --- |
| CoD4 | MP | `iw3mp.exe` (with iw3x or CoD4x installed) | `+set name <name>` |
| CoD4 | SP | `iw3sp_mod.exe` | `+set iw3sp_auto_update 0` `+set name <name>` |
| WaW | SP / MP / ZM | `%LOCALAPPDATA%\Plutonium\bin\plutonium-launcher-win32.exe` | `plutonium://play/t4sp` / `t4mp` / `t4sp` |
| BO1 | SP / MP / ZM | Plutonium launcher | `plutonium://play/t5sp` / `t5mp` / `t5sp` |
| MW2 | MP | `iw4x.exe` | `+set name <name>` |
| MW2 | SP / Spec Ops | `alterware-launcher.exe` | `iw4x-sp --skip-launcher-update` |
| BO2 | SP | `T6SP-Mod.exe` | none |
| BO2 | MP / ZM | Plutonium launcher | `plutonium://play/t6mp` / `t6zm` |
| MW3 | MP | Plutonium launcher | `plutonium://play/iw5mp` |
| MW3 | SP / Spec Ops | `alterware-launcher.exe` | `iw5-mod --skip-launcher-update --pass "-singleplayer"` |
| Ghosts | SP / MP | `iw6x.exe` | `-noupdate -singleplayer` / `-noupdate -multiplayer` `+set name <name>` |
| AW | SP / MP / ZM / Survival | `s1x.exe` | `-noupdate` plus `-singleplayer` / `-multiplayer` / `-zombies` / `-survival` `+set name <name>` |
| BO3 | Play (MP and Zombies share one command line) | `boiii.exe` | `-launch -noupdate` `-name <name>` |
| MWR | SP / MP | `h1-mod.exe` | `-noupdate -singleplayer` / `-noupdate -multiplayer` `+set name <name>` |
| IW | Play (modes are chosen in the game) | `iw7-mod.exe` | `-noupdate` `+set name <name>` |
| MW2CR | SP | `h2-mod.exe` | `-singleplayer +set cg_auto_update 0` |

Optional CB launch flags the installer does not turn on by default: BO3 `-nointro`,
`-unsafe-lua`, `-allowproxydlls`, `-logfile`, `-nosteam`; MWR `-nodriverprofile`,
`-allow_root_io`, `-nosteam`; IW `-nointro`, `-d3d12`, `-allow_root_io`.

## Where client files go

| Client | Game folder | Elsewhere |
| --- | --- | --- |
| iw3x, CoD4x | files marked `game` in the manifest | files marked `appdata` → `%LOCALAPPDATA%\CallofDuty4MW` |
| IW3SP-Mod | `iw3sp_data\`, the exe and DLLs | `bin\launcher.dll` → `%LOCALAPPDATA%\CallofDuty4MW` |
| IW4x, IW6x, S1x, Plutonium bootstrapper, AlterWare, T6SP-Mod | everything | none |
| BOIII | `boiii.exe` | `data\` → `%LOCALAPPDATA%\boiii` |
| H1-Mod (CB's build or AuroraMod's own release) | `h1-mod.exe` | `cdata\` → `%LOCALAPPDATA%\h1-mod` |
| IW7-Mod | `iw7-mod.exe` | `cdata\` → `%LOCALAPPDATA%\auroramod\iw7-mod` |
| H2-Mod | `h2-mod.exe` | `cdata\` → `%LOCALAPPDATA%\h2-mod` |
| Plutonium | `plutonium.exe` | Plutonium installs itself to `%LOCALAPPDATA%\Plutonium` |

## Version checks

CB lists one changed file per Steam depot after the 2026 updates
(`version_check_files`), for example MW2 `iw4mp.exe`, `iw4sp.exe`,
`zone/english/patch_mp.ff`; Ghosts `iw6mp64_ship.exe`, `iw6sp64_ship.exe`,
`zone/patch_common_mp.ff`. The installer reports the version and size of the main
executable before every Play so a game/client mismatch is visible.
