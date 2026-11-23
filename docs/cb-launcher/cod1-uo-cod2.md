# Call of Duty, United Offensive and Call of Duty 2: what CB publishes

A fresh scrape, done on 2026-11-24 while these three games are being started over.
Everything here was read from CB's public GitHub repositories on that date. Nothing
was downloaded from CB's game-content CDN, and no game file was fetched: the entries
below are manifest metadata (path, size, hash) and source code only.

Sources:

| Source | URL |
| --- | --- |
| Updater folder listing | `https://api.github.com/repos/CBServers/updater/contents/updater` |
| Client manifests | `https://raw.githubusercontent.com/CBServers/updater/main/updater/<name>.json` |
| Launcher update manifest | `https://raw.githubusercontent.com/CBServers/updater/main/updater/cb-launcher.json` |
| Full-game manifests | `https://raw.githubusercontent.com/CBServers/updater/main/updater/cb-launcher/manifest/<game>.json` |
| Game configuration | `https://raw.githubusercontent.com/CBServers/cb-launcher/main/src/launcher/game_config.cpp` |
| Launch prerequisites | `https://raw.githubusercontent.com/CBServers/cb-launcher/main/src/launcher/commands/game_commands.cpp` |

The updater folder holds 52 entries: 25 JSON manifests and 27 folders (`h1-mod` and
`iw7-mod` keep their manifest inside the folder, as `files.json`). Five manifests
cover these three games: `cod1.json`, `cod1x.json`, `coduo.json`, `coduox.json` and `cod2x.json`. Each
one has a matching folder of the same name beside it.

## The five manifests, verbatim

`cod1.json` (208 bytes):

```json
[ [ "CoDMP.exe", 1564672, "1F4DF0C155AD821184DBE1F166111F220FC14DD3" ],
  { "ManifestHash": "27EEA0D3D21261684E5491B5B73156D235DAEAACE08E89ED8CC9AE40E1BE225B" } ]
```

`cod1x.json` (310 bytes):

```json
[ [ "cod1x.dll", 1107968, "B8F66B99195B393FFE12126866E1F2E50F09C364" ],
  [ "CoDMP.exe", 1564672, "2EE05C06A9B46C0B488D8743BA9449FC790FBF50" ],
  { "ManifestHash": "65092FA7C133832C449760F6687B0B414B64047E754ADE5678436DDDCD8850A3" } ]
```

`coduo.json` (210 bytes):

```json
[ [ "CoDUOMP.exe", 1904640, "31B21E8B55BB168DD2CE11E510A9CD2F47776C57" ],
  { "ManifestHash": "E52DC3227D6C6B581FC1547A92A21CA5FB204E59CB47119AE3A89AC343CE52B2" } ]
```

`coduox.json` (311 bytes):

```json
[ [ "cod1x.dll", 415744, "1EDA93961891ED8AA8CC6F7486EC50666759001F" ],
  [ "CoDUOMP.exe", 1904640, "3C2CC379AEFD68B7EEC0CFB1C3B0FA8AE397A5F2" ],
  { "ManifestHash": "B220EC0E6EC1510E45B7B34D88E49B2FE28F301454DA4CF6B6AB58E9D72E47FF" } ]
```

`cod2x.json` (318 bytes):

```json
[ [ "mss32.dll", 6206990, "5701D61ABF95042EE93C1EE727F8DB1354C97320" ],
  [ "mss32_original.dll", 370688, "1B4C0C4FADDCDAE5B7239CC861A9389D55F38A4E" ],
  { "ManifestHash": "973F2A9A6E0AB52D5CA81AEDD70D7331FBF24AB34827B82A75101AB8BCB0BAB8" } ]
```

None of the entries has the optional fourth field (`game` / `appdata`), so every file
goes into the game folder. There are no version numbers, no archive entries, no
redistributables and no data files in any of the five: a file is current when its size
and SHA-1 match.

The folders beside the manifests hold exactly the same names:

