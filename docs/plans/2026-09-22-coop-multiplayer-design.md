# Co-op Multiplayer — Design

**Date:** 2026-09-22
**Project:** firstPersonSandbox
**Status:** Approved
**Builds on:** `2026-04-13-cooking-game-foundation-design.md` (solo slice) and the
backlog sweep committed 2026-09-22 (ab801ce).

## Decisions

| Question | Decision |
|----------|----------|
| Transport | Steam via GodotSteam 4.22.1 GDExtension (Godot 4.7.2), `SteamMultiplayerPeer` |
| Player count | Up to 4 |
| Authority | Host owns all item physics, cooking, orders and delivery. Each client owns only its own player body |
| Lobby | The lobby is a live **practice kitchen**. Friends join via Steam overlay invite while the host is already playing; host presses Start Run when everyone is in |
| Replication | Godot high-level multiplayer: `MultiplayerSpawner`, `MultiplayerSynchronizer`, `@rpc` |
| Run transition | In-place reset of one persistent kitchen; no scene change |
| Late join | Into the practice kitchen only. The run locks the lobby |
| Host migration | None. Host leaves, everyone goes to the menu |

## Session flow

**Boot.** A `SteamManager` autoload calls `Steam.steamInitEx(480)` and runs
`Steam.run_callbacks()` every frame. If Steam is absent the menu shows
"Steam not detected" and still offers Solo, so the offline path and the
headless smoke test keep working.

**Menu.** Host / Join / Solo.

- **Host**: `Steam.createLobby(LOBBY_TYPE_FRIENDS_ONLY, 4)`, then
  `SteamMultiplayerPeer.create_host(0)`, `multiplayer.multiplayer_peer = peer`,
  load `kitchen.tscn` in `PRACTICE` mode.
- **Join**: only via a Steam invite. `join_requested(lobby, steam_id)` fires on
  the invitee, who calls `Steam.joinLobby(lobby)`; on `lobby_joined` success,
  `create_client(Steam.getLobbyOwner(lobby), 0)` and load the kitchen. The
  host's spawners replay every existing player and item to the new peer.
- **Solo**: no peer at all. `multiplayer.is_server()` is true, every host-only
  branch runs, no RPC is ever sent. Solo is the host path with zero clients.

**Practice kitchen.** `kitchen.tscn` with `mode = PRACTICE`: no timer, no
delivery goal, no end screen. Orders, cooking, delivery and respawn all work
so people can learn the loop. A lobby panel lists connected Steam names and,
for the host only, a **Start Run** button. The pause menu gains **Invite
friends** (`Steam.activateGameOverlayInviteDialog(lobby_id)`). Start Run and
Invite friends live in the Escape menu, because the mouse is captured while
playing.

**Start run.** Host only. `Steam.setLobbyJoinable(lobby, false)`, then
`KitchenNet.start_run()` resets the persistent kitchen in place:

1. free every item under `Items` (the spawner despawns them on clients),
2. teleport every player to its `SpawnPoint` (one reliable RPC to the owning
   peer, since the player node is theirs),
3. refill every `ItemSpawner`,
4. reset `KitchenLoop` (timer, deliveries) and `OrderSystem`,
5. set `KitchenNet.mode = RUN` (synced `on_change`, drives HUD / end screen
   on every peer).

The run ends on the third delivery as today. The end screen shows time and
stars to everyone; **Back to Practice** (host, same reset with
`mode = PRACTICE`, lobby joinable again) or **Leave** (anyone).

**Leaving.** Host `peer_disconnected`: clear `held_by` on anything that peer
held, free their player. Client `server_disconnected`: "Host left" screen,
back to menu. `Steam.leaveLobby` on every exit path.

**Kitchen changes.** Four `SpawnPoint` markers near the door; room stays
12 × 12 m (already big enough); a second egg spawner and plate spawner on the
counter; the pan leaves the scene file and is produced by a third
`ItemSpawner` on the stove so every item enters through the same path. Still
grey-box.

## Replication and authority

### Node layout added to the kitchen

```
Kitchen
├── Players  (Node3D)  + MultiplayerSpawner  spawn_path = Players, spawnable = player.tscn
├── Items    (Node3D)  + MultiplayerSpawner  spawn_path = Items,   spawnable = egg, pan, plate
├── Net      (Node)    KitchenNet: mode, start_run / return_to_practice RPCs, spawn points
└── SpawnPoints (Node3D) SpawnPoint0..3 (Marker3D)
```

Both existing `ItemSpawner`s point `spawn_parent_path` at `Items` and spawn
only when `multiplayer.is_server()`.

### Peer roles

- Host = peer 1. Owns every item, `CookSlot`, `FoodContainer`, `StoveDetector`,
  `DeliveryZone`, `OrderSystem`, `KitchenLoop`.
- Each `Player` sets `set_multiplayer_authority(owner_peer)` in `_enter_tree`
  (before `MultiplayerSynchronizer` initialises). Movement, crouch and camera
  run locally on the owner; the `Camera3D` is `current` only on the owner.
- Client-side items are `RigidBody3D` with `freeze = true`,
  `freeze_mode = KINEMATIC`, so the local capsule still collides with them but
  they only move where the host says.

### Synced properties

Continuous values replicate `always` (unreliable, 30 Hz). Step changes are
`on_change`, which Godot sends reliably, so a dropped packet can never lose a
transition.

