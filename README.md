# firstPersonSandbox

A PEAK-style first-person cooking sandbox built on Godot 4.7. Contains a
vertical slice where players cook a fried egg and deliver it to the pass, solo
or in Steam co-op for up to four.

## Status

- **Solo slice complete.** The cook loop (grab, cook, plate, deliver, respawn)
  runs end to end in the grey-box kitchen.
- **Backlog sweep done 2026-09-11:** crouch, grab assist, pan and plate rims,
  dedicated physics layers, `Groups` constants, `egg.seconds` overlay watch,
  plate-on-pan no longer re-cooks, per-spawner respawn under the kitchen root,
  `state_changed` listener, dot crosshair, and a 95-check headless smoke test
  (94 pass, 1 documented expected failure).
- **Co-op built 2026-09-23 on branch `coop`:** Steam lobbies via GodotSteam,
  up to 4 players, host-authoritative physics, practice kitchen lobby,
  in-place run reset, two-peer ENet regression test.
- **Next candidates:** recipe variety, art pass, holder-owned physics if
  held-item lag bites.

## How to run

Open the project in Godot 4.7 and press F5. The menu loads; click **Play >
Solo** to enter the kitchen alone, or **Play > Multiplayer > Host via Steam**
to start a co-op session (Host is greyed out when Steam is not detected; the
status line under the buttons says why). There is no Join button: guests join
by accepting a Steam invite. Escape steps back one page.

### Co-op setup

Solo play and the automated tests need none of this. For Steam sessions:

1. Download GodotSteam 4.22.1 (GDExtension build) from
   https://codeberg.org/godotsteam/godotsteam/releases — tag `v4.22.1-gde`,
   asset `godotsteam-4.22.1-gdextension-plugin-4.4.zip` — and unzip it so
   that `addons/godotsteam/godotsteam.gdextension` exists. `addons/godotsteam/`
   is git-ignored, so every clone installs it separately.
2. Delete `addons/godotsteam/editor/` (its updater plugin is broken on Godot
   4.4+) and do not enable the "GodotSteam Updater" plugin.
3. Godot only loads extensions listed in `.godot/extension_list.cfg`, which
   the editor writes on its filesystem scan. On a fresh clone open the
   project once in the editor, or create that file containing
   `res://addons/godotsteam/godotsteam.gdextension`, before headless or
   exported runs can see Steam.