| Folder | Files |
| --- | --- |
| `updater/cod1/` | `CoDMP.exe` |
| `updater/cod1x/` | `CoDMP.exe`, `cod1x.dll` |
| `updater/coduo/` | `CoDUOMP.exe` |
| `updater/coduox/` | `CoDUOMP.exe`, `cod1x.dll` |
| `updater/cod2x/` | `mss32.dll`, `mss32_original.dll` |

## What each of the five actually is

From `game_config.cpp` (`game_configs_`, the `cod1`, `coduo` and `cod2x` blocks) and
the sizes and hashes above:

| Manifest | What CB installs | Reading |
| --- | --- | --- |
| `cod1.json` | One file: `CoDMP.exe` | A patched copy of the game's own multiplayer executable. CB calls this client "cod1" and declares it first, so **vanilla is the default** multiplayer choice. |
| `cod1x.json` | `cod1x.dll` + a second `CoDMP.exe` | The CoD1x client: its DLL plus its own patched MP executable. This `CoDMP.exe` is a **different build** from `cod1.json`'s (same 1,564,672 bytes, SHA-1 `2EE05C06...` instead of `1F4DF0C1...`). |
| `coduo.json` | One file: `CoDUOMP.exe` | A patched copy of the game's own United Offensive multiplayer executable. Also first, so vanilla is the default. |
| `coduox.json` | `cod1x.dll` + a second `CoDUOMP.exe` | The UOx client: the same DLL name at a **different size and build** (415,744 bytes instead of 1,107,968) plus its own patched `CoDUOMP.exe` (SHA-1 `3C2CC379...` instead of `31B21E8B...`). |
| `cod2x.json` | `mss32.dll` (6,206,990 bytes) + `mss32_original.dll` (370,688) | This is **not a client**. It is attached to the game entry itself as that game's update: CB replaces the game's Miles Sound System library with its own build and keeps the retail one under the backup name. The retail library is 370,688 bytes, which matches the full-game manifest below. |

So for these three games CB publishes two multiplayer executables per classic title,
each a patched copy of the game's own file, plus the CoD1x/UOx DLL, and for CoD2 a
single DLL pair. Nothing else.

## Game configuration as CB defines it

From `game_config.cpp`:

| | Call of Duty | United Offensive | Call of Duty 2 |
| --- | --- | --- | --- |
| CB id | `cod1` | `coduo` | `cod2x` |
| Display name | Call of Duty | United Offensive | Call of Duty 2 |
| Main executable | `CoDMP.exe` | `CoDUOMP.exe` | `CoD2MP_s.exe` |
| Files that mark a valid folder | `CoDSP.exe`, `CoDMP.exe` | `CoDUOSP.exe`, `CoDUOMP.exe` | `CoD2SP_s.exe`, `CoD2MP_s.exe` |
| Modes | `sp` (`CoDSP.exe`), `mp` (`CoDMP.exe`) | `sp` (`CoDUOSP.exe`), `mp` (`CoDUOMP.exe`) | `sp` (`CoD2SP_s.exe`), `mp` (`CoD2MP_s.exe`) |
| Mode arguments | none | none | none |
| Default arguments | `+set com_hunkmegs 512 +set r_lodbias -1000` | `+set com_hunkmegs 512 +set r_lodbias -1000` | none |
| Name argument | `+set name` | `+set name` | `+set name` |
| Game-content folder | `cod1_game_files` | `coduo_game_files` | `cod2_game_files` |
| Redistributables | `vcr2005`, `dx_jun2010` | `vcr2005`, `dx_jun2010` | `vcr2005`, `dx_jun2010` |
| Requires elevation | no | no | **yes** |
| Custom resolution keys | set | set | set |
| Clients declared | `cod1` (default), `cod1x` | `coduo` (default), `coduox` | none: `cod2x.json` is the game update |

