# Call of Duty and United Offensive: versions and files

Steam's Call of Duty (app 2620, build 60145) and United Offensive (app 2640, build
1024) share one folder, `steamapps\common\Call of Duty`. Steam ships its own builds of
the executables and some of the game modules. The community clients need the retail
1.1 (CoD1x) and 1.51 (UOx) files instead. The installer handles that as follows.

## Where each file comes from

| Version | Files the installer places | Source |
| --- | --- | --- |
| CoD1 Steam (1.5) | none | Steam's own files |
| CoD1 1.1 | the 1.1 game files below | **imported** from the player's own copy of Call of Duty 1.1 |
| CoD1 1.1x | `cod1x.dll`, `CoDMP.exe` (patched), `CoDMP_old.exe` (plain 1.1) | CoD1x's official release ([xtnded/codextended-client](https://github.com/xtnded/codextended-client), build 2697), on top of the 1.1 files |
| CoD1 retail 1.5 (optional) | the 1.5 game files below | **imported** from the player's own copy of 1.5; only needed if a 1.5 server rejects Steam's build |
| UO Steam | none | Steam's own files |
| UO 1.51 | the 1.51 game files below | **imported** from the player's own copy of UO 1.51 |
| UO 1.51x | `coduo.dll`, `CoDUOMPx.exe` | `coduo.dll` is UOx built by this repository's CI ([build-uox.yml](../.github/workflows/build-uox.yml)) from [xtnded/codextended-client-uo](https://github.com/xtnded/codextended-client-uo) at commit `146bcb1`; `CoDUOMPx.exe` is made on the player's PC from their own 1.51 `CoDUOMP.exe` |

The installer never downloads Activision's game files. Files marked "imported" are
copied from a folder the player picks (an old retail install, a backup or the disc)
when each one matches the size and CRC-32 below. Every replaced file is backed up and
put back by Remove, and **Use Steam version** removes every version at once.

## The exe patch

CoD1x's own release contains both its patched `CoDMP.exe` and the original 1.1 one
(`CoDMP_old.exe`). The two differ in exactly five bytes: the import table entry
`mss32.dll` is renamed to `cod1x.dll`, so the game loads the client DLL, and the DLL
then loads the real `mss32.dll` itself. UOx's source (`dllmain.cpp`, `mss32.cpp`) works
the same way. `New-ImportRenamedExecutable` makes that change on a copy of the
player's 1.51 `CoDUOMP.exe`, giving `CoDUOMPx.exe`, which imports `coduo.dll`. The UO
DLL gets that name because CoD1x's `cod1x.dll` already sits in the same folder. The
tests check that patching `CoDMP_old.exe` this way reproduces CoD1x's `CoDMP.exe`
byte for byte.

## Files compared

These values come from reading the central directories of the cod.pm guides' archives
with [tools/Get-RemoteZipListing.ps1](../tools/Get-RemoteZipListing.ps1) (directory only,
nothing else downloaded) and checking them against the Steam folder file by file.

### CoD1 1.1 (`CoD 1.1 files`)

18 files of the 1.1 layout are byte-identical to Steam's (`pak1`-`pak6`, `miles\*`,
`mss32.dll`, ...). These differ:

| File | Size | CRC-32 | Steam's |
| --- | ---: | --- | --- |
| `Main/pak0.pk3` | 167,014,921 | `4D8A1EC3` | 164,229,067 |
| `Main/game_mp_x86.dll` | 483,328 | `94124316` | 491,520 |
| `Main/cgame_mp_x86.dll` | 536,576 | `923DD9EE` | 540,672 |
| `Main/ui_mp_x86.dll` | 270,336 | `8D23A8B4` | 274,432 |
| `localization.txt` | 2,069 | `1CE5F860` | 2,285 |
| `CoDSP.exe` | 1,712,128 | `F7DBC266` | 610,816 |
| `gamex86.dll` | 737,280 | `FA15B6F1` | same size, different build |
| `cgamex86.dll` | 462,848 | `BFF6E693` | same size, different build |
| `uix86.dll` | 253,952 | `BDAABBD7` | same size, different build |

The 1.1 `CoDMP.exe` (1,564,672 bytes, `52F454FD`) is not imported: CoD1x's release
ships the identical file as `CoDMP_old.exe`.

### CoD1 retail 1.5 (`CoD 1.5 files`)

| File | Size | CRC-32 |
| --- | ---: | --- |
| `CoDMP.exe` | 1,830,912 | `59B8B6DF` |
| `CoDSP.exe` | 2,899,712 | `C055244B` |
| `Main/game_mp_x86.dll` | 503,808 | `F4747D63` |
| `Main/cgame_mp_x86.dll` | 544,768 | `E1D55B51` |
| `Main/ui_mp_x86.dll` | 274,432 | `8E0553C1` |
| `Main/pakb.pk3` | 5,087,181 | `13E84AC9` (Steam's is a 1-byte stub) |
| `localization.txt` | 2,069 | `1CE5F860` |

### UO 1.51 (`UO 1.51 files`)

34 files are byte-identical to Steam's. These differ:

| File | Size | CRC-32 | Steam's |
| --- | ---: | --- | --- |
| `CoDUOMP.exe` | 1,904,640 | `A04DDC77` | 693,760 |
| `CoDUOSP.exe` | 2,999,821 | `71664E61` | 633,344 |
| `uo/uomappack00.pk3` | 39,499,720 | `8228FF58` | not in Steam's copy |

## What can run together

- 1.1 and 1.1x need the CoD 1.1 files, and 1.1x needs CoD1x as well.
- The 1.5 files cannot be in place together with the 1.1 files or CoD1x, because they
  replace the same files.
- United Offensive runs on Call of Duty's 1.5 data, so no UO version starts while the
  CoD 1.1 files are in place (its card says so).
- 1.1x and 1.51x start with administrator rights, as CoD1x asks for ("Disabled
  VirtualStore").

## Registry and keys

While an imported version is in place, the installer writes the retail values
`InstallPath`, `InstallDrive`, `Language`, `Version` and `pb` for the player's folder.
They go to HKCU's VirtualStore and, after one administrator prompt, to HKLM, as the
cod.pm `.reg` files have them. The earlier values are recorded and put back by Remove.

CoD1's CD key is the player's own. It is written to the registry (1.5) and to
`Main\codkey` (1.1, in the format the game writes), backed up first, and restorable.
