# Not downloaded by the installer

Each item, the evidence, and the legitimate route for the player.

| Item | Why not | Legitimate route |
| --- | --- | --- |
| Full game files from CB's CDN (`cdn-*.cbservers.*/<game>/`) | No distribution right documented; CB's own terms say game content belongs to its owners and its FAQ says no ownership is needed (quotes in [provenance.md](provenance.md)) | Install the game from Steam (or Battle.net for BO4, MW2CR) |
| `BlackOps3.exe` (from `boiii.json`) | Copy of the game's own executable | The player's own copy; **Verify integrity of game files** in Steam if it is missing or a different build |
| `BlackOps4.exe` and BO4 LPC files (from CB's `project-bo4.json`) | Copies of the game's own executable and data | Not downloaded by the installer. Shield's official launcher, which the installer sets up in the game folder, fetches what Project BO4 needs itself; the player's own exe and LPC files are backed up first and put back by Remove |
| CB's copy of the Project BO4 support files (113 files) | Match nothing the Shield project publishes individually | Not needed: Shield's launcher downloads its own support mod and Target Range |
| CD keys in CB's launcher | Hard-coded values, no authorization | The player's own key: Steam library → game → **Manage** → **CD Key** |
| `iw3mp.exe` (iw3x, CoD4x manifests) | Copy of the game's own executable | The player's own `iw3mp.exe` (Steam's CoD4 is 1.7, which these clients use) |
| `binkw32.dll`, original `mss32.dll` (IW4x manifest) | Copies of the game's own libraries | Already in the player's MW2 folder |
| `miles32.dll` (CoD4 clients) | The game's own `mss32.dll`, renamed | Made from the player's own `mss32.dll` when its SHA-1 matches the manifest; otherwise the card asks to verify the game files |
| `t6sp-mod.dll` from CB | Matches no T6SP-Mod release | Taken from the T6SP-Mod project's own release instead |
| `iw4x-launcher.exe` (46.9 MB, `alt-launchers.json`) | Matches no published IW4x launcher build | Not needed: MW2 starts `iw4x.exe` directly |
| CB's HorizonMW files (`h2m.json`, `hmw.json`) | No upstream trace | HorizonMW's official launcher from `api.horizonmw.org`, which downloads the mod itself (see [horizonmw.md](horizonmw.md)) |
| WWII client (S2x) | No public repository or release | Not in the catalogue |