There are no launch flags (no equivalent of BO3's `-nointro`), no property overrides
and no custom updater files for any of the three. `+set name` is the only player-name
mechanism, and only the multiplayer executables take it.

Singleplayer: CB has no client for any of these game's singleplayer executables, and
none of the three games has a mode other than `sp` and `mp`.

## The full game, as CB lists it ("Download game")

The launcher carries one game-content manifest per game inside its own update
(`cb-launcher/manifest/<game>.json` in the updater repository). These are metadata
only and were read, not acted on: the files they name are served from CB's game-content
CDN, which this project does not use (see [provenance.md](provenance.md)).

| Game | Manifest | ManifestHash | Files | Total size | Component |
| --- | --- | --- | ---: | ---: | --- |
| Call of Duty | `manifest/cod1.json` | `149ABFE02F3DFC7C740D806074992303E1E1F49ACD8A1C3843BCC44F72872177` | 29 | 1,216,842,066 B (1.13 GiB) | `base`: "Full Game (1.1)", required |
| Call of Duty 2 | `manifest/cod2.json` | `D32843F4B2B0DFDEEA9A09E1481B9C6D75B66CC49FE7F5C0F6F64AF5DF9E50F0` | 64 | 3,701,416,426 B (3.45 GiB) | `base`: "Full Game (1.3)", required |
| United Offensive | `manifest/coduo.json` | `72D7460749F78ACD074280D3181C06904E653C31F64C4660A4106D21D57B0EB8` | 75 | 2,225,623,754 B (2.07 GiB) | `base`: "Full Game (1.5 + UO)", required |

Each has a single component, so CB offers no split between singleplayer and
multiplayer and no language components. The versions CB ships are CoD1 1.1, CoD2 1.3
and UO 1.5 already including the United Offensive expansion.

The hashes in these manifests are 16 hexadecimal characters (a 64-bit hash), not
SHA-1 like the client manifests: `CoDMP.exe` is `18B9DB70B767A3FE` there while
`cod1.json` gives the SHA-1 of its patched copy.

Executables and DLLs named in each game manifest (`[path, size, hash]`):

Call of Duty:

```
CoDMP.exe                  1564672  18B9DB70B767A3FE
CoDSP.exe                  1712128  8D01E7475958862D
cgamex86.dll                462848  012C50BC6D7A40EB
gamex86.dll                 737280  115B76BF8AD6C1B3
uix86.dll                   253952  99E14E090C7340BD
main/cgame_mp_x86.dll       536576  F9344B3EDB86953A
main/game_mp_x86.dll        483328  59BBF109A9438625
main/ui_mp_x86.dll          270336  C6BFEA8F21049C0F
mss32.dll                   370688  08FCB3406B7C8E83
```

Call of Duty 2:

```
CoD2MP_s.exe               1974272  53DE18DE70EEED5E
CoD2SP_s.exe               1761280  D7A6E254558248D4
gfx_d3d_mp_x86_s.dll       1855488  F2BDBFF0E074CE6A
gfx_d3d_x86_s.dll          1851392  379734D9857C6286
mss32.dll                   370688  08FCB3406B7C8E83
FirewallInstallHelper.dll    54280  9BDA0EDFF7F82A76
GameuxInstallHelper.dll      96264  043D1639DEA56F69
pb/pbag.dll                  57344  E0F7984965FDCF67
pb/pbags.dll                 57344  E0F7984965FDCF67
pb/pbcl.dll                 503808  374331D078A180EC
pb/pbcls.dll                503808  374331D078A180EC
pb/pbsv.dll                 307200  C21F3487E7D72AD9
pb/dll/wc001203.dll         503808  374331D078A180EC
pb/dll/ws001105.dll         307200  D95E602FE3DC7D9E
```

United Offensive:

```
CoDMP.exe                  1830912  6CE86AB67515F58C
CoDSP.exe                  2899712  7658C9EB17B865A0
CoDUOMP.exe                1904640  3FB2DF335E573C22
CoDUOSP.exe                1806336  12A27E413DABAD84
binkw32.dll                 338944  09A6CF65462DD9AC
cgamex86.dll                462848  88EEE354A5509AED
gamex86.dll                 737280  B3A4494310FFCC69
uix86.dll                   253952  10B12D6969081D41
mss32.dll                   370688  08FCB3406B7C8E83
EaxMan.dll                   94208  DBFB28AEFCC3A0FC
validatekey.dll              49152  66F48EF3A9ABE0C3
Main/cgame_mp_x86.dll       544768  854C061B5D524CF8
Main/game_mp_x86.dll        503808  21A788ED56109C9E
Main/ui_mp_x86.dll          274432  79B76B15C9A5D6D0
uo_cgamex86.dll             520192  47F7633C08B24920
uo_gamex86.dll              774144  D288D5854EC963F7
uo_uix86.dll                258048  C59BDB5AA9022B80
uo/uo_cgame_mp_x86.dll      626688  9902B54A887E993D
uo/uo_game_mp_x86.dll       622592  A5809ECD453FA4B4
uo/uo_ui_mp_x86.dll         290816  84157E325DD9F590
pb/pbag.dll                  45710  51266C18E5C5255A
pb/pbags.dll                 45710  51266C18E5C5255A
pb/pbcl.dll                 303104  52E40E6937B2D25D
pb/pbcls.dll                303104  52E40E6937B2D25D
pb/pbsv.dll                 198002  3FDC0ECC17234746
```

The rest of each list is the retail install and nothing else: `.pk3` archives (9 in
CoD1, 28 in UO) and `.iwd` archives (28 in CoD2); the Miles Sound System codec
plugins under `miles/` (`*.m3d`, `*.flt`, `mssmp3.asi`, `mssvoice.asi`); PunkBuster
under `pb/` (`pbcl.dll`, `pbsv.dll`, `pbag.dll`, `pbag.dll`, `htm/` help pages); the
`.bmp` logos, `localization.txt`, `version.inf`; and for CoD2 the default player
configs (`main/players/Default/config.cfg`, `config_mp.cfg`, `active.txt`,
`instscript.vdf`, `servercache.dat`).

CoD1's list also has `main/codkey` (172 bytes): the game's CD-key file. It is part of
CB's full-game download only; no client manifest lists it.

Note the retail `mss32.dll` is 370,688 bytes with hash `08FCB3406B7C8E83` in all three
games, and `cod2x.json`'s `mss32_original.dll` is exactly 370,688 bytes. United
Offensive's manifest contains the base game as well as the expansion (two `CoDMP.exe`
generations, `uo/` DLLs and `validatekey.dll`).

