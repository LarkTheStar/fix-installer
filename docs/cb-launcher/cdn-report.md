# CDN, mirrors and update mechanism

From the launcher source (`CBServers/cb-launcher`, branch `main`) and the public
updater repository. Nothing was requested from the game-content paths.

## Hosts

`src/common/utils/cdn.cpp` defines two mirror groups:

| Region | Hosts |
| --- | --- |
| North America | `https://cdn-na.cbservers.dev/`, `https://cdn-na.cbservers.xyz/` |
| Europe | `https://cdn-eu.cbservers.dev/`, `https://cdn-weu.cbservers.xyz/` |

The user can pick a region (Auto, NA or EU) or set a custom CDN URL.

The same hosts serve two different things, told apart by path:

| Path | Content |
| --- | --- |
| `<host>/updater/<client>.json`, `<host>/updater/<client>/<file>` | Client and launcher files, mirrored from GitHub `CBServers/updater/updater/` (`cdn-mirror.yml` syncs it with rclone to the R2 buckets `cbservers-storage` and `cbservers-storage-eu`) |
| `<host>/<game base_folder>/...` (for example `mw2_game_files/`) | Full game content, served by the launcher's "Download game". Never falls back to GitHub. Not used by this installer |

## Mirror order for client files

`src/launcher/updater/update_mirrors.cpp`: for each CDN mirror group (preferred region
first) the launcher tries `<host>updater/`, and GitHub
`https://github.com/CBServers/updater/raw/main/updater/` is always the last source.
Every manifest request carries a cache buster (`?<nanoseconds>`). Each file is fetched
as `<base><folder><url-encoded name>?<SHA-1>`.

The installer uses the same order: CB CDN North America, CB CDN Europe, then GitHub.

## Client manifest format

A JSON array of entries plus a trailing hash object:

```json
[ ["bin/launcher.dll", 2165248, "423789228E83498260F94CDFFB42297E1F743E76", "appdata"],
  ["iw3mp.exe", 3330048, "C160AE5E89222D6930925E3389064D1A1136E157", "game"],
  { "ManifestHash": "25931811C2F2DEBC3D0AAEDE240B9F33B137645C438E1B1062E9657AE9ADA025" } ]
```

- `[path, size, sha1]`, with an optional fourth field `"game"` or `"appdata"` for the destination.
- There are no version numbers: a file is current when its size and SHA-1 match.
- `ManifestHash` (64 hex) identifies the manifest as a whole; the folder-style
  manifests (`h1-mod/files.json`, `iw7-mod/files.json`) and `h2m.json` have none.

Update logic (`client_updater.cpp`): a local file is outdated when it is missing, its
size differs, or its SHA-1 differs. Each download is checked for size and SHA-1 before
it is written. Files the client shipped last time but no longer lists are deleted,
by comparing with a cached copy of the previous manifest (`clients/<id>.json`).

## Game-content manifest format

Shipped inside the launcher update (`manifest/<game>.json`, 18 files listed in
`cb-launcher.json`; recorded in the inventory by name and hash, not fetched). From
`game_updater.cpp`: an object with `ManifestHash`, `files` (`[name, size, hash,
component?]`, component defaulting to `"base"`) and `components` (`{id: {displayName,
required, defaultEnabled, show, totalSize}}`). Downloads resume from
`.<hash>.part` files. An update is needed when the stored `ManifestHash` differs.

## How CB keeps the clients current

`tools/ci/check-upstreams.ps1` in `CBServers/updater` fingerprints each upstream
release or manifest into `tools/upstream/<client>.json` (for example IW4x `r5318`) and
opens bot pull requests on `bot/<client>/<fingerprint>` branches. `tools/upstream/hold.txt`
pauses updates for listed clients. The upstream records are what
[manifests.md](manifests.md) traces each file against.

## The launcher's own update

`cb-launcher.json` (or `cb-launcher-dev.json`) and the `cb-launcher/` folder: the
running exe is renamed to `.exe.old`, the new one is downloaded and started. See
[inventory.md](inventory.md) for every file.