| Node | `always` (unreliable, 30 Hz) | `on_change` (reliable) |
|------|------------------------------|------------------------|
| Player | position, rotation.y, head pitch | crouched |
| Egg | transform, cook_progress | state, held_by |
| Pan, Plate | transform | held_by |
| KitchenLoop | elapsed_time | state, deliveries_made |
| OrderSystem | | recipe_tag, required_count |
| KitchenNet | | mode |

Egg colour is derived locally from `cook_progress`. `on_stove` and plate
contents are recomputed on the host only and never synced.

### Held state is a synced property

Every item carries `held_by: int` (peer id, or -1), written only by the host
when it takes or releases the item. Clients react to the property, not to an
RPC:

- the holding client's `GrabController` binds to the item when its own peer id
  appears in `held_by`,
- any client can tint or attach the item visually immediately,
- a late joiner who arrives while someone holds the pan receives `held_by`
  with the replayed node and sees it correctly.

### Client smoothing

First build: each client keeps the last received transform as a target and
lerps the visible body toward it over one network tick; snap if the error
exceeds 1 m (respawn, teleport). Known artefact: a slight "chasing" feel that
never quite settles under jitter. Next step when it shows: buffer the last
two received states and render one tick behind, interpolating between them.

## Interactions across the network

**Grab.** The client's `GrabController` runs its own ray and assist queries
locally against the frozen item copies, so aim forgiveness feels identical to
solo. On a hit it sends `request_grab(item_path)` (reliable, to host). The
host re-validates with the same ray from the requesting player's replicated
camera transform, rejects if `held_by != -1`, otherwise takes the item exactly
as today (gravity off, `held` group, collision exception with the holder's
body) and writes `held_by`. The reply RPC carries only a rejection reason so
the client can play a "taken" cue; `held_by` is the truth.

**Hold.** The pull toward `HoldTarget` runs on the host using the holding
player's replicated head transform. A held item therefore trails a client's
hand by one round trip. Break distance is judged on the host.

**Release / throw.** Reliable RPCs to the host with the client's camera
forward; the host releases or applies the throw velocity.

**Contested grab.** First request to reach the host wins; the loser is
rejected. No tug of war.

**Cooking and delivery.** Unchanged, gated by `multiplayer.is_server()` in
`CookSlot._physics_process`, `DeliveryZone._physics_process`, `KitchenLoop`
and `ItemSpawner`. Clients see cook state only through synced properties.

## Error handling

| Event | Handling |
|-------|----------|
| Steam not running | Menu shows "Steam not detected"; Solo still works |
| `lobby_created` / `lobby_joined` failure | Menu error line, stay on menu |
| Client disconnects | Host clears its `held_by` items, frees its player |
| Host disconnects | Clients: "Host left" screen, back to menu |
| Grab request for an item already held | Reject, reason `TAKEN` |
| Grab request fails host re-validation | Reject, reason `OUT_OF_REACH` |

## Testing

1. **Existing headless smoke test** (`tests/smoke_test.gd`, 95 checks) keeps
   passing with no Steam: proves the solo path (host with zero clients) is
   intact. Item lookups move from the kitchen root to `Items`.
2. **New headless two-peer test** over `ENetMultiplayerPeer` on localhost,
   because GodotSteam cannot run without a Steam client. Two `SceneTree`
   processes, one hosting and one joining, assert that the client: sees the
   egg spawn, sees `cook_progress` advance while the host cooks, sees `state`
   step to `COOKED`, can grab through the RPC path and sees `held_by` set, and
   sees `deliveries_made` increment after a host delivery. A second client
   joining after the first has grabbed the pan sees `held_by` on arrival.
   The transport is swappable, so the replication logic under test is the
   same code Steam runs.
3. **Manual Steam test** on two accounts with App ID 480, launched as a
   Non-Steam Game so the overlay invite works. Checklist in the README.

## Known caveats

- **Host re-validation is distance-only.** The host accepts a grab when the
  item is within `break_distance` of the requester's replicated hold target;
  it does not re-cast the line-of-sight ray, so a modified client could grab
  through thin geometry. Fine for friends-only co-op.
- **Throw direction comes from the replicated head**, one sync tick stale on
  a fast flick, rather than a client-supplied vector.

- **Held-item lag.** Over Steam relay in one region, round trip is typically
  30–80 ms and reads as a slightly loose grip. Measure on the first real test;
  revisit holder-owned physics only if it feels bad.
- **Chasing interpolation.** See Client smoothing.
- **GodotSteam updater plugin** is broken on Godot 4.4+; delete the
  `addons/godotsteam/editors/` folder after install.
- Export must ship `steam_api64.dll` and `godotsteam.dll` next to the exe and
  must not ship `steam_appid.txt`.

## Out of scope

Host migration, voice, text chat, drop-in to a live run, holder-owned
physics, Steam achievements or stats, a public lobby browser, a Steam App ID
of our own.

## References

- GodotSteam 4.22.1 releases: https://codeberg.org/godotsteam/godotsteam/releases
- SteamMultiplayerPeer class: https://godotsteam.com/classes/multiplayer_peer/
- MultiplayerPeer tutorial: https://godotsteam.com/tutorials/multiplayer_peer/
- Lobbies tutorial: https://godotsteam.com/tutorials/lobbies/
- Initializing: https://godotsteam.com/tutorials/initializing/
- Exporting: https://godotsteam.com/tutorials/exporting_shipping/