## Launcher files for the three games

`cb-launcher.json` has 146 entries; 15 belong to these three games:

| Path | Size | SHA-1 |
| --- | ---: | --- |
| `data/launcher-ui/assets/img/games/cod1/capsule.jpg` | 62,040 | `AA96FA637D78F98BCB746CDC87EF8EA97C6394FC` |
| `data/launcher-ui/assets/img/games/cod1/hero.jpg` | 925,052 | `9F6ABD2A1A608DB8B3278141B24EFD7F53281001` |
| `data/launcher-ui/assets/img/games/cod1/icon.ico` | 50,504 | `D607600189BF3E98D39546F271D2F5D4F6E24912` |
| `data/launcher-ui/assets/img/games/cod1/logo.png` | 666,251 | `8B0C1C795106C35ADDBD4084288AFF75F29EEB3E` |
| `data/launcher-ui/assets/img/games/cod2x/capsule.jpg` | 211,757 | `AB5AC2D9DDDB891F266042068637C0EBC6A998E5` |
| `data/launcher-ui/assets/img/games/cod2x/hero.jpg` | 1,297,156 | `9EBF1245621AE421556E955B0B6FCB83F9506F8D` |
| `data/launcher-ui/assets/img/games/cod2x/icon.ico` | 545,119 | `C596143FB36F3FEE98920206F96639B441B815BE` |
| `data/launcher-ui/assets/img/games/cod2x/logo.png` | 557,830 | `DAB62D3182E04CAB1D54B2925D4BD81F142E1940` |
| `data/launcher-ui/assets/img/games/coduo/capsule.png` | 880,657 | `DFA991EC4A59C5C3CB581898BBE3B15D1CA1BEB5` |
| `data/launcher-ui/assets/img/games/coduo/hero.jpg` | 644,947 | `F5DD1446E966EC0B2F0567F4B26145F1A0974037` |
| `data/launcher-ui/assets/img/games/coduo/icon.ico` | 61,420 | `4C54106D4D0B79EFB4AB22CDAA4C4E86BC78D8CC` |
| `data/launcher-ui/assets/img/games/coduo/logo.png` | 192,153 | `0549BECDDE5421A92130D8C9B698698649BC4FB2` |
| `manifest/cod1.json` | 3,934 | `F66B9A27C150E79AB9DF92BD4441EA093A1E90E2` |
| `manifest/cod2.json` | 8,488 | `C146545B63589C449D529C2D848F6375FD454BBC` |
| `manifest/coduo.json` | 9,709 | `77B3258CE86FCD0882CFF59FF71E23A8BA7C8521` |

