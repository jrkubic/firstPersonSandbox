# Tests

## Headless smoke test

`tests/smoke_test.gd` is a `SceneTree` entry point that loads
`tests/smoke_test_body.gd`, a `Node` holding the checks, once the autoloads
exist (a `--script` MainLoop is compiled before them, and any `class_name`
script it types that names `NetSession` would fail to compile). The body
loads `scenes/kitchen.tscn` headless, drives the physics items by teleporting
them, and asserts the whole cook loop end to end. No addons, no editor, no
display needed. Since the co-op build the player is spawned by `KitchenNet`
at `Players/1` (so the camera and `GrabController` are looked up under
`Players/1/Head/Camera3D`) and every egg, pan and plate lives under `Items`,
not the `Kitchen` root; the smoke test runs the solo path, which is the host
path with zero clients.

Run from the project root (Windows console binary shown; any Godot 4.7
binary works):

```sh
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/smoke_test.gd
```

Output is one line per check — `PASS <name>`, `FAIL <name>: <detail>` or
`XFAIL <name>: <detail>` — followed by a `SUMMARY: N passed, N failed, N
xfailed` line. The process exits with code `0` when no non-expected check
failed and `1` otherwise. A 180 s wall-clock watchdog fails the run if the
coroutine ever stalls (for example after a script error inside a check).

Physics runs at a fixed 60 ticks/s and every wait is counted in physics
frames (`await physics_frame`), so the number of cook ticks an egg receives
between two assertions is deterministic. Wall time is about 25 s because
headless physics still advances in real time.

### What each check covers

