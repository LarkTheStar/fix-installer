# Tier III plan: server browser, accounts, friends and community

These features need a real application and a small online service, so they belong to
the native app described in [exe-plan.md](exe-plan.md), step 4. This document is the
plan. Nothing here is built yet.

## 1. Server browser (like the CB launcher's Servers page)

**What the player sees:**

- A game picker with player counts ("94 in servers").
- Then a list per game: server name, map, mode, region, players / max, ping, and a
  favourite star.
- Search over names and maps; **Favorites**, **Hide empty** and **Hide full**
  filters; region and sort ("Most players", ping, name); **Refresh** with "updated
  N seconds ago".
- **Copy** puts `connect ip:port` on the clipboard.
- **Join** starts the game's installed client straight into the server, which the
  launch code already knows how to do per client (`+connect ip:port`, Plutonium's
  `plutonium://play/<id>?ip=...`, BOIII / H1-Mod `+connect`).
- A **Custom server** field for servers not listed.

**Where the lists come from.** Each source is the client project's own public server
list, read the way its client reads it. No private API of another launcher is used;
CB's `/v1/servers` sits behind its own service.

| Game | Source |
| --- | --- |
| CoD4 (CoD4x / iw3x) | the CoD4x master server, then `getstatus` |
| WaW, BO1, BO2, MW3 MP | Plutonium's public server list |
| MW2 (IW4x), Ghosts, AW, BO3, IW, MWR, MW2CR (X Labs / AlterWare / Aurora clients) | each project's master server or JSON server list |
| HorizonMW | its master server (`ms.s2mod.to`, as in `src/client/tcp/hmw_tcp_utils.cpp`) |
| BO4 (Shield) | Shield's public servers are listed in its Discord, not an API. Custom server only, unless Shield publishes a list |
| any game | `gameserve.rs` aggregates most of the above and has an API page. Its terms and rate limits must be confirmed before use; then it can replace several sources at once |

**Ping** is measured from the player's own PC, the same way CB does it:

- one UDP probe per server, `\xff\xff\xff\xffgetinfo xxx`, or `pingreq` for Plutonium;
- at most about 500 servers in batches of 32, with a 1.2-second timeout;
- run on a background thread so the window never freezes.

**Caching:** lists are kept for 30 seconds, and favourites are stored locally.

## 2. Accounts, profiles and friends

These need a backend. The proposal is Freebuff Sites:

- a Cloudflare Worker with a D1 (SQL) database;
- **Sign in with Freebuff** for login, so there are no passwords to store;
- isolated preview and production environments.

| Feature | What it stores / does |
| --- | --- |
| Profile | display name (unique, 3-16 characters), avatar (R2 storage, size-limited), the games the player has, a short bio, created date |
| Friends | requests (send, accept, decline, cancel), friend list, remove, block (blocked users cannot message, invite or see presence) |
| Presence | online / in game / which game and mode / which server (only if the player allows it); sent by the app every 60 seconds while running, expires after 3 minutes |
| Join a friend | from presence: opens the server browser's Join for that server |
| Invite | "Invite to this server" sends a notification with the server address |

Every API checks the signed-in user and scopes data by that user's id. Writes check
the request's origin and are rate-limited.

## 3. Community

| Feature | Notes |
| --- | --- |
| Game rooms | one room per game (and per client where useful): live chat and pinned posts |
| Posts | text and links in a room; replies; edit and delete own posts |
| Looking for group (LFG) | "Playing BO2 Zombies, need 2, server X": expires after 2 hours; Join from the post |
| Direct messages | between friends (and optionally anyone who has not been blocked) |
| Notifications | friend requests, invites, replies, LFG matches |

Realtime chat and presence use Sites realtime rooms. Every message is stored in D1
first, then broadcast, so a reconnect reloads the room from the database.

**Moderation is required before this opens to the public:**

- report on every post, message and profile;
- block;
- per-user rate limits (posts, DMs, friend requests);
- word filter for names;
- room moderators, and an admin view to remove posts and suspend accounts;
- terms of use and a minimum age (13+, or as the hosting region requires);
- a privacy note saying what is stored, plus account deletion that removes the
  player's data.

## Order

1. Server browser, read-only. It needs no backend, so it can ship in the script and
   the exe first.
2. Backend: Sign in with Freebuff, profiles, friends, presence (preview environment).
3. Join a friend and invites.
4. Game rooms and LFG with moderation tools.
5. Direct messages and notifications.
6. Production launch after a moderation and privacy review.
