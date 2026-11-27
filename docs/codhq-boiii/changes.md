# What we changed in the fork

Everything below is ours, on top of Ezz's `main` (base commit `4e60eb52`). As of
`v3.1.0-codhq.11` the fork is **40 commits ahead**. Grouped by purpose, because
the commit list alone does not say why any of it exists.

## 1. Branding

| Change | Commit |
| --- | --- |
| Show `CodHQ BOIII` as the client's name and version | `44c5f8b` |
| Rebrand the launcher as CodHQ BOIII, move the launcher profile | `76ca944`, `90294d1` |
| Centre the first-run button, draw the app icon per size | `5ea6eb2` |
| Give the game console and server titles the CodHQ prefix | `6561292` |
| Draw our own in-game mark instead of a plain version line | `b128078` |
| PE metadata: product, company, description, copyright crediting Ezz + GPL-3.0 | `44c5f8b` |

The launcher window, the in-game console title, dedicated-server titles and the
small mark in the corner all read `CodHQ BOIII`. The copyright line keeps Ezz's
name and states that this is a GPL-3.0 fork, which it is.

## 2. Our own update path (the big one)

| Change | Commit |
| --- | --- |
| Point the updater at our Pages site | `a606573` |
| Publish our own build from GitHub Pages | `b0e02a1` |
| Drop the upstream R2 publishing workflows | `915b144` |
| Publish a landing page so the site root is not a 404 | `ee8160f` |
| CI publishes a full archive next to the manifest | `e49a3a1` |
| Publish the same bytes when a tag is built twice | `83c0d8f` |
| Link reproducibly so a rebuild gives the same bytes | `832017f` |

Before this, `file_updater.cpp` fetched Ezz's manifest from his R2 bucket: our
players would have downloaded *his* executable and *his* data, and any number of
people could have. Now the client only ever updates from
`https://larkthestar.github.io/codhq-boiii/`, built by our CI from this
repository, pinned by the installer. Nothing a player runs comes from anywhere
else.

Making the build reproducible was required, not cosmetic: the installer and the
manifest both pin bytes, so two builds of one tag had to produce one hash.

## 3. Never touching the player's game executable

| Change | Commit |
| --- | --- |
| Never replace the player's `BlackOps3.exe` | `55868e4` |
| README: say the game executable is never replaced | `29ae352` |
| Offer the compatible `BlackOps3.exe` instead of refusing to start | `5a8286e` |
| Document it | `docs/blackops3-executable.md` |

The client needs one specific build of `BlackOps3.exe` (PE checksum
`0x6531394`). Earlier behaviour refused to start on anything else, or replaced
the file. Now: refuse silently never, offer explicitly always, back up the
original as `BlackOps3.exe.boiii_backup`, and tell the player that Steam's
*Verify integrity* restores it.

## 4. `-noupdate` meant two different things

| Change | Commit |
| --- | --- |
| Skip the executable when `-noupdate` is set | `5ddb31e` |
| Let `-noupdate` keep updating the data files | `fa08e8e` |

`-noupdate` now means "do not replace the executable" and *not* "freeze
everything". Freezing `data/` as well left players with old UI and old scripts
against a newer client — a crash source we created ourselves and then removed.

## 5. Crash and dead-end fixes

| Change | Commit | Problem it solved |
| --- | --- | --- |
| Name a missing data file instead of starting with broken menus | `a9e2d78` | A partial `data/` gave a menu with unclickable entries and no message |
| Name the proxy DLL, WinDivert or GoodbyeDPI that redirects the game | `10f248e` | A network shim broke the connection and nothing said so |
| Say why the Zombies entry cannot start instead of dead-ending | `d07d9b9` | Zombies with no Zombies data did nothing at all (#410) |
| Report a mod whose UI script the client shadows | `efb8d4e` | A mod's UI silently lost to ours (#392) |
| Load a gametype's settings when a dedicated server rotates to it | `6db8cb4` | Rotation kept the previous gametype's settings (#415) |
| Clamp repeated console output so a warning cannot flood it | `0141a26` | A repeating warning ate the console and the frame time (#339) |
| Remove the last catch of the deleted patch installer | `5f89293` | Dead code that could still swallow an error |

## 6. The missing game-mode pack work (the latest releases)

This is the family of changes behind `v3.1.0-codhq.6` … `.11`, and it is the
part most worth understanding later.

**The problem.** A player whose Steam install has no Multiplayer DLC (or no
Zombies DLC) has no `zone/mp_common.ff`, `zone/mp_patch.ff`, `zone/zm_common.ff`
and no `mp_*` zone files worth speaking of. Ask the engine to load
`mp_rise` in that state and it walks into a null asset while loading fast files,
or faults in the lobby code before it gets that far. The player sees a crash and
a dump, not an explanation — and the crash looks like our bug, not a missing DLC.

**What we did.**
- `explain_missing_mode_for_level()` / `missing_mode_for_level()` in
  `error_help.cpp` map a level name to the pack its mode needs
  (`mp_*` → Multiplayer, `zm_*` → Zombies, `cp_*` → campaign) and check whether
  that mode's common zone is actually installed.
- A missing pack is now explained in the console and in a toast, with the exact
  Steam path to fix it: *right-click Black Ops III → Properties → DLC → tick the
  pack*.
- The level-change guard was first put on `Cmd_ExecuteSingleCommand` via a
  detour. **That detour never fires on this engine build.** Instrumentation
  proved it: only the registered `map`/`devmap` command functions run. So the
  detour was deleted and the check now lives in the one command-pointer wrap
  that does fire (`com.cpp`, `run_level_command`).
- `party::handle_connect_query_response` refuses a join the same way, *before*
  the Workshop checks. Previously a join with a missing pack said "Missing or
  invalid workshop/map dependencies", which sent players looking for a Workshop
  download they did not need.
- The shared refusal is `error_help::refuse_missing_mode_for_level(level, tag)`,
  used with tag `Com` for a local level change and `Party` for a join.

**What it does not do.** It does not install the missing data and it does not
invent Multiplayer content. It turns a crash into a readable sentence, which is
the most a client can honestly do when the DLC is absent.

## 7. Version scheme and releases

| Change | Commit |
| --- | --- |
| Name releases after the client build, publish them as GitHub releases | `76673d8` |
| Bring back the version selector for our builds, keep Ezz's apart | `aacb716` |

`v0.2.x` was our own counter and said nothing about what was inside. Now a tag
is `v<client base>-codhq.<n>`, and `SHORTVERSION` carries it into the launcher.
See [releases.md](releases.md).

## 8. Ported from CB's fork

| Change | Commit |
| --- | --- |
| Port CB's command-line `+set` fix, record the port matrix | `2b90298` |
| Document it | `docs/cb-fork-port.md` |

CB's BOIII fork fixed the way `+set` arguments were parsed from the command
line. We ported that fix rather than re-deriving it; `docs/cb-fork-port.md` in
the fork records exactly what was taken and what the port covers.

## 9. Build and maintenance docs

| Change | Commit |
| --- | --- |
| Document the build prerequisites and the upstream sync | `0216c9b` |
| Merge upstream nightly, build it before proposing it | `0c86bb9` |
| Fetch upstream by its full ref name in the sync workflow | `dc4e6ab` |
| Format the checkout and branding changes with clang-format | `4daa67d` |
| Format the lobby rotation guard the way stylua expects | `3489e3e` |

The sync workflow has one non-obvious fix: upstream also carries a **tag** named
`main`, so a short refspec fetched the tag instead of the branch and left no
`upstream/main` to merge. It now fetches
`+refs/heads/main:refs/remotes/upstream/main` explicitly.