Twelve are card artwork (capsule, hero, icon, logo per game); the other three are the
full-game manifests above. There is no `cod1x` or `coduox` artwork, and no launcher
file shipped under the client ids.

## What the launcher does before it starts these games

From `game_commands.cpp`:

- **DPI.** All of `CoDSP.exe`, `CoDMP.exe`, `CoDUOSP.exe`, `CoDUOMP.exe`,
  `CoD2SP_s.exe` and `CoD2MP_s.exe` get the per-user high-DPI compatibility override
  (`HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers`), on every
  launch, guarded so it is written once.
- **CD keys.** These three plus CoD4 each get a key written only when no key exists
  yet. The values are fixed strings hard-coded in `game_commands.cpp` (lines 286-336),
  so they are not the player's own key; this project does not use them.
  - CoD2: `HKCU\SOFTWARE\Classes\VirtualStore\MACHINE\SOFTWARE\WOW6432Node\Activision\Call of Duty 2`,
    value `codkey`. Skipped when the value already exists there **or** in the real
    `HKLM\SOFTWARE\Activision\Call of Duty 2` (32-bit view), because an elevated CoD2x
    migrates the store value to the real key and deletes the copy.
  - United Offensive: the same VirtualStore path for
    `...\Activision\Call of Duty United Offensive`, writing **both** `key` and
    `codkey`, with the same real-key check.
  - CoD4 (for comparison): `HKCU\SOFTWARE\Activision\Call of Duty 4`, value `codkey`.
- Elevation: only CoD2 is marked `requires_elevation`.

## Open questions for the next step

These come out of the scrape and are not decided yet:

1. **`cod1x.dll` is the only file here that is not a copy of a game file.** Its two
   builds (CoD1: 1,107,968 bytes, UO: 415,744) need to be traced to the CoD1x
   project's own release before the installer may fetch them. That auditing has not
   been redone for these three games.
2. **Every patched executable is a copy of the game's own file** (same sizes as the
   retail ones: `CoDMP.exe` 1,564,672, `CoDUOMP.exe` 1,904,640), so under the
   file-sourcing rule they cannot be downloaded; a client that needs one would have to
   patch or import the player's own copy. Resolved for CoD1 on 2026-11-24: its 1.1
   singleplayer and MP files come from this project's own release (tag `1.1`), pinned
   by SHA-256 and installed as published, so nothing is taken from CB.
3. **CoD2's client is a DLL pair, not an executable**, and it replaces the game's
   `mss32.dll`. If it is used, the retail library has to be kept as
   `mss32_original.dll` and restored by Remove.
4. **Two different patched builds per game** mean the choice between vanilla and
   CoD1x/UOx changes the executable in the folder, so install and removal have to
   track which build is in place rather than just "client present".
5. Nothing in the scrape says how CoD1 1.5 (the base game after the UO patch) should
   be detected; CB treats the UO folder as "Full Game (1.5 + UO)".
