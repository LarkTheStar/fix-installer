# How the CodHQ BOIII fork works

## The pieces

| Piece | Where | What it does |
| --- | --- | --- |
| The client | `dist/codhq-boiii/src` | Hooks `BlackOps3.exe`, adds the launcher, server browser, mod support, updater |
| The data tree | `dist/codhq-boiii/data` | Launcher UI, `scripts/`, `ui_scripts/`, `lua/`, `custom_scripts/`, `lookup_tables/`, `gamesettings/` |
| The build | `premake5.lua` + ninja | Generates `src/version.h`, links `boiii.exe` |
| The update site | `gh-pages` branch of our repo | `boiii.json`, `boiii/`, `codhq-boiii.zip`, `versions.json` |
| The publisher | `.github/workflows/pages.yml` | Builds on every `v*` tag, makes the ZIP/manifest, creates the release, republishes the site |
| The upstream sync | `.github/workflows/sync-upstream.yml` | Nightly merge of Ezz's `main`, built before it is proposed |
| The installer | `install.ps1` | Downloads the ZIP, verifies it, writes the client and data, records what it wrote |

## Where files live on a player's machine

- `boiii.exe` — next to `BlackOps3.exe`, in the game folder. The only file the
  installer writes into the game folder.
- `%LOCALAPPDATA%\boiii\data\` — the data tree (UI, scripts, lua, tables).
- `%LOCALAPPDATA%\boiii\user\` — the player's profile: name, launch options.
- `%LOCALAPPDATA%\boiii\minidumps\` — crash dumps written by our crash handler.
- `%LOCALAPPDATA%\boiii\versions\` — builds downloaded by the launcher's version
  selector (empty when the player runs the installed build).
- `<game folder>\.codhq-client-boiii-codhq.json` — what the installer wrote,
  with per-file size and SHA-256. `.codhq-backups\` holds what it replaced.
- `BlackOps3.exe.boiii_backup` — the player's original game executable, if the
  client installed the compatible one for them.

## The update loop

`src/client/updater/file_updater.cpp` hardcodes one server:

```cpp
#define UPDATE_SERVER "https://larkthestar.github.io/codhq-boiii/"
#define UPDATE_FILE_MAIN UPDATE_SERVER "boiii.json"
#define UPDATE_FOLDER_MAIN UPDATE_SERVER "boiii/"
```

On every start, unless `-noupdate` is passed:

1. Fetch `boiii.json` with a cache-buster, so a CDN never serves a stale list.
2. The manifest is a list of `[path, size, sha1]`. Compare all **196** entries
   (`boiii.exe` plus 195 files under `data/`).
3. Download only the entries whose SHA-1 differs.
4. Replace `boiii.exe` (from `boiii/boiii.exe`) and restart the client; data
   files are written straight into `%LOCALAPPDATA%\boiii\data\`.

The client never touches `zone/`, `video/`, `BlackOps3.exe`, or anything else
that Steam owns. Verifying the game in Steam cannot break the client, and the
client cannot break the game.

`-noupdate` skips the executable **but still refreshes the data files**. That is
deliberate: a stale `data/` against a newer client is exactly the version mixing
that produces menu crashes. Before that behaviour was fixed, `-noupdate` also
froze the data, which is how a "why is my UI old" bug appeared.

A build selected from the *Ezz* path (`ezz:<tag>`) skips **all** updates, not
just the executable, and logs why. Running Ezz's binary against our freshly
updated `data/` would mix two versions of the UI, which is a crash waiting to
happen.

## The site

`pages.yml` runs on `windows-latest` for every tag matching `v*`:

1. Check out with submodules, set up LLVM 23, install premake5 (VS 2026).
2. `premake5 ninja`, `ninja Release_x64 -Cbuild`.
3. `tools/canonicalize-pe.py` makes the build reproducible: same sources, same
   bytes, so two builds of a tag produce one SHA-256.
4. Stage `site/boiii/` = `boiii.exe` + `data/`, then write `site/boiii.json`
   (`[path, size, sha1]`, `boiii.exe` first).
5. `tools/make-archive.py` packs `site/codhq-boiii.zip` deterministically.
6. Create or update the GitHub release for the tag with `boiii.exe` and
   `codhq-boiii.zip` attached, and `--generate-notes`.
7. Write `site/versions.json` from our releases that actually carry a
   `boiii.exe` asset — so the launcher's version list can never offer a dead
   download, and can never list Ezz's releases.
8. Publish `site/` to `gh-pages` with peaceiris/actions-gh-pages.

## The installer side

The catalog entry lives in `install.ps1` under the Black Ops III game
(`Id = 'boiii'`, client `boiii-codhq`):

```powershell
-Archive @{ Url = 'https://larkthestar.github.io/codhq-boiii/codhq-boiii.zip'
            Size = 7382016
            Sha256 = '10CC845C…' }
-ManifestCount 196
-AppData 'boiii'
-GameFiles @('boiii.exe')
-Allow @('boiii.exe', 'data/*')
```

- The ZIP is pinned by **size + SHA-256 of the whole download**.
- Every file inside is checked against `boiii.json` from the same site, before
  and after writing; a mismatch puts back what was there.
- `ManifestCount` is asserted: a ZIP with more or fewer files than the manifest
  says is refused, which catches a truncated or half-published release.
- `ExeCheck` on `BlackOps3.exe`: PE checksum `0x6531394`. If the player's game
  executable is a different build, the client offers the compatible one, keeps
  theirs as `BlackOps3.exe.boiii_backup`, and Steam's *Verify integrity* undoes
  it. The client never silently replaces it.
- Modes: `play` runs `boiii.exe -launch`, `launcher` runs `boiii.exe` with no
  arguments so the player can set their name and options. The client has no
  `-name` argument; the name lives in its own profile.

After a release, the pin must be re-synced by hand. Procedure and the values to
update are in [releases.md](releases.md).

## The build a player sees

`premake5.lua` writes `src/version.h` on every generate:

| Macro | Example | Used for |
| --- | --- | --- |
| `GIT_DESCRIBE` | `v3.1.0-codhq.11-0-g22d9f88` | full describe |
| `SHORTVERSION` | `3.1.0-codhq.11` | what the launcher, the console and Settings → About print |
| `VERSION_PRODUCT_RC` | `3,1,0` | Windows product version |
| `VERSION_FILE_RC` | `3,1,0,3339` | Windows file version (numeric, so the commit count) |

`SHORTVERSION` comes from the nearest tag, minus the leading `v`
(`release_version()`), so a release carries the name of the release. A checkout
with no tag falls back to the numeric product version.

The PE reports `ProductName: CodHQ BOIII`, `CompanyName: CodHQ`,
`FileDescription: CodHQ BOIII launcher and client`, and a copyright line that
credits Ezz and states the GPL-3.0 fork relationship.