4. `steam_appid.txt` (App ID 480, Valve's test app) is committed for
   development. Steam must be running and logged in when the game starts.
5. For the overlay (invites), add the game as a Non-Steam Game: Steam > Add a
   Game > Add a Non-Steam Game, pointing at the Godot exe with
   `--path C:\Projects\firstPersonSandbox` as launch options, or at an
   exported exe.
6. Exports ship `steam_api64.dll` and
   `libgodotsteam.windows.template_release.x86_64.dll` from
   `addons/godotsteam/win64/` next to the exe, and must not ship
   `steam_appid.txt`.

## How to play (the cook loop)

1. Pick up the raw egg from the counter (E).
2. Walk up to the stove, keep the view roughly level, and press E again to
   drop the egg into the pan.
3. Wait ~4 seconds for it to cook. Color shifts white to golden as it progresses.
4. Pick up the pan or the cooked egg and transfer the egg onto a plate.
5. Place the plated meal onto the Pass counter — release the plate inside the
   delivery zone.
6. A fresh plate and egg respawn automatically. Repeat; after the third
   delivery the end screen shows your time and star rating.

### Co-op

1. Host presses **Host with Steam**. The kitchen loads in practice mode: no
   timer, no delivery goal, everything else works. The lobby panel top-right
   reads `PRACTICE` and lists the players.
2. Host presses Escape > **Invite friends** and invites from the Steam
   overlay dialog. Guests accept from the overlay or their friends list and
   land in the same kitchen.
3. Practice together. The HUD shows `Practice  Delivered: N` and `--:--`.
4. When everyone is in, host presses Escape > **Start Run**. Everyone
   teleports to the door, items reset, the lobby locks and the HUD switches
   to `Delivered: N/3` with a timer.
5. After the third delivery the end screen shows on every peer. Host has
   **Play Again** and **Back to Practice** (reopens the lobby); anyone can
   **Leave**. If the host quits, guests return to the menu with `Host left`.

## Controls

| Input    | Action                          |
|----------|---------------------------------|
| WASD     | Move                            |
| Mouse    | Look                            |
| Space    | Jump (not while crouched)       |
| Ctrl / C | Crouch (hold)                   |
| E        | Grab / release held item        |
| F        | Throw held item                 |
| Escape   | Pause menu (solo) / session menu with Invite and Start Run (online, host only) |
| F3       | Toggle debug overlay            |

Grabbing is forgiving: if the centre dot narrowly misses a small item, a
short sphere sweep along the aim line (`grab_assist_radius`, default 0.12 m)
still picks it up, provided the item is in line of sight. Toggle it with
`grab_assist_enabled` on the `GrabController`.

## Debug overlay

Press F3 to toggle. Twelve watched values:

- `held` — currently held body name, or `<none>`
- `crouched` — `true` while the player is crouched
- `egg.state` — `RAW` / `COOKING` / `COOKED` / `BURNED` (from the first food
  item found in the `food` group)
- `egg.seconds` — real seconds of heat the egg has received (`%.1fs`), from
  `FoodItem.cook_elapsed_seconds()`: `cook_duration` + `burn_duration` at
  BURNED (8.0s by default)
- `egg.progress` — the same value normalized 0..2 (0..1 is the cook phase,
  1..2 is the burn phase); this is what drives state and colour
- `pan.on_stove` — `true` / `false`
- `plate.contents` — comma-separated list of food items resting on the plate
- `order` — current order text from `OrderSystem`
- `net.role` — `OFFLINE` (solo) / `HOST` / `CLIENT`
- `net.peer` — this peer's multiplayer id (`1` for the host and for solo)
- `net.players` — number of player bodies under `Players`
- `net.mode` — `PRACTICE` / `RUN`, from `KitchenNet`

## Automated tests

### Headless smoke test

`tests/smoke_test.gd` (entry point; the checks are in
`tests/smoke_test_body.gd`) loads the kitchen headless, drives the items by
teleporting them and asserts the whole loop — no editor, display or addons
needed. Run it with the Godot **console** build (`<Godot console exe>` is e.g.
`Godot_v4.7.2-stable_win64_console.exe`; `<project>` is the folder holding
`project.godot`, so `.` from the repo root):

```sh
"<Godot console exe>" --headless --path <project> --script res://tests/smoke_test.gd
```

It prints one `PASS` / `FAIL` / `XFAIL` line per check and a `SUMMARY` line,
takes about 25 s, and exits non-zero (`1`) if any check fails or the 180 s
watchdog trips. The 95 checks are:

- `boot.*` (5) — kitchen loads and is wired; exactly one egg, plate, pan and
  stove; egg `RAW`; pan on the stove; nothing held
- `cook.*` (5) — `RAW` to `COOKING` to `COOKED` at one 1/60 s tick per physics
  frame; a loose egg stays inside the rimmed pan
- `pause.*` (4) — progress freezes while the pan is off the stove and resumes
  when it returns
- `burn.*` (3) — `BURNED` after `cook_duration + burn_duration`; progress
  clamps at 2.0 and stays there
- `no_deliver_burned.*` (4) — a burned egg on a plate in the zone is rejected
  and nothing is freed
- `deliver.*` (8) — a cooked egg delivers; plate and egg are freed; one new
  plate and egg respawn under the `Kitchen` root and fill their spawner
  slots; `deliveries_made` counts
- `held_no_deliver.*` (6) — a plate in the `held` group never delivers; it
  delivers once released
- `grab.*` (12) — `interact` grabs the egg in front of the camera and `throw`
  releases it fast; with grab assist off an off-axis egg is missed, with it
  on the same aim grabs; an egg hidden behind the Pass counter cannot be
  grabbed through it
- `crouch.*` (8) — holding `crouch` lowers the head and shrinks the capsule
  with its bottom fixed; releasing restores both
- `plate_on_pan.*` (9) — a plated cooked egg set on the stove pan does not
  cook, and resumes once it leaves the plate
- `carry.*` (5) — a grabbed pan leaves the stove and stops cooking its egg;
  `carry.pan_keeps_egg` is an **expected failure** (the grab snap throws the
  egg out, see Known limitations)
- `grab.break_*` (4) — a held item past `break_distance` is dropped
- `release.*` (4) — standing at the stove with a level view, a released egg
  drops into the pan and cooks
- `throw.*` (3) — an egg thrown at a wall bounces instead of tunnelling out
- `crouch.blocked_*` (4) — a low ceiling keeps the player crouched until it
  is clear; a held item never does
- `held_egg.*` (4) — an egg held over a plate in the zone is not delivered
  until released
- `occupied.*` (6) — a delivery while a fresh egg still sits in its slot does
  not spawn a second one

Determinism notes, per-check details and how to add a check: `tests/README.md`.

### Two-peer net test

`tests/run_net_test.ps1` launches `tests/net_test.gd` (a launcher for
`tests/net_test_body.gd`, split for the same reason as the smoke test) twice
over `ENetMultiplayerPeer` on localhost port 7777 — one host, one client — so
the replication code runs without Steam. The host gets a 4 s head start;
each half has a 120 s watchdog.

```sh
powershell -ExecutionPolicy Bypass -File tests/run_net_test.ps1
```

The script prints the merged `PASS` / `FAIL` / `SUMMARY` lines of both halves
(stdout goes to `%TEMP%\net_test_host.log` and `net_test_client.log`, Godot's
stderr to the matching `.err.log` files) and ends with `NET TEST PASSED` or
`NET TEST FAILED`. The 34 checks split into 11 `host.*` and 23 `client.*`:
the host follows a scripted timeline (listen, hold the plate before the client
joins, cook the egg, park it on the counter, wait for the client's grab and
release, deliver, start the run, wait for the client to leave) while the
client asserts what it sees replicated — its own player spawned with
authority and the host's without, the egg frozen and parented under `Items`,
`cook_progress`, state and position arriving, the plate reported `held_by`
the host on late join, a grab on that plate rejected as `TAKEN`, its own grab
and release round-tripping through the RPCs, names and practice mode on
join, the delivery count, the mode switch, the teleport on run start and the
timer ticking. Per-check table: `tests/README.md`.

### Menu test

`tests/menu_test.gd` (launcher for `tests/menu_test_body.gd`, split like the
others) instantiates `scenes/menu.tscn` headless and drives the buttons by
emitting `pressed`. Its 16 checks cover the page flow (Main > Play > Solo /
Multiplayer > Host via Steam, and Back on each page), that the Solo, Host and
Quit buttons are wired, the Host button's label, the offline status line, and
the background diorama (present, three chefs, its camera is current, and at
least two chefs have moved after 90 frames). Steam is never available
headless, so it also asserts Host is disabled. No addon or display needed; it
runs in a few seconds.

```sh
"<Godot console exe>" --headless --path <project> --script res://tests/menu_test.gd
```

## Manual smoke test

Run this after any meaningful change to verify the slice end-to-end.

1. Load the kitchen scene. Confirm: egg on the counter, plate on the plate
   rack, pan on the stove, order board reads `1x egg(COOKED)`, F3 toggles the
   debug overlay, crosshair is visible.
2. Grab the egg, drop it in the pan. Watch `egg.state` progress from `RAW` to
   `COOKING` to `COOKED` over ~4 seconds.
3. Keep waiting. Watch it continue to `BURNED` over another ~4 seconds.
4. Lift the pan off the stove mid-cook. Confirm `egg.progress` pauses while
   `pan.on_stove` is `false`, and resumes when the pan is returned.
5. Plate a cooked egg and deliver it by setting the plate down inside the
   delivery zone on the Pass counter.
6. Verify a fresh plate and egg respawn after delivery.
7. Throw (F) an egg into a wall. It should bounce, not tunnel through.
8. Try to deliver a burned or raw egg on a plate. No delivery should fire;
   the plate stays where it is.
9. Carry a held plate through the delivery zone without releasing it. It must
   NOT deliver while held.
10. Plate a cooked egg, then set the plate down on the pan while the pan is on
    the stove. `egg.seconds` must stay put and the egg must not burn.
11. Hold Ctrl (or C) next to an egg lying on the floor. The view drops from
    1.7 m to 1.1 m, the dot lands on the egg easily and E picks it up. Space
    does nothing while crouched.
12. Stay crouched and push into the north wall directly under the order board
    (the kitchen has no counter overhang; the board's underside at 1.9 m is
    the only low ceiling). Release Ctrl: `crouched` stays `true` until you
    back out from under the board, then you stand up.
13. Aim a hand's width beside the egg, not on it, and press E: it still
    grabs. Set `grab_assist_enabled` to `false` on the `GrabController` and
    repeat: the same aim misses.
14. Put the egg on the floor tight against the far side of the counter, stand
    on the near side and aim through the counter at the spot where you left
    it, then press E: nothing is grabbed, because the assist rejects an item
    the camera cannot see. (A dead-on hit with the precise centre ray can
    still grab through geometry — see Known limitations.)
15. Drop the egg in the pan, grab the pan and carry it around at a brisk walk.
    The egg stays inside the rim instead of rolling off. Hold the pan above
    the plate and look down to tilt it: the egg slides over the rim onto the
    plate.

## Manual Steam test

Two machines (or one PC plus a VM), each with Steam running and logged in to
a different account; the accounts must be Steam friends. Set both up per
**Co-op setup** above, including the Non-Steam Game entry so the overlay
works. Record the result in the table below.

- Relay warm-up: SteamManager calls initRelayNetworkAccess() after init; if
  the first guest connect still times out, wait ~10 s after both games start
  and retry the invite.

Accepting an invite while the game is closed launches it with
`+connect_lobby <id>` on the command line and the game joins automatically,
so step 4 also works from a cold start.

1. Both launch the game. Menu status line shows `Steam ready as <persona name>`.
2. Host presses **Host with Steam**. Kitchen loads in practice mode; lobby
   panel top-right shows `PRACTICE` and the host's name.
3. Host presses Escape > **Invite friends**; Steam overlay invite dialog
   opens; invite the second account.
4. Guest accepts the invite (overlay or Steam friends list). Guest's kitchen
   loads; both panels list both names; guest sees the host's capsule, the
   egg, pan and plate. F3 on the guest shows `net.role: CLIENT`.
5. Guest picks up the egg (E). Host sees it lift. Guest drops it in the pan;
   both see it cook (colour shift), F3 `egg.state` agrees on both.
6. Host holds the plate, guest tries E on it: nothing happens on the guest
   (rejected as taken).
7. Guest plates a cooked egg and sets it on the Pass. Both HUDs show
   `Practice  Delivered: 1`; items respawn on both.
8. Host presses Escape > **Start Run**. Both teleport to the door, items
   reset, HUD shows `Delivered: 0/3` and a timer on both.
9. Complete three deliveries together. End screen on both: host has Play
   Again / Back to Practice / Leave; guest has Leave only.
10. Host presses **Back to Practice**. Both return to practice, lobby panel
    says `PRACTICE`.
11. Guest presses Escape > **Leave**. Host's panel drops the guest; anything
    the guest held falls.
12. Guest re-joins via invite while the host holds the pan: the guest sees
    the pan held (in the host's hand) on arrival.
13. Host quits (Escape > Quit). Guest lands on the menu with `Host left`.

Note how a held item feels on the guest (loose grip vs. visible lag); that
number decides whether holder-owned physics is worth building.

| Date | Godot | GodotSteam | Result | Held-item feel |
|------|-------|------------|--------|----------------|
| —    | 4.7.2 | 4.22.1     | not yet run | — |

## Project layout

- `scenes/` — `menu.tscn`, `kitchen.tscn`, `player.tscn`,
  `ui/{debug_overlay,hud,pause_menu,end_screen,score_popup,lobby_panel,menu_diorama}.tscn`
  (`menu_diorama.tscn` is the animated primitive kitchen behind the title
  menu),
  `items/{egg,pan,plate}.tscn`,
  `sync/{player,egg,container,loop,orders,net}_sync.tres`
  (`MultiplayerSynchronizer` replication configs)
- `scripts/` — `player.gd`, `menu.gd`, `groups.gd` (node-group name
  constants), `items/{food_item,pan,plate}.gd`,
  `net/{net_session,steam_manager,net_body}.gd` (session/peer autoload,
  Steam autoload, per-item replication and smoothing),
  `systems/{grab_controller,stove_detector,cook_slot,food_container,order_system,delivery_zone,item_spawner,kitchen_loop,kitchen_net}.gd`,
  `ui/{debug_overlay,order_board,hud,pause_menu,end_screen,score_popup,lobby_panel,menu_diorama}.gd`
  (`menu_diorama.gd` builds the menu's flat-shaded kitchen and three tweened
  capsule chefs from primitives in `_ready`; no art assets)
- `scene.gltf`, `scene.bin`, `textures/` — the old Sketchfab menu background.
  No scene uses them any more (the menu draws `menu_diorama.tscn` instead);
  they can be deleted.
- `tests/` — `smoke_test.gd` (headless smoke test entry point),
  `smoke_test_body.gd` (its checks), `net_test.gd` / `net_test_body.gd`
  (two-peer ENet test) with `run_net_test.ps1`, `menu_test.gd` /
  `menu_test_body.gd` (headless menu flow test), and their `README.md`
- `steam_appid.txt` — App ID 480 for development; never exported
- `addons/godotsteam/` — GodotSteam GDExtension, git-ignored (see Co-op
  setup)
- `docs/plans/` — the design docs and implementation plans that drove the
  solo slice and the co-op build; the solo plan ends with the post-slice
  backlog and its completion notes
- `docs/WALKTHROUGH.md` — quick inspect-and-debug guide: health checks,
  editor debug views, overlay values, symptom-to-cause table, probe template

## Known limitations (slice scope)

- Run state is minimal: a count-up timer, a fixed three-delivery goal and a
  star rating on the end screen; no fail state and no persistent score
- No customer NPCs or dining area
- Only one recipe (fried egg)
- Art is grey-box primitives only
- The automated smoke test is headless physics only — no rendering or visual
  regression coverage, so the manual smoke test above is still the net for
  anything you can see
- The precise grab ray queries only the `Items` layer, so a dead-on aim at an
  item hidden behind thin geometry can still grab it; only the grab-assist
  path checks line of sight
- Grabbing the pan with an egg in it throws the egg out: the grab controller
  snaps the pan's velocity in a single physics step (see `tests/README.md`,
  `carry.pan_keeps_egg`). Carry the egg separately for now.
- Releasing an item only reaches ~1.2 m ahead of the camera: walk up to the
  stove or rack and keep the view roughly level to drop food into the pan or
  onto the plate.
- Co-op (see `docs/plans/2026-09-22-coop-multiplayer-design.md`, Known
  caveats): a held item trails a guest's hand by one round trip because the
  host runs the pull; the first-build interpolation on guests chases its
  target under jitter (a two-state buffer is the next step); the host
  re-validates a grab by distance only, not line of sight; throw direction
  comes from the replicated head, one tick stale; no host migration (host
  leaves, everyone returns to the menu); no drop-in to a live run (joins go
  to the practice kitchen only); Steam App ID 480 only; late joiners get
  discrete state (mode, deliveries, timer, order) via one full-state RPC

## Backlog

The post-slice backlog in `docs/plans/2026-04-13-cooking-game-foundation.md`
("Post-slice backlog") was swept on 2026-09-11; each bullet there keeps its
original text behind a **Done** note describing how it was closed. New items
go in the same list.

## Requirements

- Godot 4.7 (4.7.2 stable or later), Forward+ renderer
- Jolt Physics (already configured in `project.godot`)
- For co-op only: GodotSteam 4.22.1 GDExtension and a running Steam client
  (see Co-op setup)
