# Game executables and CD keys in the CB launcher

How the CB launcher handles the two retail executables it carries and the CD-key
registry values it writes, and what this installer does instead. No key values are
reproduced here.

## BlackOps3.exe and BlackOps4.exe

- `boiii.json` lists `BlackOps3.exe` (106,059,256 bytes) next to `boiii.exe`;
  `project-bo4.json` lists `BlackOps4.exe` (114,558,448 bytes). Both live in Git LFS
  in `CBServers/updater`.
- `game_config.cpp` puts them in `client_install_path_files`, so they are copied into
  the game folder. Games with several clients for one mode keep each client's files
  under `%LOCALAPPDATA%\cbservers\clients\<id>\` and copy the selected client's files
  into place at launch (`client_store::reconcile`).
- BO3 is recognized by `BlackOps3.exe` alone (`valid_game_files`); BO4 by
  `BlackOps4.exe`, `BlackOps4_boot.exe` or `Black Ops 4 Launcher.exe`.

**This installer:** never downloads either file. `Test-GameExecutable` checks the
player's own copy: present, not a link, its file version and product name, its size,
SHA-1 and SHA-256 compared with the build the client expects (the size and SHA-1 CB
publishes), and the files the client needs beside it. A different build is reported
with its version, and the guidance is Steam's **Verify integrity of game files** (BO3)
or Battle.net's **Scan and Repair** (BO4).

## CD keys

Written by `game_commands.cpp` before launch, only when no key is present yet:

| Game | Registry location written | Value name(s) | Also checked |
| --- | --- | --- | --- |
| Call of Duty 4 | `HKCU\SOFTWARE\Activision\Call of Duty 4` | `codkey` | none |


Format: each stored value is 20 characters, uppercase letters and digits, no dashes
(the key as Steam shows it, with the dashes removed).

Other registry work before launch: BO4 gets an empty
`HKCU\SOFTWARE\Blizzard Entertainment\Battle.net` key.

**This installer:** the **CD key** button inspects the current value (masked to its last
4 characters), backs it up to a `.reg` file, writes the key the player types (their own
key, from Steam's **CD Key** entry for the game; checked for 20 letters and digits after
removing dashes; read back to confirm), and restores a backup. It writes the same
location as above and never logs a key. It
contains no keys of its own.
