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
| Real window | `powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-Gui.ps1` | every page opens, all 15 game cards appear, the admin hand-off works |
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
| 1 | Call of Duty (2003) | 1.1 (singleplayer and MP) | Install copies the 1.1 files from this project's release over the folder; both Play modes start the 1.1 exes; Remove puts the previous game files back |
| 2 | Call of Duty 4 | iw3x, CoD4x, IW3SP-Mod | install iw3x and CoD4x one at a time (they conflict); campaign via IW3SP-Mod |
| 3 | Ghosts | IW6x | campaign and MP |
| 4 | World at War, Black Ops, Black Ops II, MW3 | Plutonium | **Plutonium login** once; each mode's `plutonium://play/<id>` starts |
| 5 | Black Ops II campaign | T6SP-Mod | campaign starts without Plutonium |
| 6 | MW2, MW3 campaign | IW4x, AlterWare | Spec Ops through AlterWare |
| 7 | Advanced Warfare, Infinite Warfare, MWR | S1x, IW7-Mod, H1-Mod (CB) and H1-Mod (AuroraMod) | try both H1-Mod sources one after the other |
| 8 | Black Ops III | BOIII | **Check game exe** first; Play starts BOIII |
| 9 | Black Ops 4 | Project BO4 (Shield) | Install takes a while (about 2.2 GB through Shield's launcher); Play Online and Play Offline open Shield's launcher with your name in `project-bo4.json`; press Play Client; **Repair** if the screen stays black; Remove puts your `BlackOps4.exe` and LPC back; Battle.net Scan and Repair clean |
| 10 | HorizonMW | HMW Launcher | Install opens the HMW Launcher: paste the MWR folder (on the clipboard), Verify game files; then **Play** on the card; Remove asks before deleting what the launcher added |

## When something fails

Send the saved log. The fix goes into the installer. It is never a downloaded copy of
a game file. Things worth noting with the log:

- which step of the table failed, and the exact message the game showed;
- for BO4: `project-bo4\launcher\content-sync.log` in the game folder;
- for HorizonMW: what the HMW Launcher showed after Verify.
