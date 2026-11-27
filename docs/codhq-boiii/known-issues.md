# Known issues and open questions

## Open, and the reason

### The test machine has no Steam Multiplayer or Zombies data

`zone/` holds four `mp_*` maps and `zm_castle`, without `mp_common`,
`mp_patch` or `zm_common`. That is a Steam DLC state, not a client bug: the
Multiplayer and Zombies packs are free DLC and have to be ticked in
*Steam → Black Ops III → Properties → DLC*.

Consequence for us: the client's success paths for Multiplayer and Zombies
cannot be exercised here at all. Every "it works" claim in this folder is about
the failure path being readable instead of fatal.

### The in-game server browser is unreachable on this machine

The MP menu data is part of the missing pack, so the browser does not open and a
click-through join cannot be tested. The join was driven through `connect`,
which runs the same `party::connect_stub` the browser uses, so the code path is
covered even though the UI is not.

### A completed join and gameplay were never observed

`connect` against a live server (`45.11.18.111:27019`, 14-player TDM) ends in the
CodHQ `[Party]` missing-pack refusal — the correct outcome *for this install*,
because the map cannot load without the pack. Verified on the shipped `.11`
build. Whether a join completes, loads the map and plays is unverified.

### The missing-pack explanation cannot fix the install

The client refuses the level change or the join and explains which DLC to tick.
It cannot download or install the pack. Do not let this grow into an attempt to
ship Multiplayer content: the data is Steam's and the pack is free there.

## Resolved, but easy to reintroduce

| Issue | Fix | Do not undo |
| --- | --- | --- |
| `-noupdate` froze `data/` as well as the executable | Data still updates; only the executable is skipped | Freezing both mixes versions and crashes menus |
| A level-change guard on `Cmd_ExecuteSingleCommand` | Never fired on this engine build; removed, guard lives on the `map`/`devmap` command wrap | Re-adding the detour hides the guard again |
| Join reported "missing workshop/map dependencies" for a missing DLC | `party` refuses before the Workshop checks with the pack explanation | Players chase a Workshop download they do not need |
| Two builds of one tag produced different bytes | `canonicalize-pe.py` + reproducible linking | The installer pins a SHA-256; drifting bytes break it |
| Upstream sync fetched upstream's *tag* named `main` | Full refspec for `refs/heads/main` | The nightly merge silently stops finding upstream |
| Ezz build selected, then updated with our data | An `ezz:` selection skips **all** updates and logs why | Version mixing crashes |
| Dead tag `v3.1.0-codhq.9` on a commit that never built | Tag deleted locally and on `origin`; nothing referenced it | Do not reuse the number; fix forward with a new tag |

### `versions.json` is not sorted by release number

The list is written in the order the GitHub releases API returns, which is by
*release record creation time*, and `v3.1.0-codhq.10`'s record was created before
most of the others. It therefore appears near the bottom of the selector instead
of second. Nothing is broken (the builds are the right builds), but the order is
wrong. A fix is to sort by the numeric suffix in `pages.yml` before writing the
file; it was not done because it changes the publishing workflow.

### The installer record lags after a client self-update

`.codhq-client-boiii-codhq.json` records the build the installer wrote. When the
client updates itself on start, the record still names the previous archive —
which `Get-GameClientUpdateCount` reads as "an update is available" and repairs
on the next install. That is intended behaviour, not damage.

For the `.11` install the record was reconciled by hand instead
(`Size`/`Sha1`/`Sha256` of `boiii.exe` recomputed from disk, `ArchiveSha256` set
to the pinned archive, `InstalledAt` refreshed), so the game folder's record and
the installed release agree and the installer computes `update needed: False`.
Only the `boiii.exe` entry differed; all 195 data entries were already correct,
because `.11` changed C++ only. A fresh install or repair does the same job.

## Sharp edges worth remembering

- **Never move a published tag.** Players may already hold a manifest that
  points at its bytes, and the installer pins a SHA-256 of the archive.
- **Never commit `AGENTS.md`, `CB.md`, `CHECKPOINT.md` or `HANDOFF.md`** to the
  installer repository; they are local working notes.
- **Do not touch the unstaged `docs/cb-*` files** in the installer repository.
- `install.ps1` must stay pure ASCII, BOM-free and PowerShell 5.1 compatible.
- The `versions/` folder in the game directory is created by the launcher's
  version selector and is empty for an install that runs the installed build;
  an empty folder there is normal, not a broken install.
