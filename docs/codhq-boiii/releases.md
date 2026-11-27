# Releases, tags and the installer pin

## The scheme

```
v3.1.0-codhq.11
 │      │      └─ our release number, one per shipped build
 │      └──────── marks this as a CodHQ fork release
 └─────────────── the client build we sit on (Ezz's v3.1.0)
```

`premake5.lua` strips the leading `v` and writes it to `SHORTVERSION`, so the
launcher, the in-game console and Settings → About print `3.1.0-codhq.11`, and
the executable's numeric `FileVersion` stays `3.1.0.<commit count>` because
Windows needs numbers there.

Every `v*` tag triggers `pages.yml`, which builds the tag, publishes the site,
attaches `boiii.exe` + `codhq-boiii.zip` to a GitHub release, and rewrites
`versions.json` from the releases that really carry an `boiii.exe` asset,
newest first by version number. A tag
therefore *is* a release; a tag whose build fails produces no release and no
manifest entry.

## What each release contained

| Tag | Commit | Contents |
| --- | --- | --- |
| `v3.1.0-codhq.1` | `76673d8` | Launcher rebranded as CodHQ BOIII, per-size app icon, first-run card centred, releases named after the client and published as GitHub releases |
| `v3.1.0-codhq.2` | `aacb716` | Version selector offering only our releases; Ezz's builds kept behind a separate, labelled path |
| `v3.1.0-codhq.3` | `90294d1` | Window title is ours; the launcher profile moved out of the game folder |
| `v3.1.0-codhq.4` | `6561292` | Game console and dedicated-server titles carry the CodHQ prefix |
| `v3.1.0-codhq.5` | `b128078` | Our own in-game mark instead of a plain version line |
| `v3.1.0-codhq.6` | `8e6e7a7` | Explain missing game-mode data instead of crashing on it |
| `v3.1.0-codhq.7` | `00742f4` | Warn about a missing mode pack by its common zone (`mp_common`, `zm_common`) |
| `v3.1.0-codhq.8` | `68109a6` | The mode-pack warning is printed after startup, not during component init |
| `v3.1.0-codhq.9` | — | **Deleted.** The tag pointed at a commit whose build never compiled, so no release and no manifest entry existed. It was removed locally and on `origin`; nothing ever referenced it. Do not recreate the number. |
| `v3.1.0-codhq.10` | `19b4a36` | Refuse a level change whose game-mode pack is missing (`map`/`devmap`), plus a crash fix passing the level name as a C string |
| `v3.1.0-codhq.11` | `22d9f88` | Refuse a join the same way before the Workshop checks (`[Party]`), and trim the guard to the one interception that actually fires |

## Re-pinning the installer after a release

`install.ps1` pins the published ZIP by size and SHA-256 and asserts the file
count. After CI has published a tag:

1. Read the published archive's size and SHA-256. CI writes them into the
   release; the same values are what `codhq-boiii.zip` serves.
2. Update the catalog entry for `boiii-codhq` (search for
   `-Id 'boiii-codhq'`):
   `-Archive @{ Url = …; Size = …; Sha256 = '…' }`.
3. Check `-ManifestCount`. It is **196** (the executable plus 195 data files)
   and only changes when the data tree itself gains or loses a file — a
   C++-only release keeps it.
4. Run the tests (see [testing.md](testing.md)) and commit on `dev`.

### Pin history

| Release | ZIP size | ZIP SHA-256 | Manifest entries |
| --- | --- | --- | --- |
| `.10` | 7,382,016 | `10CC845CB27392FA10324FCC34DA55A1839F912ACDE9C7391AA5EE98C813BA2D` | 196 |
| `.11` | 7,381,262 | `93741D93BC69922F4C9963D365C67A62FDBB5EC39C6248E0E25C2BB24405AC87` | 196 |

## Rebuilding a release by hand

CI is the only publisher. If a tag's build fails, fix forward with a new tag
(`.12`, `.13`, …) rather than moving the failed tag: players may already have
downloaded a manifest that points at the old tag's bytes, and a moved tag breaks
the reproducible-build assumption the pin relies on. A dead number is harmless;
a moved tag is not.

## Pin log

Values are appended here each time the installer is re-pinned, so an old install
can always be identified from its `.codhq-client-boiii-codhq.json`.

| Date | Release | ZIP size | ZIP SHA-256 | Exe `FileVersion` |
| --- | --- | --- | --- | --- |
| 2026-11-27 | `3.1.0-codhq.10` | 7,382,016 | `10CC845C…813BA2D` | `3.1.0.3339` |
| 2026-11-27 | `3.1.0-codhq.11` | 7,381,262 | `93741D93…4405AC87` | `3.1.0.3340` |
