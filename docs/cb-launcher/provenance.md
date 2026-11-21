# Provenance and distribution status

Each resource was evaluated on its own evidence: who publishes it, under what terms,
and whether that publisher has documented the right to distribute it. Where hosting
alone is the only evidence, that is said. Checked November 2026.

## Used by the installer

| Resource | Source | Publisher and terms | Evidence |
| --- | --- | --- | --- |
| CB launcher (`cb-launcher.exe`, `data/`) | `github.com/CBServers/updater/raw/main/updater/cb-launcher/` | CB Servers, GPL-3.0 ([LICENSE](https://github.com/CBServers/cb-launcher/blob/main/LICENSE)) | Retrieved for the inventory only; not shipped with the installer |
| Client manifests `updater/*.json` | `CBServers/updater` | CB Servers, public repository | Metadata: path, size, SHA-1 per file |
| IW4x client and rawfiles (MW2) | `iw4x/iw4x-client` r5318, `iw4x/iw4x-rawfiles` v0.2.42 | IW4x project, GitHub releases | 95 of 97 CB entries match by name and size, including the contents of `release.zip` (checked from its central directory) |
| AlterWare launcher (MW2/MW3 campaign and Spec Ops) | `alterware/alterware-launcher` v0.11.6 | AlterWare, GitHub releases | SHA-1 identical to CB's copy |
| Plutonium bootstrapper (WaW, BO1, BO2, MW3) | `https://cdn.plutonium.pw/updater/plutonium.exe` | Plutonium, official distributor | SHA-1 identical to CB's copy; the installer downloads it from Plutonium directly |
| CoD4x (CoD4 multiplayer) | `callofduty4x/CoD4x_Client_pub` 21.8, `CoD4x-mss` 1.0.2, `CoD4x-launcher` 1.1.3 | CoD4x project, GitHub releases | 7 of 9 entries match by name and size |
| iw3x / CoD4R (CoD4 multiplayer) | `http://74.208.200.240/manifest.json` | iw3x project's own update server | 11 of 13 entries match by name and size |
| IW3SP-Mod (CoD4 campaign) | `https://jerryalt.codeberg.page/files.json` and CoD4x releases | IW3SP-Mod project | 28 of 29 entries match by SHA-1 or name and size |
| CoD2x (CoD2 multiplayer) | `callofduty2x/CoD2x` v1.4.6.8 | CoD2x project, GitHub releases | `mss32.dll` SHA-1 identical |
| T6SP-Mod (BO2 campaign) | `Rattpak/T6SP-Mod-Release` v1.0.0-Beta | T6SP-Mod project, GitHub releases | `T6SP-Mod.exe` matches; CB's `t6sp-mod.dll` matches no release, so the installer takes both files from the project's release instead |
| IW6x (Ghosts), S1x (AW), BOIII (BO3), H1-Mod (MWR), IW7-Mod (IW) | `CBServers/updater` | CB Servers, builds of its public GPL-3.0 forks `CBServers/iw6-mod`, `s1-mod`, `boiii`, `h1-mod`, `iw7-mod` | The forks publish source but no releases; CB is the publisher of these builds |
| H2-Mod (MW2 Campaign Remastered) | `https://h2-mod.alicent.cat/files.json` | H2-Mod project's own update server | All 69 entries match by SHA-1 |

## Not used

| Resource | Source | Evidence | Status |
| --- | --- | --- | --- |
| Full game files ("Download game") | `cdn-na/eu.cbservers.*/<game>/` | CB Terms section 5: "We are not affiliated with or endorsed by Activision, Infinity Ward, Treyarch..."; "All trademarks and game content are the property of their respective owners." Privacy policy: "Game files you install are downloaded from our CDN." FAQ: "you do not need to own the games on Steam. The launcher can download all game files directly." No license or ownership check is documented anywhere. | Not fetched. Documented from the launcher source only (see [cdn-report.md](cdn-report.md)) |
| `BlackOps3.exe`, `BlackOps4.exe` | `CBServers/updater` (Git LFS) | Copies of the games' own executables; no rights-holder authorization documented | Not fetched; the player's own file is checked instead |
| Retail executables and libraries inside client manifests (`CoDMP.exe`, `CoDUOMP.exe`, `iw3mp.exe`, `binkw32.dll`, the original `mss32.dll`/`miles32.dll`) | various manifests | Copies or patched copies of the games' own files | Not fetched; renamed copies are made from the player's own file when its SHA-1 matches |
| BO4 LPC files and Project BO4 support files | `project-bo4.json` | LPC files are BO4 game data (the Shield launcher lists them in its "game" component); the support files match nothing the Shield project publishes individually | Not fetched |
| CD keys written by the CB launcher | `src/launcher/commands/game_commands.cpp` | Hard-coded values; no authorization documented | Not used; players enter their own key |
| HorizonMW client | `h2m.json` | Two files with no upstream trace; HorizonMW publishes source only (see [horizonmw.md](horizonmw.md)) | Not fetched |
| WWII client (S2x) | `s2x.json` | No public repository or release found | Not fetched; WWII is not in the catalogue |
