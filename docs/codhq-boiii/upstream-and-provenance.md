# Provenance: what is Ezz's, what is ours, and how they stay apart

## The two repositories

| | Upstream | Ours |
| --- | --- | --- |
| Repository | `Ezz-lol/boiii-free` | `LarkTheStar/codhq-boiii` |
| Branch we follow | `main` (`4e60eb52` is our merge base) | `codhq-rebrand` |
| Licence | GPL-3.0 | GPL-3.0 (unchanged, and we publish our source) |
| Builds published by | Ezz (R2 bucket + his GitHub releases) | our CI, from our tags, to our Pages site |

The fork is 40 commits ahead of `4e60eb52`. Everything in
[changes.md](changes.md) is that delta; everything else — the hooking layer, the
launcher, server browser, mod loading, GSC additions, the updater's core loop —
is Ezz's work and is left alone unless a change is listed there.

## What we deliberately took from others

1. **Ezz's client.** The whole base. Credited in the PE copyright line
   (`BOIII Copyright (C) 2026 Ezz. CodHQ BOIII is a fork under GPL-3.0.`), in the
   README, and in the `v3.1.0` part of every release tag.
2. **CB's `+set` fix.** CB's BOIII fork had already solved command-line `+set`
   parsing. We ported that fix instead of re-deriving it; the fork records
   exactly what was taken in `docs/cb-fork-port.md`.

Nothing else was copied in. Anything that looked like a good idea from another
launcher was reimplemented, not lifted.

## What we did *not* take

- **CB's build.** `install.ps1` used to offer CB's BOIII fork and no longer
  does: it was CB's own build with CB's own patches, which is not ours to
  redistribute as a CodHQ client. The catalog comment says so where someone
  would look for it.
- **Ezz's published binaries as our main download.** They remain reachable
  through the *Builds from the original creator…* path in the launcher, stored
  as `ezz:<tag>` and labelled in a warning colour, but the main dropdown offers
  only our releases. A player who picks one gets exactly his file, unmodified,
  with a warning that none of our fixes or branding are in it — and the client
  then skips **all** updates so his binary never runs against our `data/` tree.

## The nightly sync

`.github/workflows/sync-upstream.yml`, 03:41 UTC daily:

1. Check out our `codhq-rebrand` with submodules and full history.
2. Fetch upstream `main` by full ref name (a short refspec matches upstream's
   *tag* named `main` instead of the branch — this bit us once).
3. If upstream is already an ancestor, stop (`state=current`).
4. Otherwise switch to `sync/upstream`, merge upstream, and **build it with the
   same toolchain the release uses**.
5. A merge that builds opens a pull request. A merge that fails becomes an
   issue and the branch is kept for whoever resolves it.

Nothing is merged into `codhq-rebrand` automatically. Our patches touch engine
offsets and hook signatures, so every merge has to be read before it lands, and
a green build only proves it compiles.

## Why keeping the paths apart matters

Running Ezz's binary against our `data/` tree is version mixing: his client
expects his UI files, ours expects ours. That is a reliable crash. The split
exists so a player can still get his build deliberately, while never getting it
by accident — and so that anything they run with our name on it really is ours.