| Check group | What it asserts |
|-------------|-----------------|
| `boot.*` | Kitchen loads; `Pass/DeliveryZone`, `KitchenLoop`, `OrderSystem`, both `ItemSpawner`s, the camera and `GrabController` are wired; after the deferred spawns settle there is exactly one egg and one bread (both in `food`, told apart by `recipe_tag` via `_foods_tagged()`), one plate, one pan and one stove; the egg is `RAW` at progress 0; the pan reports `is_on_stove()`; nothing is held; the ticket is `current_index == 0`, `1× Fried Egg`. Right after wiring the body sets `KitchenLoop.delivery_goal = 99` (the run makes five deliveries and must never reach WON, which pauses the tree) and `OrderSystem.randomize_orders = false` (the ticket only moves when a check calls `set_current()`). The debug overlay is switched on for the whole run so its watch Callables execute headless (including the "no egg / no plate" branches during respawn). |
| `cook.*` | Egg dropped into the pan on the stove goes `RAW -> COOKING` within 10 frames. `cook.egg_stays_in_pan` watches the egg unassisted for 90 frames: it must still be inside the pan's rim (under 0.2 m off-axis) and must have gained the full 90 ticks of `cook_progress` (see below). Then, while "stirring" (re-centring the egg in the pan every 20 frames if it drifted), the egg reaches `COOKED` and the number of physics frames matches the remaining `cook_duration` exactly (one 1/60 s tick per physics frame, +10/-2 frames tolerance). |
| `pause.*` | Pan (with the egg) teleported onto the counter: `is_on_stove()` becomes false and `cook_progress` does not move for 60 frames. Pan returned to the stove: `is_on_stove()` true again and progress advances. |
| `burn.*` | Cooking continues past `cook_duration + burn_duration`: state becomes `BURNED`, `cook_progress` clamps at exactly 2.0 and stays there. |
| `no_deliver_burned.*` | The burned egg placed on the plate, plate placed inside the delivery zone on the Pass: the plate's `FoodContainer` reports the egg, `OrderSystem.check_delivery` rejects it, `DeliveryZone.delivered` does not fire in 30 frames, and plate and egg are still alive. |
| `deliver.*` | The burned egg is binned (`queue_free`), a fresh egg is spawned with `EggSpawner.spawn()`, cooked to `COOKED` in the pan and placed on the plate already in the zone: `delivered` fires within 30 frames, plate and egg are freed, `KitchenLoop` respawns exactly one new plate and one new `RAW` egg, both parented to the `Kitchen` root (not `Counter` / `PlateRack`), both spawners report their slot as occupied (`is_slot_free()` false), and `deliveries_made == 1`. |
| `held_no_deliver.*` | The respawned plate is put in the `held` group and placed in the zone with a freshly cooked egg: no delivery for 30 frames and the plate survives. Removing it from `held` delivers within 30 frames and `deliveries_made == 2`. (The delivery goal is 3, so the run never reaches the WON state, which would pause the tree.) |
| `grab.*` | The respawned egg is teleported 1 m in front of the player camera. An `InputEventAction("interact")` press/release is fed through `Input.parse_input_event`, which headless still routes to `GrabController._unhandled_input`: `is_holding()` is true, `held_body_name()` matches the egg, and the egg is in `held`. An `InputEventAction("throw")` then releases it with `linear_velocity.length() > 5` and clears `held`. With `grab_assist_enabled = false` an egg 0.15 m off the aim line is missed; with assist on it is grabbed (`grab.assist_*`). `grab.through_wall_blocked`: the egg frozen just outside the north wall, aimed at dead-on, is not grabbed by either the ray or the assist. |
| `carry.*` | The pan (with the egg from `plate_on_pan`) is grabbed through `interact` from 1.5 m: it leaves the stove, `cook_progress` stops once `is_on_stove()` is false. **Expected failure** `carry.pan_keeps_egg`: the egg is thrown out of the pan the frame it is grabbed (see below). |
| `release.*` | Standing pressed against the stove with a level view, an egg released from the hold point drops into the pan's `CookSlot` and cooking resumes. Guards the `HoldTarget` offset. |
| `throw.*` | An egg thrown at the north wall from 2.2 m never crosses the wall plane (egg `continuous_cd`). |
| `grab.break_*` | A held egg teleported past `break_distance` from the hold target is released and leaves `held`. |
| `crouch.blocked_*` | Standing up is refused under a temporary 1.5-1.7 m ceiling slab, allowed once it is freed, and never blocked by a body in the `held` group. |
| `held_egg.*` | A cooked egg in the `held` group on a plate in the zone is not delivered; releasing it delivers (`delivery_goal` is raised to 10 first so the run never reaches WON). |
| `occupied.*` | A separately instantiated egg is cooked and delivered while the respawned egg still sits in the spawner slot: no second egg is spawned, the slot stays occupied, the plate respawns. |
| `orders.*` | Recipe data. `set_current(1)` switches `current_order_text()` to `1× Egg on Toast`; a plate holding only a cooked egg is rejected by `check_delivery()` against that ticket and accepted once `set_current(0)` puts the fried egg back. The plate is left in the zone, so `DeliveryZone` delivers it over the next 30 frames (`_check_walk` / `_check_trash` re-fetch their items afterwards). |
| `toast.*` | Bread and the toaster. The raw slice is teleported just above `SlotA` of the toaster on the `ToasterCounter` (`TOASTER_SLOT_A`); it reaches `COOKING` within 20 frames with no pan or stove involved (`CookSlot.always_hot`) and `COOKED` within 1.5× `cook_duration`. It is then parked off-heat on the counter (`TOASTER_COUNTER_PARK_POS`, clear of the toaster and the bread spawner's slot radius) — the slots are always hot, so leaving it in place during the egg's 4 s cook would burn it (bread burns 3 s after toasting). With the ticket on recipe 1, a plate with only the toast is rejected; adding the cooked egg delivers within 60 frames (the detail string guards `plate`, which the delivery frees) and one raw bread respawns. A fresh slice left in `SlotB` reaches `BURNED` within 1.5× (`cook_duration + burn_duration`); binned, it is freed and replaced. Finally `set_current(0)` restores `1× Fried Egg`. |
| `crouch.*` | Holding `crouch`: `is_crouched()`, the Head drops toward `crouch_height_offset`, the capsule shrinks to `crouch_capsule_height` with its bottom staying on the floor. Releasing: stands up, Head and capsule restored. |
| `plate_on_pan.*` | A freshly cooked egg is plated and the plate is set down on the pan while the pan is on the stove. The plate's `FoodContainer` reports the egg (`is_contained()`), the pan's `CookSlot` still overlaps it (`has_food()`), yet `cook_progress` does not move for 120 frames and the state stays `COOKED`; the egg is still in both volumes afterwards, so the freeze is due to containment rather than the egg escaping. Moving the plate away and dropping the egg back in the pan clears containment and progress resumes. |
| `pause_settings.*` | Runs last. A `pause` action press through `Input.parse_input_event` opens `PauseMenu` on its buttons (`%VBoxContainer` visible, `%SettingsPage` hidden); emitting `%SettingsButton.pressed` swaps the controls page in; a second `pause` press backs out to the buttons rather than resuming; a third resumes. The tree is paused meanwhile (offline), so the waits count process frames. Nothing is rebound or saved, so the real `settings.cfg` is never written. |

### `carry.pan_keeps_egg` (expected failure)

`GrabController` sets the held body's linear and angular velocity in one
step (up to 20 m/s / 20 rad/s) on the frame it is grabbed, so a pan grabbed
off the stove hits the egg resting in it like a bat and throws it out; the
rim cannot help because the impulse comes from the disc itself. A 2026-09-11
probe with real physics tried `continuous_cd` on the pan (worse: the swept
rim launches the egg 5 m), acceleration ramps of 20-80 m/s^2 and speed caps
down to 5 m/s / 4 rad/s; every variant still lost the egg at one or more
grab distances (1.2 / 1.5 / 2.0 m). The fix is a feel pass on the grab
controller (impulse-limited pull, or briefly parenting/freezing contents to
the pan while it accelerates), then flip this `_xfail` back to `_check`.

### `cook.egg_stays_in_pan` and stirring

The pan's handle collision cylinder does not reach down to the stove top
(pan disc bottom is at local y = -0.04, the handle's underside at -0.025),
so with the pan resting on its disc the handle end hangs in the air and the
body used to settle at a slight pitch (the collision is now lowered so its underside is flush with the disc bottom). A free egg on that surface rolls toward the
handle. Before the pan had a rim this carried the egg out of the `CookSlot`
volume after about 80 frames and stalled `cook_progress` (the check used to
be an expected failure). The 12 rim wall segments on the pan now stop the
egg at about 0.17-0.18 m off-axis, inside both the disc and the `CookSlot`
box, so it keeps cooking; the check asserts exactly that. The later checks
still "stir" (re-centre the egg every 20 frames) so the plate-on-pan and
delivery flows do not depend on where the egg comes to rest.

### Adding a check

Write an `async` function that awaits `_step(n)` / `_wait_until(pred, n)` /
`_cook_until(...)`, call `_check(name, condition, detail)` for each
assertion, and call it from `_run()`. Never rely on wall time — count physics
frames. Use `_xfail` only for a documented gameplay bug that a later task is
expected to fix.

## Two-peer net test

`tests/net_test.gd` is the `--script` launcher (split from the body for the
same reason as the smoke test) and `tests/net_test_body.gd` holds the checks.
Two Godot processes load `scenes/kitchen.tscn` headless and talk over
`ENetMultiplayerPeer` on localhost, so the `MultiplayerSpawner` /
`MultiplayerSynchronizer` / `@rpc` code that Steam sessions use runs with no
Steam client and no addon. The transport is the only thing swapped.

### Running it

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_net_test.ps1
```

The runner starts the host, waits 4 s so it is listening before the client
connects, starts the client, waits for both to exit (client 150 s, host a
further 60 s, then kills them), and prints the merged `PASS` / `FAIL` /
`SUMMARY` lines followed by any `SCRIPT ERROR` / `ERROR:` / `WARNING:` lines
Godot wrote to stderr. It exits `0` only if both halves exited `0`
(`NET TEST PASSED`), otherwise `1` with both exit codes. Full stdout of each
half is in `%TEMP%\net_test_host.log` and `%TEMP%\net_test_client.log`;
stderr in `net_test_host.err.log` and `net_test_client.err.log` next to
them. Pass `-Godot <path>` if the console binary is not at
`%USERPROFILE%\Downloads\Godot_v4.7.2-stable_win64\`, `-Port` to change 7777.

By hand, in two consoles from the project root (start the host first):

```sh
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/net_test.gd -- role=host port=7777
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/net_test.gd -- role=client port=7777
```

Each half prints its own `SUMMARY <role>: N passed, N failed` line and
exits `1` if any check failed, if the number of checks run differs from
`EXPECTED_CHECKS[role]` (`FAIL <role>.summary.count`), or if its 120 s
watchdog trips. Adding a check means bumping `EXPECTED_CHECKS` for that
role only (`{"host": 12, "client": 25}` today). The host sets
`OrderSystem.randomize_orders = false` right after loading the kitchen so the
ticket only moves on its own `set_current()` calls. Waits are counted in physics
frames at 60 ticks/s as in the smoke test; the whole run takes about 15 s
including the runner's 4 s head start.

### Host timeline vs. client assertions

The host does the driving and asserts only that the client's actions arrived;
the client asserts what it sees replicated. In order, the host: listens,
loads the kitchen, teleports the plate to hand and grabs it **before** the
client connects (so the client's first sight of the plate is a held one),
waits for the peer, cooks the egg (stirring, as the smoke test does), parks
it on the counter so it stops cooking, waits for the client to grab and then
release it, releases the plate, delivers the egg on the plate at the Pass,
checks practice mode did not end the run, calls `KitchenNet.start_run()`, and
waits for the client to disconnect before leaving.

| Check | What it asserts |
|-------|-----------------|
| `host.listen` | `NetSession.host_enet(port)` returns `OK`. Aborts the host half if not. |
| `host.plate_held` | The host's own `GrabController` holds the plate and `NetBody.held_by == 1` before any client exists. |
| `host.client_connected` | `peer_connected` fires within 40 s. Aborts if not. |
| `host.client_player_spawned` | 30 frames later `Players/<client id>` exists on the host. |
| `host.egg_cooked` | The egg reaches `COOKED` in the pan within 1.5× `cook_duration`. |
| `host.client_grabbed_egg` | Within 20 s the parked egg's `held_by` becomes the client's peer id — the grab RPC arrived and passed re-validation. |
| `host.client_released_egg` | Within 20 s `held_by` returns to `NetBody.NOBODY`. |
| `host.order_index` | `OrderSystem.current_index` is still 1: the host called `set_current(1)` right after `host.client_player_spawned` (so the change replicates on_change, not only via the join snapshot) and nothing re-drew it through the client's grab. Checked just before the ticket is switched back to 0, because a fried-egg plate cannot satisfy Egg on Toast. |
| `host.delivered` | Ticket back on recipe 0, plate then egg teleported to the Pass: `deliveries_made == 1` within 5 s. |
| `host.practice_no_win` | `KitchenLoop.state` is still `PLAYING` and `KitchenNet.mode` is `PRACTICE`: a practice delivery never ends the run. |
| `host.run_started` | After `start_run()`: mode `RUN`, `deliveries_made == 0`, exactly two eggs and two plates (one per spawner) after the in-place reset. |
| `host.client_left` | `peer_disconnected` fires within 60 s. |

The client, in order:

| Check | What it asserts |
|-------|-----------------|
| `client.connected` | `connected_to_server` fires within 20 s of `prepare_client_enet`. Aborts if not. |
| `client.peer_id` | `multiplayer.get_unique_id() > 1`. |
| `client.player_spawned` | `Players/<own id>` appears within 10 s (host's `MultiplayerSpawner` replayed it). Aborts if not. |
| `client.player_authority` | That player node reports `is_multiplayer_authority()`. |
| `client.host_player_visible` | `Players/1` exists and is **not** owned by this peer. |
| `client.sees_egg` | A `food` node is replicated within 5 s. Aborts if not. |
| `client.egg_frozen` | The replicated egg has `freeze == true` (no client-side simulation). |
| `client.egg_parent` | The egg's parent is the kitchen's `Items` node. |
| `client.cook_progress_syncs` | `cook_progress` climbs past 0.25 while the host cooks. |
| `client.state_syncs` | `state` becomes `COOKED`. |
| `client.order_index_syncs` | `OrderSystem.current_index` becomes 1 within 10 s (`orders_sync.tres` replicates it on change). Checked here, while the ticket is guaranteed to be on recipe 1: the host set it before cooking and only switches back after our grab and release. |
| `client.order_board_text` | One process frame later `OrderBoard/TicketLabel.text` reads `1× Egg on Toast`. |
| `client.position_syncs` | The egg ends up within 0.5 m of the host's counter park position. |
| `client.late_join_held_by` | The plate the host grabbed before we joined arrives with `held_by == 1`. |
| `client.late_join_held_group` | ...and is in the `held` group locally. |
| `client.grab_taken_rejected` | `request_grab` on that held plate leaves us not holding, with `last_reject == Reject.TAKEN`. |
| `client.grab_rpc` | Standing at the counter, `request_grab` on the egg makes `is_holding()` true within 5 s and `held_by` our id. |
| `client.held_name` | `held_body_name()` matches the egg's node name. |
| `client.release_rpc` | `request_release` clears `is_holding()` and `held_by` goes back to `NOBODY` within 5 s. |
| `client.practice_mode_on_join` | `KitchenNet.mode` is `PRACTICE` (came through the full-state RPC on join). |
| `client.names_synced` | `NetSession.peer_names` has entries for peer 1 and for us. |
| `client.delivery_syncs` | `deliveries_made == 1` after the host's delivery. |
| `client.mode_syncs` | Mode flips to `RUN` after the host's `start_run()`. |
| `client.teleport_rpc` | Our player is within 0.5 m of `SpawnPoint1` — the owning-peer teleport RPC moved a body we have authority over. |
| `client.timer_syncs` | `KitchenLoop.elapsed_time` passes 0.5 s on the client. |

The client stays connected two more seconds before leaving so the host's
`client_player_spawned` check (30 frames after `peer_connected`) never races
its departure.

## Menu test

`tests/menu_test.gd` is the `--script` launcher and `tests/menu_test_body.gd`
holds the checks (same launcher/body split as the other two). The body
instantiates `scenes/menu.tscn` as the current scene, waits one frame for
`_ready`, then drives the flow by emitting each button's `pressed` signal and
reading page visibility, exercises the Settings page (rebind by a key press
fed through `Input.parse_input_event`, then Reset), then watches the
background diorama for 90 frames. No Steam, addon or display is needed; the
run takes a few seconds. A 60 s watchdog fails it if it stalls.

```sh
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/menu_test.gd
```

The menu's pages are `VBoxContainer`s toggled by `scripts/menu.gd`
(`_show_page`), and every node the test addresses is looked up by its
unique name (`%MainPage`, `%PlayButton`, ...), so renaming or re-parenting a
node inside a page does not break the test as long as `unique_name_in_owner`
stays set. It exits `1` if any check fails or if the number of checks run
differs from `EXPECTED_CHECKS` (21 today).

Before the `settings.*` checks the body points `Settings.config_path` at
`user://menu_test_settings.cfg` and calls `reset_to_defaults()`, so the
developer's real `settings.cfg` is never read or written; the temp file is
deleted after the Back press.

| Check | What it asserts |
|-------|-----------------|
| `menu.pages_exist` | `%MainPage`, `%PlayPage`, `%MultiplayerPage` and `%StatusLabel` resolve. Aborts the run if not. |
| `menu.main_first` | After `_ready` only the main page is visible. |
| `menu.status_offline` | With no Steam the status line reads `Steam not detected: solo only`. |
| `menu.play_opens_play_page` | Play shows the Play page and hides Main. |
| `menu.play_back` | Back on the Play page returns to Main. |
| `menu.multiplayer_opens_mp_page` | Play then Multiplayer shows the Multiplayer page and hides Play. |
| `menu.host_disabled_without_steam` | `%HostButton.disabled` is true headless. |
| `menu.host_text` | The host button reads `Host via Steam`. |
| `menu.mp_back` | Back on the Multiplayer page returns to the Play page. |
| `menu.solo_wired` | `%SoloButton.pressed` has exactly one connection. |
| `menu.quit_wired` | `%QuitButton.pressed` has exactly one connection. |
| `menu.host_wired` | `%HostButton.pressed` has exactly one connection. |
| `settings.opens` | Settings on Main shows `%SettingsPage` and hides Main. |
| `settings.one_row_per_action` | The page's `Rows` grid has two children (label + key button) per `Settings.REBINDABLE` action. |
| `settings.shows_current_key` | `key_button(&"interact").text` reads `E`. |
| `settings.rebinds_on_key` | After emitting that button's `pressed` and feeding a physical `G` key press through `Input.parse_input_event`, one frame later `Settings.key_for(&"interact")` is `KEY_G` and the button reads `G`. |
| `settings.reset` | `%ResetButton` puts interact back to `E` and the button text follows; `%SettingsBackButton` then returns to Main. |
| `diorama.present` | `Background/MenuDiorama` exists. The three checks below are recorded as failed if not. |
| `diorama.three_chefs` | `MenuDiorama/Chefs` has exactly three children. |
| `diorama.camera_current` | `MenuDiorama/Camera3D` exists and is the current camera. |
| `diorama.chefs_move` | After 90 process frames at least two chefs are more than 0.05 m from where they started. |

Solo and Quit are never actually pressed: Solo would `change_scene_to_file`
into the kitchen and Quit would end the process, so the test only asserts
they are connected.

## Settings test

`tests/settings_test.gd` is the `--script` launcher and
`tests/settings_test_body.gd` holds the checks. It exercises the `Settings`
autoload directly, with no scene: the autoload is on the tree before
`_initialize`, so the body may name `Settings` as any game script does. The
body first sets `Settings.config_path` to `user://settings_test.cfg`, deletes
any stale copy and calls `reset_to_defaults()`, and deletes the temp file
again at the end, so the developer's real `user://settings.cfg` is never
touched. It exits `1` if any check fails or if the number of checks run
differs from `EXPECTED_CHECKS` (11 today).

```sh
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/settings_test.gd
```

| Check | What it asserts |
|-------|-----------------|
| `defaults.interact_e` | After `reset_to_defaults`, `key_for(&"interact")` is `KEY_E` (defaults are captured from the shipped `InputMap` in `_ready`). |
| `defaults.walk_shift` | `key_for(&"walk")` is `KEY_SHIFT`. |
| `bind.updates_settings` | `bind(&"interact", KEY_G)` makes `key_for` report `G`. |
| `bind.updates_inputmap` | The `InputMap` events for `interact` now contain a physical `G` and no `E`. |
| `bind.swaps_on_conflict` | `bind(&"throw", KEY_G)` gives throw `G` and hands interact throw's old `F`, so nothing is left unbound. |
| `save.written` | The temp config exists and stores `controls/throw = KEY_G`. |
| `save.sensitivity` | Assigning `mouse_sensitivity = 0.004` then calling `save()` writes `mouse/sensitivity` (the setter clamps and emits but does not save; the page saves when a slider drag ends or on Back). |
| `reset.restores` | `reset_to_defaults` returns interact to `E`, throw to `F` and sensitivity to `DEFAULT_SENSITIVITY`. |
| `load.applies` | A hand-written config (`interact = KEY_H`, `sensitivity = 0.001`) is applied to both `Settings` and the `InputMap` by `load_settings`. |
| `load.does_not_write` | That `load_settings` call left the file's modified time and bytes unchanged: loading never rewrites the config, so a boot cannot create or clobber it. |
| `load.ignores_unknown_action` | `pause` (Escape) is not in `Settings.REBINDABLE`. |

Two engine quirks the autoload works around, both of which would otherwise
print an `ERROR:` line per call headless: `DisplayServer.keyboard_get_keycode_from_physical`
is unsupported by the headless display server (so `key_name` falls back to
the physical key there), and `ConfigFile.get_value` treats an explicit `null`
default as "no default given" (so `load_settings` tests `has_section_key`
before reading).
