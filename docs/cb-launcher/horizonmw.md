# HorizonMW

## Sources

| Source | What it holds |
| --- | --- |
| [HorizonMW/HorizonMW-Client](https://github.com/HorizonMW/HorizonMW-Client) | Source code, GPL-3.0, based on AuroraMod's h1-mod. Last push October 2024. **No GitHub releases.** |
| `CBServers/updater/updater/h2m.json` | Two files: `d3d11.dll` (110,592 bytes) and `h2m-mod-cb.exe` (1,501,696 bytes). Neither matches any published HorizonMW build |
| CB game-content manifest `manifest/hmw.json` (folder `h2m`) | The HorizonMW files CB distributes as game content. Not fetched |

## Requirements and layout

- The README: "You must legally own Call of Duty: Modern Warfare Remastered to run this
  mod. Cracked/Pirated versions of the game are NOT supported."
- Base game: MWR (Steam app 393080); CB validates the folder by `h1_mp64_ship.exe`.
- Executable `hmw-mod.exe`, name argument `+set name`; CB removes a leftover
  `d3d11.dll` at launch ("CB Extension retired").
- Build: `generate.bat` (premake5, vs2022), then `build\h1-mod.sln`.
- The credits list "h2m-mod - ported assets/maps": HorizonMW carries maps ported from
  another game, which is game content rather than client code.

## Integration status

Not installable by the installer. HorizonMW publishes no client builds, and the only
downloadable copy is CB's game-content package. The Games page shows the card with
this reason and a button that opens the official repository, where the client can be
built from source by players who own MWR.
