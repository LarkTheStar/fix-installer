# Testing plan: every game on the Games page

Two stages. Stage A runs without any real game and is repeated after every change.
Stage B is done once per release on a PC with the real games; it is the only way to
prove a client actually starts and joins a server.

## Stage A: automatic (no real games)

| Check | Command | Covers |
| --- | --- | --- |
| Pester, Windows PowerShell 5.1 | `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1` | every install / update / remove path, release archives, launcher cleanup, CD keys, update checks |
| Pester, PowerShell 7 | `pwsh -NoProfile -File tests\Invoke-Tests.ps1` | the same |
| Window layout | `powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-Xaml.ps1` | every control the script uses exists |
| Real window | `powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-Gui.ps1` | every page opens, all 17 game cards appear, the admin hand-off works |
| Sandbox | `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Start-Sandbox.ps1 -Reset` | the real window against fake Steam, CoD4, MW2, BO2, Ghosts, MWR and BO4 folders, with real downloads |

In the sandbox window, for each fake game:

1. The card shows **Game found** (BO4: use **Change folder** and pick
   `<sandbox>\Battle.net\Call of Duty Black Ops 4`).
2. **Install** each client. It downloads and checks the real files, and the log lists
   what was downloaded, kept and made.
3. **Play** each mode. Sandbox mode prints the exact command instead of starting it.
4. **Check all for updates** reports "up to date" for each client.
5. **Remove** each client, then run `tests\Start-Sandbox.ps1 -Report`. The folder is as
   it was.

CI (`.github/workflows/tests.yml`) runs the first four on every push to `dev`.

## Stage B: real games (you play, the log tells us the rest)

Before starting: set a **Player name**. After each game, press **Save** in the
activity log and keep the `.txt`: it holds the exact commands, hashes and any error.

For every game the checks are the same:

| # | Step | Pass when |
| --- | --- | --- |
| 1 | Open the Games page | the card says **Game found** with the right folder |
| 2 | Install each client | the log ends with "is installed"; nothing in red |
| 3 | Play each mode | the game starts in that mode |
| 4 | Join a server (MP modes) | it connects and you can play a round |
| 5 | Check the name | your player name shows in the scoreboard |
| 6 | Check all for updates | "up to date" |
| 7 | Remove each client | the log ends with "was removed"; the card is back to **Game found** |
| 8 | Steam > Properties > Installed Files > Verify integrity | Steam reports nothing to re-download (Battle.net: Scan and Repair finds nothing) |

Order, from the least to the most involved:

