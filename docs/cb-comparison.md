# The CB launcher's game cards compared with the Games page

The CB Servers launcher prints the clients each game uses in the corner of its card
(screenshots from the launcher's Library, November 2026). The test
"matches every client the CB launcher shows on its cards" in `tests/install.Tests.ps1`
keeps the catalogue in line with this table.

| CB card | CB shows | Games page clients (catalogue ids) | Match |
| --- | --- | --- | --- |
| Call of Duty | COD1 V1.1 / COD1.1X | CoD 1.1 files (`cod1-v11`), CoD1x (`cod1x`); also Steam's version and retail 1.5 (`cod1-v15`) | yes, plus Steam and 1.5 |
| United Offensive | CODUO V1.51 / CODUO1.51X | UO 1.51 files (`coduo-v151`), UOx (`uox`); also Steam's version | yes, plus Steam |
| Call of Duty 2 | COD2X | CoD2x (`cod2x`) | yes |
| Modern Warfare | IW3X / COD4X / IW3SP-MOD | iw3x, CoD4x, IW3SP-Mod | yes |
| World at War | T4 | Plutonium (t4sp, t4mp) | yes |
| Modern Warfare 2 | IW4X / IW4-SP | IW4x; the campaign through AlterWare's `iw4x-sp` | yes |
| Black Ops | T5 | Plutonium (t5sp, t5mp) | yes |
| Modern Warfare 3 | IW5 / IW5-MOD | Plutonium (iw5mp), AlterWare (`iw5-mod`) | yes |
| Black Ops 2 | T6 / T6SP-MOD | Plutonium (t6mp, t6zm), T6SP-Mod | yes |
| Ghosts | IW6X | IW6x | yes |
| Advanced Warfare | S1X | S1x | yes |
| Black Ops 3 | BOIII | BOIII | yes |
| Infinite Warfare | IW7-MOD | IW7-Mod | yes |
| Modern Warfare Remastered | H1-MOD | H1-Mod (CB's build), H1-Mod (AuroraMod release) | yes, plus a second source |
| World War II | S2X (coming soon) | not in the catalogue | no: CB has not released it, and S2x has no public repository or release |
| Black Ops 4 | PROJECT BO4 | Project BO4 (Shield's official launcher) | yes |
| MW2 Campaign Remastered | H2-MOD | H2-Mod | yes |
| HorizonMW | HMW-MOD | HMW Launcher (HorizonMW's official launcher, which installs `hmw-mod`) | yes |

## Differences in how the files arrive

The clients are the same, but some files reach the player differently from CB:

- CB delivers the CoD1 1.1 and UO 1.51 game files itself. Here they are imported from
  the player's own copy ([cod1-uo-files.md](cod1-uo-files.md)).
- CB delivers Project BO4's executable and LPC data. Here Shield's own launcher
  fetches them.
- CB delivers HorizonMW's content. Here HorizonMW's own launcher does.
