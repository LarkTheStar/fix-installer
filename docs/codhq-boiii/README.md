# CodHQ BOIII — the Black Ops III client fork

This folder is the working memory for our Black Ops III client, so the next
session does not have to rediscover any of it. It is documentation only: nothing
here is read by the installer or by the game.

- **Fork:** <https://github.com/LarkTheStar/codhq-boiii> (branch `codhq-rebrand`)
- **Upstream:** <https://github.com/Ezz-lol/boiii-free> (`main`, GPL-3.0)
- **Update site:** <https://larkthestar.github.io/codhq-boiii/>
- **Installer side:** `install.ps1`, catalog entry `boiii` → client `boiii-codhq`
- **Local checkout:** `dist/codhq-boiii`

## What it is

`boiii` is a community client for Black Ops III: it launches `BlackOps3.exe`,
serves the multiplayer and Zombies menus, hosts and joins servers outside
Activision's matchmaking, and loads mods and custom maps. It is a DLL-style
client that sits next to the game, not a replacement for the game: the retail
`BlackOps3.exe`, `zone/` and `video/` stay exactly where Steam put them.

Our fork takes Ezz's client and adds CodHQ's branding, a handful of crash fixes
and quality-of-life changes, our own update site, and a versioning scheme that
says out loud which client build a download sits on.

## Read in this order

| File | What it answers |
| --- | --- |
| [how-it-works.md](how-it-works.md) | How the client, the updater, the site, CI and the installer fit together |
| [changes.md](changes.md) | Every change we made to the fork, grouped, with the reason |
| [upstream-and-provenance.md](upstream-and-provenance.md) | What is Ezz's, what is ours, how the nightly sync works, licensing |
| [releases.md](releases.md) | Tag scheme, what each `-codhq.N` release contained, installer pin values |
| [testing.md](testing.md) | How to prove a build on a real install, and what "passing" looked like |
| [known-issues.md](known-issues.md) | Open problems, and what was never verified |

## Current state

`v3.1.0-codhq.11` is published, pinned in `install.ps1`, and installed in the
game folder (executable `3.1.0.3340`, SHA-256 `49f9c7da…`). It was launched from
that folder and reported `CodHQ BOIII V3.1.0-codhq.11` in its own console title,
with the `[Com]` level guard and the `[Party]` join refusal both observed. The
install has no Steam Multiplayer/Zombies DLC, so a successful join remains
untested — see [testing.md](testing.md).

## Short version of the history

1. Started as a rebrand of Ezz's client: our name, our version line, our icon.
2. The updater pointed at Ezz's R2 bucket. We cut that and published our own
   site from GitHub Pages out of this repository, so every build a player runs
   came from our own CI.
3. Players with an incomplete Steam install (no Multiplayer DLC, or no
   Zombies DLC) crashed when they tried to start a match. We could not ship the
   missing data, so the client now explains what is missing and refuses the
   action instead of faulting.
4. Releases were named `v0.2.x`, which said nothing about the client inside.
   They are now `v3.1.0-codhq.N`: the client base plus our release number.
5. A version selector came back, but it only offers our releases; Ezz's builds
   live behind a clearly separated, clearly labelled second path.