| Order | Game | Clients / versions | Game-specific checks |
| --- | --- | --- | --- |
| 1 | Call of Duty (2003) | 1.1 (singleplayer and MP) | Install copies the 1.1 files from this project's release over the folder; both Play modes start the 1.1 exes; Remove puts the previous game files back. Also test **Change folder** on an empty folder: the card says **Folder picked**, Install fills it, and the card then says **Game found** |
| 2 | Call of Duty 4 | iw3x, CoD4x, IW3SP-Mod | install iw3x and CoD4x one at a time (they conflict); campaign via IW3SP-Mod |
| 3 | Ghosts | IW6x | campaign and MP |
| 4 | World at War, Black Ops, Black Ops II, MW3 | Plutonium | **Plutonium login** once; each mode's `plutonium://play/<id>` starts |
| 5 | Black Ops II campaign | T6SP-Mod | campaign starts without Plutonium |
| 6 | MW2, MW3 campaign | IW4x, AlterWare | Spec Ops through AlterWare |
| 7 | Advanced Warfare, Infinite Warfare, MWR | S1x, IW7-Mod, H1-Mod (CB) and H1-Mod (AuroraMod) | try both H1-Mod sources one after the other |
| 8 | Black Ops III | CodHQ BOIII (our own build, updated from our own site; data in `%LOCALAPPDATA%\boiii`) | Install downloads our `codhq-boiii.zip`, checks its pinned SHA-256, verifies all 196 files against our `boiii.json` before writing, puts `boiii.exe` in the game folder and the `data` tree in `%LOCALAPPDATA%\boiii`, then reads the install back and checks the count and every SHA-1 again; Play starts it; **Check game exe** reports whether your `BlackOps3.exe` carries the PE checksum the client can load (0x6531394) and Steam's Verify restores the original; a missing or changed file must fail with a message naming it and asking for a re-download, never count as installed; an install made by an earlier version of this utility shows **Remove BOIII (CB Servers)** |
| 9 | Black Ops 4 | Project BO4 (Shield) | Install takes a while (about 2.2 GB through Shield's launcher); Play Online and Play Offline open Shield's launcher with your name in `project-bo4.json`; press Play Client; **Repair** if the screen stays black; Remove puts your `BlackOps4.exe` and LPC back; Battle.net Scan and Repair clean |
| 10 | HorizonMW | HMW Launcher | Install opens the HMW Launcher: paste the MWR folder (on the clipboard), Verify game files; then **Play** on the card; Remove asks before deleting what the launcher added |

**Call of Duty (2003).** On a folder with an older copy of the game, Install 1.1 must
leave the 1.1 files and nothing else behind (only the two executables are kept), 1.1X must
stay greyed out until 1.1 is in, and Remove must take 1.1X with it and put every original
file back. Removing 1.1 is the full revert.

**United Offensive** takes an empty folder picked with **Change folder**: it is not looked
for in Steam, it is never written into the Call of Duty (2003) folder, and a folder that
holds anything is refused before anything is downloaded. Install then copies the 1.5 game
files in, the United Offensive 1.5 files over them, and sets up the two server keys from
the client's site. The first key comes from the site's key file, the second from the page
that prints it next to `CODUO`: it is a new key on every request, so run **Set up server
key** twice and `key\coduo-key.txt` must hold a different key each time, the 20 characters
the registry gets, without the dashes the page groups them in. Each key is its own
`.reg` file, and each one opens the registry editor,
which asks whether to add it: click **Yes** (Windows asks for administrator rights first).
After it closes the log must not say the values are still missing from the registry: that
line means the merge did not happen (a No, or an editor that closed without asking), and
**Set up server key** must ask again.
Check that `key\` ends up with both `.reg` files as published (`cod1.1_(x64).reg`,
`coduo1.51.reg`), both keys (`codkey.txt`, `coduo-key.txt`), the filled in copies
(`codhq-server-key.reg`, `codhq-uo-server-key.reg`) with `"Version"="1.5"` in the first and
`"Version"="1.51"` in the second, and that the log says both keys are set
up. **Set up server key** on the card must do the same again in a few seconds, without
downloading the game. Then Play must start `CoDUOSP.exe` and `CoDUOMP.exe`, and Remove must
take the files, `key\` and the registry values the two `.reg` files added away again (the
editor asks once per file, and a prompt that is cancelled leaves
`key\codhq-*-remove.reg` to double-click). The keys come from the client's own site, so try the
whole flow again if a download fails; when the page holds no key that can be read, the
`.reg` is still in `key\` with its path, drive and version filled in, and the log says what
to put in
it by hand. **Call of Duty 2** installs two patches. **Install Custom patch v2** copies only `steam.dll` and `cod2patch.ini` out of the ZIP's `steam` folder (the `retail` folder and `Info.txt` stay in it), then **Install CoD2x** copies `mss32.dll` and `mss32_original.dll` in. Play must start `CoD2SP_s.exe` and `CoD2MP_s.exe` with the custom patch alone: CoD2x only enhances it, so neither Play button may wait for it, and CoD2x carries `(Recommended)` on its status line and its install button. Remove must take CoD2x away first, put the retail `mss32.dll` back and then delete the patch's two files.

**Black Ops III** installs CodHQ BOIII, our own build of the community client: it is the
only client on the card, marked Recommended, and its files come from our GitHub Pages
(`https://larkthestar.github.io/codhq-boiii/`) and nowhere else. Install downloads
`codhq-boiii.zip`, compares its SHA-256 with the one pinned in the catalogue, and checks
the file list in `boiii.json` from the same site: the pinned 196 entries have to be there,
and every entry's size and SHA-1 have to match before anything is written. It then puts
`boiii.exe` in the game folder and the `data` tree in `%LOCALAPPDATA%\boiii`, reads the
install back, and checks the count and every SHA-1 again. A missing, changed or extra
file must fail with a message naming that file and asking for a re-download, then a retry
after deleting `%LOCALAPPDATA%\boiii`, and nothing that was written may stay behind: a
partial or corrupt install never counts as installed. After the fork publishes a new
`v*` tag, run `tools\Update-BoiiiPin.ps1` and commit the size, SHA-256 and count it
writes (its `-Check` form, which the daily workflow runs, must report that the pin and
the site agree), then install and update once from the card: the client replaces
`boiii.exe` from `boiii.json`, keeps its `data` tree current even with `-noupdate`, and
the install must still end with the pinned count and every SHA-1 matching. Play starts `boiii.exe` with
`-launch -noupdate`; the client then updates itself from that same manifest. **Check game exe** reads `BlackOps3.exe` and reports its
version, SHA-1, SHA-256 and PE checksum; the build a BOIII client can load is the
executable released Sept 10, 2026 with PE checksum 0x6531394 (the dedicated server's
0x14C28B4 is not it), and a mismatch must recommend Steam's Verify integrity. The
client offers to fix it: on an unsupported build it prompts, downloads `BlackOps3.exe`
(106,059,256 bytes, SHA-1 `9D03F810...3B9B`, checksum 0x6531394), keeps your own file
as `BlackOps3.exe.boiii_backup`, installs it and reads it back; Cancel, a failed
download or a bad hash must leave the file untouched, and the Patches tab's button
must answer "already the compatible build" when it matches. This utility itself never
downloads a game file.
At startup it also names a proxying DLL beside the game, a WinDivert driver or service, a running
GoodbyeDPI or a non-Windows Winsock entry in one console message, and does not patch around it. If an earlier version installed CB's BOIII
here, the card also offers **Remove BOIII (CB Servers)**, and Remove must take
`boiii.exe` and its `data\` tree away while leaving your own game files alone.

## When something fails

Send the saved log. The fix goes into the installer. It is never a downloaded copy of
a game file. Things worth noting with the log:

- which step of the table failed, and the exact message the game showed;
- for BO4: `project-bo4\launcher\content-sync.log` in the game folder;
- for HorizonMW: what the HMW Launcher showed after Verify.
