# Testing a build on a real install

The client can only be judged on a real Black Ops III install. This is the
procedure that was actually used, including the parts that were not verified.

## Launching for a test

```bash
cd "/d/SteamLibrary/steamapps/common/Call of Duty Black Ops III"
./boiii.exe -noupdate -launch
```

`-noupdate` is **required** when testing a locally built executable: without it
the updater replaces your build with the published one and the test tells you
nothing. `-noupdate` still refreshes `data/`, which is what you want.

## Where the evidence lives

| What | Where |
| --- | --- |
| Crash dumps | `%LOCALAPPDATA%\boiii\minidumps` (`codhq-crash-*.zip`, `ezz-crash-*.zip`) |
| Console output | the in-game console window (`RICHEDIT50W`); the window title carries the CodHQ prefix |
| Client log / stdout | the launching terminal, if started from one |

**Take a dump listing before the run and compare after.** "No crash" is only
true if no new `codhq-crash-*.zip` appeared; the newest dump in the folder may
be from an earlier session.

## The console checks that matter

Type into the in-game console (`~`):

| Command | Expected on an install without Multiplayer data |
| --- | --- |
| `map mp_rise` | `[Com] Black Ops III's Multiplayer data is not installed here, so 'mp_common' cannot be loaded…` plus a toast telling the player which Steam DLC to tick. The process stays alive. |
| `connect <ip:port>` | `[Party]` with the same explanation, and **not** the old `Missing or invalid workshop/map dependencies` text. |
| `quit` | Clean shutdown. |

If `map mp_rise` instead reaches the engine's fast-file loader, the guard did
not fire — check that the `map`/`devmap` command wrap is installed, not the
`Cmd_ExecuteSingleCommand` detour (that detour never fires on this engine build;
it was removed for exactly that reason).

## What a good run looked like (`v3.1.0-codhq.11`, local build)

- `]map mp_rise` → `[Com] … mp_common …`, process alive.
- `]connect 45.11.18.111:27019` → `[Party] …`, process alive.
- `quit` exited cleanly.
- No new dump: the newest `codhq-crash-*.zip` was from an earlier session, and
  the dump folder listing was identical before and after.

## Console automation

Typing into the game's console from a script is fiddly. The helpers used are in
`dist/` (`send-console.ps1`, `read-console.ps1`, `list-windows.ps1`):

- Find the window (class/title), then send keys only after confirming the game
  window is focused — `AttachThreadInput` plus minimise/restore. If focus cannot
  be confirmed, type nothing: a blind `SendKeys` goes wherever focus is (in one
  session it typed a `connect` command into a Discord window).
- Read the console back by dumping the `RICHEDIT50W` control, not by OCR.

A live server list can be pulled from Ezz's master, `master.ezz.lol:20810`, with
`\xff\xff\xff\xffgetservers T7 8 full empty` (`dist/master-query.py`).

## Building locally

The fork builds with `premake5 ninja` + LLVM, and needs three things Windows
build machines usually lack, all documented in the fork's README section
*Windows prerequisites this fork needed*:

1. The MSVC submodules at the commits the fork records.
2. ATL headers (`atlmfc/include`, from the `AtlInclude` NuGet package).
3. `llvm-windres`, which LLVM does not ship: a shim that forwards to `llvm-rc`.

```bash
INCLUDE=<atl>/atlmfc/include /tmp/premake/premake5.exe ninja
PATH=<shim dir>:$PATH ninja Release_x64 -Cbuild
```

A stub `atls.lib` in `build/` satisfies the one ATL symbol the link needs. The
result is `build/bin/x64/Release/boiii.exe`.

## Installer test suite

`tests/Invoke-Tests.ps1` (Pester 5) covers the installer, including the CodHQ
BOIII client entry, its pin, the archive check and the legacy CB removal. It
must pass on both shells before a pin is committed:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./tests/Invoke-Tests.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./tests/Invoke-Tests.ps1
```

Last run for the `.11` pin: **219 passed, 0 failed** on PowerShell 5.1.26100 and
on PowerShell 7.7.0. Windows ships 5.1; when no PowerShell 7 is installed, a
portable build can be unzipped into a temp folder and used directly.

## What was never verified

- A click-through of the **in-game multiplayer server browser** and a completed
  join. The browser needs the Multiplayer UI data, which is not installed on the
  test machine, so the join was driven through the engine's `connect` command —
  the same `party::connect_stub` path a browser join uses.
- Actual gameplay on a server after a successful join.
- Any behaviour that requires the Steam Multiplayer or Zombies DLC to be
  present, i.e. the successful path through `Com_LoadLevelFastFiles`.

If a machine with the Multiplayer DLC is available, the highest-value test is
simply: install, `map mp_rise`, and confirm the level loads — that exercises the
loader the guard currently protects.
