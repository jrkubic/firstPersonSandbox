# Co-op Multiplayer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn the solo cooking slice into a 4-player Steam co-op game with a live practice-kitchen lobby, host-authoritative physics, and a headless two-peer regression test.

**Architecture:** One persistent `kitchen.tscn` per session. The host (peer 1) owns every item, cooking, orders and delivery; each client owns only its own `Player`. Godot's high-level multiplayer replicates players and items through two `MultiplayerSpawner`s and per-node `MultiplayerSynchronizer`s (continuous values `always`/unreliable at 30 Hz, discrete values `on_change`/reliable). Grab, release and throw are requests to the host; `NetBody.held_by` is the replicated truth about who holds what. Transport is pluggable: `ENetMultiplayerPeer` on localhost drives the automated test, `SteamMultiplayerPeer` from GodotSteam drives real play.

**Tech Stack:** Godot 4.7.2 (GDScript, Jolt), Godot high-level multiplayer (`MultiplayerSpawner`, `MultiplayerSynchronizer`, `@rpc`), ENet (built in), GodotSteam 4.22.1 GDExtension + Steam App ID 480.

**Design doc:** `docs/plans/2026-09-22-coop-multiplayer-design.md`. Read it first.

---

## Conventions used by every task

- Project root: `C:\Projects\firstPersonSandbox`. All paths below are relative to it.
- `GODOT` = `C:\Users\Jake\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe`.
- **Smoke test** (solo path, must stay green in every task):
  ```powershell
  & $GODOT --headless --path . --script res://tests/smoke_test.gd
  ```
  Expected at the end of every task: `SUMMARY: 94 passed, 0 failed, 1 xfailed`, exit code 0.
- **Net test** (two ENet processes, from Task 3 on):
  ```powershell
  powershell -ExecutionPolicy Bypass -File tests/run_net_test.ps1
  ```
- Godot has no unit-test framework here. "Write the failing test" means adding `_check(...)` lines to `tests/smoke_test.gd` or `tests/net_test.gd`; those are the tests. Keep `EXPECTED_CHECKS` in sync or the run fails on count.
- Parse-check any script you touched without running the game:
  ```powershell
  & $GODOT --headless --path . --check-only --script res://scripts/<file>.gd
  ```
  Known limit (found in Tasks 1-2): `--check-only` reports `Identifier not found` for any script that names an autoload (`NetSession`, `SteamManager`), and a `--script` SceneTree file cannot compile any `class_name` script that names one either (the MainLoop is compiled before autoloads are registered and eagerly compiles every class it types). So: the smoke run is the parse gate for those scripts, and every headless test is a tiny SceneTree launcher (`tests/smoke_test.gd`, `tests/net_test.gd`) that loads a Node body (`tests/smoke_test_body.gd`, `tests/net_test_body.gd`) from `_initialize`, by which time the autoloads exist. Bodies may name autoloads and class_name types freely.
- Commit after every task with the message given. Add the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- This plan edits `.tscn` files by hand. Do not have the Godot editor open on the project while doing so.

## Task map

| # | Task | Verified by |
|---|------|-------------|
| 1 | `NetSession` + `SteamManager` autoloads (offline no-ops), `Groups` constants, design-doc fix | smoke test unchanged |
| 2 | Kitchen restructure: `Players`/`Items`/`SpawnPoints`/`Net`, `KitchenNet` spawns players, pan via spawner, spawner group | smoke test with updated paths |
| 3 | `Player` network authority + ENet two-peer test scaffold | net test: connect + player spawn |
| 4 | `NetBody`, item synchronizers, authority gating in cooking/delivery | net test: item + cook sync |
| 5 | `GrabController` request/serve RPCs, `held_by` | net test: grab, release, late-join held |
| 6 | Practice/run modes, in-place reset, full-state RPC, names | net test: mode, timer, teleport, delivery |
| 7 | UI: menu, pause menu, lobby panel, end screen, HUD | manual run in editor |
| 8 | GodotSteam install + Steam host/join flows | manual two-account Steam test |
| 9 | Docs: README, tests/README, WALKTHROUGH, memory | full test runs |

---

### Task 1: Session autoloads and constants

Nothing networked happens yet. This task adds the two autoload singletons every later script references, so the project keeps parsing headless with no Steam extension installed.

**Files:**
- Create: `scripts/net/net_session.gd`
- Create: `scripts/net/steam_manager.gd`
- Modify: `scripts/groups.gd`
- Modify: `project.godot` (add `[autoload]`)
- Modify: `tests/smoke_test.gd` (autoload guard in `_initialize`)
- Modify: `docs/plans/2026-09-22-coop-multiplayer-design.md` (room size line)

**Step 1: Fix the design doc's room-size claim**

The room is already 12 × 12 m (`BoxMesh_floor` size 12, walls at ±6). In the design doc's "Kitchen changes" paragraph replace `room grows to roughly 8 × 8 m` with `room stays 12 × 12 m (already big enough)`. Append to the "Practice kitchen" paragraph: `Start Run and Invite friends live in the Escape menu, because the mouse is captured while playing.`

**Step 2: Add group constants**

Append to `scripts/groups.gd`:

```gdscript
const SPAWNER: StringName = &"spawner"
const KITCHEN_NET: StringName = &"kitchen_net"
```

**Step 3: Create `scripts/net/steam_manager.gd`**

Every Steam call goes through `Object.call()` on the dynamically fetched singleton, so the script parses and runs without the GDExtension.

```gdscript
extends Node
## Thin wrapper around the GodotSteam singleton. Autoloaded as SteamManager.
##
## Every call goes through Object.call() on the dynamically fetched "Steam"
## singleton so this script parses and runs when the GodotSteam GDExtension
## is absent (headless tests, fresh clones): each method then degrades to
## "not available" and is_ready() stays false.

const APP_ID: int = 480  # Spacewar, Valve's public test app id
const LOBBY_TYPE_FRIENDS_ONLY: int = 1
const CHAT_ROOM_ENTER_RESPONSE_SUCCESS: int = 1
const RESULT_OK: int = 1
const INIT_RESULT_OK: int = 0

signal lobby_created(ok: bool, lobby_id: int)
signal lobby_joined(ok: bool, lobby_id: int, owner_steam_id: int)
signal join_requested(lobby_id: int)

var _steam: Object = null
var _initialized: bool = false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_try_init()


func _process(_delta: float) -> void:
	if _initialized:
		_steam.call("run_callbacks")


func is_ready() -> bool:
	return _initialized


func persona_name() -> String:
	if not _initialized:
		return ""
	return str(_steam.call("getPersonaName"))


## A fresh SteamMultiplayerPeer, or null when the extension is absent.
func new_multiplayer_peer() -> MultiplayerPeer:
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		return null
	return ClassDB.instantiate("SteamMultiplayerPeer") as MultiplayerPeer


func create_lobby(max_members: int) -> void:
	if _initialized:
		_steam.call("createLobby", LOBBY_TYPE_FRIENDS_ONLY, max_members)
	else:
		lobby_created.emit(false, 0)


func join_lobby(lobby_id: int) -> void:
	if _initialized:
		_steam.call("joinLobby", lobby_id)
	else:
		lobby_joined.emit(false, lobby_id, 0)


func leave_lobby(lobby_id: int) -> void:
	if _initialized:
		_steam.call("leaveLobby", lobby_id)


func set_lobby_joinable(lobby_id: int, joinable: bool) -> void:
	if _initialized:
		_steam.call("setLobbyJoinable", lobby_id, joinable)


func open_invite_dialog(lobby_id: int) -> void:
	if _initialized:
		_steam.call("activateGameOverlayInviteDialog", lobby_id)


func _try_init() -> void:
	if not Engine.has_singleton("Steam"):
		push_warning("SteamManager: GodotSteam extension not loaded; Steam features disabled")
		return
	_steam = Engine.get_singleton("Steam")
	var result: Dictionary = _steam.call("steamInitEx", APP_ID, false)
	if int(result.get("status", 1)) != INIT_RESULT_OK:
		push_warning("SteamManager: steamInitEx failed: %s" % str(result.get("verbal", "?")))
		_steam = null
		return
	_initialized = true
	_steam.connect("lobby_created", _on_lobby_created)
	_steam.connect("lobby_joined", _on_lobby_joined)
	_steam.connect("join_requested", _on_join_requested)


func _on_lobby_created(result: int, lobby_id: int) -> void:
	lobby_created.emit(result == RESULT_OK, lobby_id)


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	var ok: bool = response == CHAT_ROOM_ENTER_RESPONSE_SUCCESS
	var owner_id: int = int(_steam.call("getLobbyOwner", lobby_id)) if ok else 0
	lobby_joined.emit(ok, lobby_id, owner_id)


func _on_join_requested(lobby_id: int, _friend_id: int) -> void:
	join_requested.emit(lobby_id)
```

**Step 4: Create `scripts/net/net_session.gd`**

```gdscript
extends Node
## Session-level networking state, autoloaded as NetSession: which role this
## peer plays, how it is connected, and who else is in the session.
##
## Transport-agnostic. The Steam flows are driven by SteamManager signals;
## the headless two-peer test drives the ENet flows directly. A client never
## connects until the kitchen scene reports ready (kitchen_ready), so its
## MultiplayerSpawners exist before the host starts replicating into them.

enum Role { OFFLINE, HOST, CLIENT }

const KITCHEN_SCENE: String = "res://scenes/kitchen.tscn"
const MENU_SCENE: String = "res://scenes/menu.tscn"
const MAX_PLAYERS: int = 4

signal session_ended(reason: String)
signal peers_changed

var role: Role = Role.OFFLINE
var lobby_id: int = 0
## Peer id -> display name. Maintained by the host, broadcast by KitchenNet.
var peer_names: Dictionary = {}
## Shown by the menu after a session ends ("Host left", errors).
var last_message: String = ""

var _pending_enet: Array = []      # [address, port] until the kitchen is ready
var _pending_steam_host: int = 0   # host Steam id until the kitchen is ready


func _ready() -> void:
	SteamManager.lobby_created.connect(_on_steam_lobby_created)
	SteamManager.lobby_joined.connect(_on_steam_lobby_joined)
	SteamManager.join_requested.connect(join_steam)


func is_online() -> bool:
	return role != Role.OFFLINE


## True for the host and for offline play: this peer runs physics, cooking,
## orders and delivery. False only for a connected client.
func is_authority() -> bool:
	return role != Role.CLIENT


func local_peer_id() -> int:
	return multiplayer.get_unique_id()


func local_name() -> String:
	var steam_name: String = SteamManager.persona_name()
	if steam_name != "":
		return steam_name
	return "Player %d" % local_peer_id()


# --- ENet (localhost tests, LAN) --------------------------------------------

func host_enet(port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip("127.0.0.1")
	var err: Error = peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		return err
	_become_host(peer)
	return OK


func prepare_client_enet(address: String, port: int) -> void:
	role = Role.CLIENT
	_pending_enet = [address, port]


# --- Steam ------------------------------------------------------------------

func host_steam() -> void:
	if not SteamManager.is_ready():
		last_message = "Steam not detected"
		session_ended.emit(last_message)
		return
	SteamManager.create_lobby(MAX_PLAYERS)  # continues in _on_steam_lobby_created


## Called when the local user accepts a Steam invite. Ignored while already
## in an online session.
func join_steam(target_lobby_id: int) -> void:
	if is_online():
		return
	SteamManager.join_lobby(target_lobby_id)  # continues in _on_steam_lobby_joined


func _on_steam_lobby_created(ok: bool, new_lobby_id: int) -> void:
	if not ok:
		last_message = "Could not create Steam lobby"
		session_ended.emit(last_message)
		return
	var peer: MultiplayerPeer = SteamManager.new_multiplayer_peer()
	var err: Error = peer.call("create_host", 0) if peer else ERR_UNAVAILABLE
	if err != OK:
		last_message = "Steam host failed (%d)" % err
		SteamManager.leave_lobby(new_lobby_id)
		session_ended.emit(last_message)
		return
	lobby_id = new_lobby_id
	_become_host(peer)
	get_tree().change_scene_to_file(KITCHEN_SCENE)


func _on_steam_lobby_joined(ok: bool, joined_lobby_id: int, owner_steam_id: int) -> void:
	if role != Role.OFFLINE:
		return  # the host also receives lobby_joined for its own lobby
	if not ok:
		last_message = "Could not join Steam lobby"
		session_ended.emit(last_message)
		return
	lobby_id = joined_lobby_id
	role = Role.CLIENT
	_pending_steam_host = owner_steam_id
	get_tree().change_scene_to_file(KITCHEN_SCENE)


# --- Shared -----------------------------------------------------------------

## KitchenNet calls this from _ready. A client connects now, after its
## spawners exist. Returns the Error of the connection attempt (OK otherwise).
func kitchen_ready() -> Error:
	if role != Role.CLIENT:
		return OK
	var peer: MultiplayerPeer = null
	var err: Error = OK
	if not _pending_enet.is_empty():
		var enet := ENetMultiplayerPeer.new()
		err = enet.create_client(_pending_enet[0], _pending_enet[1])
		peer = enet
		_pending_enet = []
	elif _pending_steam_host != 0:
		peer = SteamManager.new_multiplayer_peer()
		err = peer.call("create_client", _pending_steam_host, 0) if peer else ERR_UNAVAILABLE
		_pending_steam_host = 0
	else:
		return ERR_UNCONFIGURED
	if err != OK:
		last_message = "Connection failed (%d)" % err
		leave()
		session_ended.emit(last_message)
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	return OK


## Tears the session down and returns to offline. Safe to call twice.
func leave() -> void:
	_disconnect_multiplayer_signals()
	var current: MultiplayerPeer = multiplayer.multiplayer_peer
	if current != null and not (current is OfflineMultiplayerPeer):
		current.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if lobby_id != 0:
		SteamManager.leave_lobby(lobby_id)
		lobby_id = 0
	role = Role.OFFLINE
	peer_names.clear()
	_pending_enet = []
	_pending_steam_host = 0
	peers_changed.emit()


func set_joinable(joinable: bool) -> void:
	if lobby_id != 0:
		SteamManager.set_lobby_joinable(lobby_id, joinable)


func set_peer_names(names: Dictionary) -> void:
	peer_names = names.duplicate()
	peers_changed.emit()


func _become_host(peer: MultiplayerPeer) -> void:
	multiplayer.multiplayer_peer = peer
	role = Role.HOST
	peer_names = {1: local_name()}
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	peers_changed.emit()


func _on_connected_to_server() -> void:
	peers_changed.emit()


func _on_connection_failed() -> void:
	_end_with("Could not connect to host")


func _on_server_disconnected() -> void:
	_end_with("Host left")


func _end_with(reason: String) -> void:
	last_message = reason
	leave()
	session_ended.emit(reason)
	if get_tree().current_scene != null:
		get_tree().change_scene_to_file(MENU_SCENE)


func _on_peer_disconnected(id: int) -> void:
	peer_names.erase(id)
	peers_changed.emit()


func _disconnect_multiplayer_signals() -> void:
	var pairs: Array = [
		[multiplayer.connected_to_server, _on_connected_to_server],
		[multiplayer.connection_failed, _on_connection_failed],
		[multiplayer.server_disconnected, _on_server_disconnected],
		[multiplayer.peer_disconnected, _on_peer_disconnected],
	]
	for pair: Array in pairs:
		var sig: Signal = pair[0]
		var cb: Callable = pair[1]
		if sig.is_connected(cb):
			sig.disconnect(cb)
```

**Step 5: Register the autoloads**

Add to `project.godot`, after the `[display]` section (order matters: SteamManager first, NetSession connects to it in `_ready`):

```ini
[autoload]

SteamManager="*res://scripts/net/steam_manager.gd"
NetSession="*res://scripts/net/net_session.gd"
```

**Step 6: Guard the smoke test against missing autoloads**

A `--script` SceneTree run may or may not have autoloads on `root` when `_initialize` runs. In `tests/smoke_test.gd`, add `_ensure_autoloads()` in `_initialize` right before `_run()`, and add this helper next to `_press_action`:

```gdscript
## Autoloads may not be on root yet when a --script SceneTree initialises.
## Adds them by their autoload names so scripts that reference NetSession /
## SteamManager resolve either way.
func _ensure_autoloads() -> void:
	var autoloads: Array = [
		["SteamManager", "res://scripts/net/steam_manager.gd"],
		["NetSession", "res://scripts/net/net_session.gd"],
	]
	for entry: Array in autoloads:
		if root.has_node(entry[0]):
			continue
		var node: Node = (load(entry[1]) as GDScript).new()
		node.name = entry[0]
		root.add_child(node)
```

**Step 7: Parse-check and run the smoke test**

```powershell
& $GODOT --headless --path . --check-only --script res://scripts/net/net_session.gd
& $GODOT --headless --path . --check-only --script res://scripts/net/steam_manager.gd
& $GODOT --headless --path . --script res://tests/smoke_test.gd
```

Expected: no parse errors; `SUMMARY: 94 passed, 0 failed, 1 xfailed`.

**Step 8: Commit**

```
git add -A
git commit -m "Add NetSession and SteamManager autoloads (offline no-ops)"
```

### Task 2: Kitchen restructure and player spawning

The kitchen gains the containers the spawners replicate into, four spawn points, and a `KitchenNet` node that spawns one `Player` per peer. The pan becomes a spawned item like the egg and plate. Still single player: this task only moves nodes.

**Files:**
- Create: `scripts/systems/kitchen_net.gd`
- Modify: `scripts/systems/item_spawner.gd` (rewrite)
- Modify: `scripts/systems/kitchen_loop.gd` (rewrite)
- Modify: `scenes/kitchen.tscn` (rewrite)
- Modify: `scripts/player.gd` (`grab_controller` reference)
- Modify: `tests/smoke_test.gd` (paths)

**Step 1: Update the smoke test to the new layout (the failing test)**

In `tests/smoke_test.gd`, `_check_boot`, replace the three `Player` lookups:

```gdscript
	_player = _kitchen.get_node_or_null("Players/1") as Player
	_camera = _kitchen.get_node_or_null("Players/1/Head/Camera3D") as Camera3D
	_grab = _kitchen.get_node_or_null("Players/1/Head/Camera3D/GrabController") as GrabController
```

Add, after the `_plate_spawner` lookup:

```gdscript
	_items = _kitchen.get_node_or_null("Items") as Node3D
	_net = _kitchen.get_node_or_null("Net") as KitchenNet
```

extend `wiring_ok` with `and _items != null and _net != null`, and declare next to the other vars:

```gdscript
var _items: Node3D
var _net: KitchenNet
```

In `_check_deliver`, the `deliver.spawn_parent` check now expects `Items`:

```gdscript
	_check("deliver.spawn_parent",
		new_egg != null and new_plate != null
		and new_egg.get_parent() == _items and new_plate.get_parent() == _items,
		"egg parent=%s plate parent=%s" % [
			new_egg.get_parent().name if new_egg else "<none>",
			new_plate.get_parent().name if new_plate else "<none>"])
```

Update the comment above it to say `Spawned items live under Kitchen/Items`.

**Step 2: Run the smoke test to see it fail**

Expected: `FAIL boot.wiring: missing node(s) under Kitchen`, then `SUMMARY` with 1 failed and a count failure. Exit code 1.

**Step 3: Create `scripts/systems/kitchen_net.gd`**

```gdscript
class_name KitchenNet
extends Node
## Owns the multiplayer shape of the kitchen: one Player per peer, spawned
## through the PlayerSpawner (a MultiplayerSpawner with a custom spawn
## function so the node is named after its peer id before it enters the
## tree). Lives at Kitchen/Net. Practice/run modes and the in-place reset
## are added in a later task.

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")

@export_node_path("Node3D") var players_path: NodePath = NodePath("../Players")
@export_node_path("Node3D") var items_path: NodePath = NodePath("../Items")
@export_node_path("Node3D") var spawn_points_path: NodePath = NodePath("../SpawnPoints")

@onready var _players: Node3D = get_node(players_path)
@onready var _items: Node3D = get_node(items_path)
@onready var _spawn_points: Node3D = get_node(spawn_points_path)
@onready var _player_spawner: MultiplayerSpawner = $PlayerSpawner


func _ready() -> void:
	add_to_group(Groups.KITCHEN_NET)
	_player_spawner.spawn_function = _spawn_player_node
	if NetSession.is_authority():
		spawn_player(multiplayer.get_unique_id())
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	NetSession.kitchen_ready()
	call_deferred("_register_debug_watches")


func player_count() -> int:
	return _players.get_child_count()


func get_player(peer_id: int) -> Player:
	return _players.get_node_or_null(str(peer_id)) as Player


func items_root() -> Node3D:
	return _items


## Host only. Spawns the Player for peer_id at the next spawn point and
## replicates it to every peer.
func spawn_player(peer_id: int) -> Player:
	var index: int = player_count() % _spawn_points.get_child_count()
	var point: Node3D = _spawn_points.get_child(index) as Node3D
	return _player_spawner.spawn([peer_id, point.global_position]) as Player


## MultiplayerSpawner.spawn_function: runs on every peer with the same data.
func _spawn_player_node(data: Variant) -> Node:
	var player: Player = PLAYER_SCENE.instantiate() as Player
	player.name = str(data[0])
	player.position = data[1]
	return player


func _on_peer_connected(peer_id: int) -> void:
	spawn_player(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	var player: Player = get_player(peer_id)
	if player == null:
		return
	player.grab_controller.force_release()
	player.queue_free()


func _register_debug_watches() -> void:
	var overlay: Node = get_tree().get_first_node_in_group(Groups.DEBUG_OVERLAY)
	if overlay == null:
		return
	overlay.watch("net.role", func() -> String:
		return NetSession.Role.keys()[NetSession.role])
	overlay.watch("net.peer", func() -> String: return str(multiplayer.get_unique_id()))
	overlay.watch("net.players", func() -> String: return str(player_count()))
```

`force_release()` on `GrabController` does not exist yet; add this stub to `scripts/systems/grab_controller.gd` (Task 5 gives it its real body):

```gdscript
## Drops whatever this controller holds (peer left, kitchen reset).
func force_release() -> void:
	_release()
```

**Step 4: Expose `grab_controller` on `Player`**

In `scripts/player.gd`, add next to the other `@onready` vars:

```gdscript
@onready var grab_controller: GrabController = $Head/Camera3D/GrabController
```

and in `_register_debug_watches` replace `var grab: GrabController = $Head/Camera3D/GrabController` with `var grab: GrabController = grab_controller`.

**Step 5: Rewrite `scripts/systems/item_spawner.gd`**

```gdscript
class_name ItemSpawner
extends Node3D
## Produces one item (egg, plate, pan) at its own position. Only the
## authority spawns; the kitchen's MultiplayerSpawner replicates the result.
## Every spawner is in the "spawner" group so KitchenLoop can refill them.

@export var item_scene: PackedScene
@export var spawn_on_ready: bool = true
## Refilled after a delivery when its slot is free (pans are not).
@export var refill_on_delivery: bool = true
## Spawns only while the kitchen has at least this many players, so extra
## ingredient stations appear for bigger groups.
@export var min_players: int = 1
## Node spawned items are added under. Leave empty to use the current scene
## root, falling back to this spawner's parent (headless runs).
@export_node_path("Node") var spawn_parent_path: NodePath
## Radius (m) around the spawn point within which the last spawned item still
## counts as occupying this slot. See is_slot_free().
@export var slot_radius: float = 0.35

## Per-item serial so replicated node names never collide across spawners.
static var _serial: int = 0

var _last_spawned: Node = null


func _ready() -> void:
	add_to_group(Groups.SPAWNER)
	if spawn_on_ready and NetSession.is_authority():
		call_deferred("spawn")


func spawn() -> Node:
	if item_scene == null or not NetSession.is_authority():
		return null
	if _player_count() < min_players:
		return null
	var instance: Node = item_scene.instantiate()
	_serial += 1
	instance.name = "%s%d" % [instance.name, _serial]
	var parent: Node = _get_spawn_parent()
	if instance is Node3D:
		var local: Vector3 = global_position
		if parent is Node3D:
			local = (parent as Node3D).global_transform.affine_inverse() * global_position
		(instance as Node3D).position = local
	parent.add_child(instance)
	_last_spawned = instance
	return instance


## True when nothing this spawner produced is still sitting in its slot: the
## last spawned item was freed (or is about to be), is being held, or has
## been carried farther than slot_radius from the spawn point.
func is_slot_free() -> bool:
	if not is_instance_valid(_last_spawned) or _last_spawned.is_queued_for_deletion():
		return true
	if _last_spawned.is_in_group(Groups.HELD):
		return true
	var item: Node3D = _last_spawned as Node3D
	if item == null:
		return false
	return item.global_position.distance_to(global_position) > slot_radius


func _player_count() -> int:
	var net: KitchenNet = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	return net.player_count() if net else 1


func _get_spawn_parent() -> Node:
	if not spawn_parent_path.is_empty():
		var target: Node = get_node_or_null(spawn_parent_path)
		if target != null:
			return target
	if is_inside_tree() and get_tree().current_scene != null:
		return get_tree().current_scene
	return get_parent()
```

**Step 6: Rewrite `scripts/systems/kitchen_loop.gd`**

```gdscript
class_name KitchenLoop
extends Node
## Run state: count-up timer, delivery goal, star rating. Authority only
## advances it; a later task replicates it to clients.

enum State { PLAYING, WON }

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath

@export var delivery_goal: int = 3
@export var star_3_threshold: float = 45.0
@export var star_2_threshold: float = 70.0
## Practice: deliveries still respawn items but never end the run, and the
## timer stays at zero.
var practice: bool = false

signal game_won(elapsed_time: float, stars: int)

var state: State = State.PLAYING
var elapsed_time: float = 0.0
var deliveries_made: int = 0


func _ready() -> void:
	var zone: DeliveryZone = get_node(delivery_zone_path)
	zone.delivered.connect(_on_delivered)


func _process(delta: float) -> void:
	if not NetSession.is_authority():
		return
	if state != State.PLAYING or practice:
		return
	elapsed_time += delta


func get_stars() -> int:
	if elapsed_time <= star_3_threshold:
		return 3
	if elapsed_time <= star_2_threshold:
		return 2
	return 1


func reset() -> void:
	state = State.PLAYING
	elapsed_time = 0.0
	deliveries_made = 0


func _on_delivered() -> void:
	if not NetSession.is_authority() or state != State.PLAYING:
		return
	deliveries_made += 1
	if not practice and deliveries_made >= delivery_goal:
		state = State.WON
		game_won.emit(elapsed_time, get_stars())
		return
	_respawn_items()


## Refills each refillable spawner whose slot is empty. Waits one frame so
## the items DeliveryZone just queue_free'd are gone before the checks run.
func _respawn_items() -> void:
	await get_tree().process_frame
	for node in get_tree().get_nodes_in_group(Groups.SPAWNER):
		var spawner: ItemSpawner = node as ItemSpawner
		if spawner.refill_on_delivery and spawner.is_slot_free():
			spawner.spawn()
```

**Step 7: Rewrite `scenes/kitchen.tscn`**

Replace the whole file. Changes from the current file: the `Player` and `Pan` instances are gone; `Players`, `Items`, `SpawnPoints` (four `Marker3D`) and `Net` (with `PlayerSpawner` and `ItemReplicator` `MultiplayerSpawner`s) are added; a `PanSpawner` sits on the stove; second egg and plate spawners appear with `min_players = 2`; every spawner's `spawn_parent_path` points at `Items`; `KitchenLoop` loses its spawner paths.

```
[gd_scene format=3 uid="uid://d207kqisrfglh"]

[ext_resource type="PackedScene" path="res://scenes/ui/debug_overlay.tscn" id="2_overlay"]
[ext_resource type="PackedScene" path="res://scenes/items/egg.tscn" id="3_egg"]
[ext_resource type="PackedScene" uid="uid://de3ay5ratre0w" path="res://scenes/items/pan.tscn" id="4_pan"]
[ext_resource type="PackedScene" path="res://scenes/items/plate.tscn" id="5_plate"]
[ext_resource type="Script" uid="uid://gsd6besrrcdb" path="res://scripts/systems/order_system.gd" id="6_order_system"]
[ext_resource type="Script" uid="uid://dayp3jxwpudjs" path="res://scripts/systems/delivery_zone.gd" id="7_delivery_zone"]
[ext_resource type="Script" uid="uid://cb5vwqejp5fij" path="res://scripts/ui/order_board.gd" id="8_order_board"]
[ext_resource type="Script" uid="uid://d4flof3ka6g1x" path="res://scripts/systems/item_spawner.gd" id="9_item_spawner"]
[ext_resource type="Script" uid="uid://dcyasrgj5ysnk" path="res://scripts/systems/kitchen_loop.gd" id="10_kitchen_loop"]
[ext_resource type="PackedScene" path="res://scenes/ui/pause_menu.tscn" id="11_pause_menu"]
[ext_resource type="PackedScene" path="res://scenes/ui/hud.tscn" id="12_hud"]
[ext_resource type="PackedScene" path="res://scenes/ui/score_popup.tscn" id="13_score_popup"]
[ext_resource type="PackedScene" path="res://scenes/ui/end_screen.tscn" id="14_end_screen"]
[ext_resource type="Script" path="res://scripts/systems/kitchen_net.gd" id="15_kitchen_net"]

[sub_resource type="ProceduralSkyMaterial" id="ProceduralSkyMaterial_sky"]

[sub_resource type="Sky" id="Sky_env"]
sky_material = SubResource("ProceduralSkyMaterial_sky")

[sub_resource type="Environment" id="Environment_env"]
background_mode = 2
sky = SubResource("Sky_env")
ambient_light_source = 3
tonemap_mode = 2

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_floor"]
albedo_color = Color(0.7, 0.7, 0.7, 1)

[sub_resource type="BoxMesh" id="BoxMesh_floor"]
material = SubResource("StandardMaterial3D_floor")
size = Vector3(12, 0.2, 12)

[sub_resource type="BoxShape3D" id="BoxShape3D_floor"]
size = Vector3(12, 0.2, 12)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_walls"]
albedo_color = Color(0.6, 0.6, 0.65, 1)

[sub_resource type="BoxMesh" id="BoxMesh_ceiling"]
material = SubResource("StandardMaterial3D_walls")
size = Vector3(12, 0.2, 12)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_7ilqw"]
albedo_color = Color(0, 0.81960785, 0, 1)

[sub_resource type="BoxShape3D" id="BoxShape3D_ceiling"]
size = Vector3(12, 0.2, 12)

[sub_resource type="BoxMesh" id="BoxMesh_wallNS"]
material = SubResource("StandardMaterial3D_walls")
size = Vector3(12, 6, 0.2)

[sub_resource type="BoxShape3D" id="BoxShape3D_wallNS"]
size = Vector3(12, 6, 0.2)

[sub_resource type="BoxMesh" id="BoxMesh_wallEW"]
material = SubResource("StandardMaterial3D_walls")
size = Vector3(0.2, 6, 12)

[sub_resource type="BoxShape3D" id="BoxShape3D_wallEW"]
size = Vector3(0.2, 6, 12)

[sub_resource type="BoxShape3D" id="BoxShape3D_counter_stove"]
size = Vector3(1.5, 1, 1.5)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_counter"]
albedo_color = Color(0.5, 0.45, 0.4, 1)

[sub_resource type="BoxMesh" id="BoxMesh_counter"]
material = SubResource("StandardMaterial3D_counter")
size = Vector3(1.5, 1, 1.5)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_stove"]
albedo_color = Color(0.25, 0.25, 0.28, 1)

[sub_resource type="BoxMesh" id="BoxMesh_stove"]
material = SubResource("StandardMaterial3D_stove")
size = Vector3(1.5, 1, 1.5)

[sub_resource type="BoxShape3D" id="BoxShape3D_plate_rack"]

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_plate_rack"]
albedo_color = Color(0.5, 0.55, 0.6, 1)

[sub_resource type="BoxMesh" id="BoxMesh_plate_rack"]
material = SubResource("StandardMaterial3D_plate_rack")

[sub_resource type="BoxShape3D" id="BoxShape3D_pass"]
size = Vector3(2, 1, 0.8)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_pass"]
albedo_color = Color(0.7, 0.6, 0.45, 1)

[sub_resource type="BoxMesh" id="BoxMesh_pass"]
material = SubResource("StandardMaterial3D_pass")
size = Vector3(2, 1, 0.8)

[sub_resource type="BoxShape3D" id="BoxShape3D_delivery_zone"]
size = Vector3(1.8, 0.8, 0.6)

[sub_resource type="BoxShape3D" id="BoxShape3D_order_board"]
size = Vector3(2, 1.2, 0.1)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_order_board"]
albedo_color = Color(0.2, 0.2, 0.2, 1)

[sub_resource type="BoxMesh" id="BoxMesh_order_board"]
material = SubResource("StandardMaterial3D_order_board")
size = Vector3(2, 1.2, 0.1)

[node name="Kitchen" type="Node3D"]

[node name="WorldEnvironment" type="WorldEnvironment" parent="."]
environment = SubResource("Environment_env")

[node name="DirectionalLight3D" type="DirectionalLight3D" parent="."]
transform = Transform3D(0.866025, 0.353553, -0.353553, 0, 0.707107, 0.707107, 0.5, -0.612372, 0.612372, 0, 10, 0)
shadow_enabled = true

[node name="Room" type="StaticBody3D" parent="."]

[node name="Floor" type="MeshInstance3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.1, 0)
mesh = SubResource("BoxMesh_floor")

[node name="FloorCollision" type="CollisionShape3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.1, 0)
shape = SubResource("BoxShape3D_floor")

[node name="Ceiling" type="MeshInstance3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 6, 0)
mesh = SubResource("BoxMesh_ceiling")
surface_material_override/0 = SubResource("StandardMaterial3D_7ilqw")

[node name="CeilingCollision" type="CollisionShape3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 6, 0)
shape = SubResource("BoxShape3D_ceiling")

[node name="WallN" type="MeshInstance3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 3, -6)
mesh = SubResource("BoxMesh_wallNS")

[node name="WallNCollision" type="CollisionShape3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 3, -6)
shape = SubResource("BoxShape3D_wallNS")

[node name="WallS" type="MeshInstance3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 3, 6)
mesh = SubResource("BoxMesh_wallNS")

[node name="WallSCollision" type="CollisionShape3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 3, 6)
shape = SubResource("BoxShape3D_wallNS")

[node name="WallE" type="MeshInstance3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 6, 3, 0)
mesh = SubResource("BoxMesh_wallEW")

[node name="WallECollision" type="CollisionShape3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 6, 3, 0)
shape = SubResource("BoxShape3D_wallEW")

[node name="WallW" type="MeshInstance3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -6, 3, 0)
mesh = SubResource("BoxMesh_wallEW")

[node name="WallWCollision" type="CollisionShape3D" parent="Room"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -6, 3, 0)
shape = SubResource("BoxShape3D_wallEW")

[node name="Players" type="Node3D" parent="."]

[node name="Items" type="Node3D" parent="."]

[node name="SpawnPoints" type="Node3D" parent="."]

[node name="SpawnPoint0" type="Marker3D" parent="SpawnPoints"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.1, 4)

[node name="SpawnPoint1" type="Marker3D" parent="SpawnPoints"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -2, 0.1, 4)

[node name="SpawnPoint2" type="Marker3D" parent="SpawnPoints"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 0.1, 4)

[node name="SpawnPoint3" type="Marker3D" parent="SpawnPoints"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.1, 5)

[node name="Counter" type="StaticBody3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -2.5, 0, 0)

[node name="CollisionShape3D" type="CollisionShape3D" parent="Counter"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
shape = SubResource("BoxShape3D_counter_stove")

[node name="MeshInstance3D" type="MeshInstance3D" parent="Counter"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
mesh = SubResource("BoxMesh_counter")

[node name="EggSpawner" type="Node3D" parent="Counter"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.2, 0)
script = ExtResource("9_item_spawner")
item_scene = ExtResource("3_egg")
spawn_parent_path = NodePath("../../Items")

[node name="EggSpawner2" type="Node3D" parent="Counter"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.2, -0.5)
script = ExtResource("9_item_spawner")
item_scene = ExtResource("3_egg")
min_players = 2
spawn_parent_path = NodePath("../../Items")

[node name="Stove" type="StaticBody3D" parent="." groups=["stove"]]

[node name="CollisionShape3D" type="CollisionShape3D" parent="Stove"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
shape = SubResource("BoxShape3D_counter_stove")

[node name="MeshInstance3D" type="MeshInstance3D" parent="Stove"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
mesh = SubResource("BoxMesh_stove")

[node name="PanSpawner" type="Node3D" parent="Stove"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.0605681, 0)
script = ExtResource("9_item_spawner")
item_scene = ExtResource("4_pan")
refill_on_delivery = false
spawn_parent_path = NodePath("../../Items")

[node name="PlateRack" type="StaticBody3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 2.5, 0, 0)

[node name="CollisionShape3D" type="CollisionShape3D" parent="PlateRack"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
shape = SubResource("BoxShape3D_plate_rack")

[node name="MeshInstance3D" type="MeshInstance3D" parent="PlateRack"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
mesh = SubResource("BoxMesh_plate_rack")

[node name="PlateSpawner" type="Node3D" parent="PlateRack"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.1, 0)
script = ExtResource("9_item_spawner")
item_scene = ExtResource("5_plate")
spawn_parent_path = NodePath("../../Items")

[node name="PlateSpawner2" type="Node3D" parent="PlateRack"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.1, -0.5)
script = ExtResource("9_item_spawner")
item_scene = ExtResource("5_plate")
min_players = 2
spawn_parent_path = NodePath("../../Items")

[node name="OrderSystem" type="Node" parent="."]
script = ExtResource("6_order_system")

[node name="KitchenLoop" type="Node" parent="."]
script = ExtResource("10_kitchen_loop")
delivery_zone_path = NodePath("../Pass/DeliveryZone")

[node name="Net" type="Node" parent="."]
script = ExtResource("15_kitchen_net")

[node name="PlayerSpawner" type="MultiplayerSpawner" parent="Net"]
spawn_path = NodePath("../../Players")

[node name="ItemReplicator" type="MultiplayerSpawner" parent="Net"]
_spawnable_scenes = PackedStringArray("res://scenes/items/egg.tscn", "res://scenes/items/pan.tscn", "res://scenes/items/plate.tscn")
spawn_path = NodePath("../../Items")

[node name="Pass" type="StaticBody3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 3)

[node name="CollisionShape3D" type="CollisionShape3D" parent="Pass"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
shape = SubResource("BoxShape3D_pass")

[node name="MeshInstance3D" type="MeshInstance3D" parent="Pass"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
mesh = SubResource("BoxMesh_pass")

[node name="DeliveryZone" type="Area3D" parent="Pass"]
collision_layer = 0
collision_mask = 4
script = ExtResource("7_delivery_zone")
order_system_path = NodePath("../../OrderSystem")

[node name="CollisionShape3D" type="CollisionShape3D" parent="Pass/DeliveryZone"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.4, 0)
shape = SubResource("BoxShape3D_delivery_zone")

[node name="OrderBoard" type="StaticBody3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 2.5, -5.8)

[node name="CollisionShape3D" type="CollisionShape3D" parent="OrderBoard"]
shape = SubResource("BoxShape3D_order_board")

[node name="MeshInstance3D" type="MeshInstance3D" parent="OrderBoard"]
mesh = SubResource("BoxMesh_order_board")

[node name="TicketLabel" type="Label3D" parent="OrderBoard"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0.06)
pixel_size = 0.01
text = "1× Fried Egg"
font_size = 64
script = ExtResource("8_order_board")
order_system_path = NodePath("../../OrderSystem")

[node name="DebugOverlay" parent="." instance=ExtResource("2_overlay")]

[node name="PauseMenu" parent="." instance=ExtResource("11_pause_menu")]

[node name="HUD" parent="." instance=ExtResource("12_hud")]
delivery_zone_path = NodePath("../Pass/DeliveryZone")
kitchen_loop_path = NodePath("../KitchenLoop")
popup_scene = ExtResource("13_score_popup")

[node name="EndScreen" parent="." instance=ExtResource("14_end_screen")]
kitchen_loop_path = NodePath("../KitchenLoop")
```

Notes for the executor:
- `unique_id=` attributes were dropped on purpose; Godot regenerates them on the next editor save.
- The `Net` node must come **after** `Players`, `Items` and `SpawnPoints` in the file so its `@onready` lookups resolve, and after `KitchenLoop`/`OrderSystem` for Task 6.
- `PanSpawner` is at the pan's old global position `(0, 1.0605681, 0)` so `tests/smoke_test.gd`'s `STOVE_PAN_POS` stays valid.
- `SpawnPoint0` is the old `Player` position `(0, 0.1, 4)` so every existing player-relative check keeps its geometry.

**Step 8: Run the smoke test**

```powershell
& $GODOT --headless --path . --script res://tests/smoke_test.gd
```

Expected: `SUMMARY: 94 passed, 0 failed, 1 xfailed`. If `boot.items` reports `pans=0`, the `PanSpawner`'s deferred spawn did not run: check `NetSession.is_authority()` is true (role OFFLINE) and that `ItemSpawner._ready` ran (`Groups.SPAWNER` group).

**Step 9: Commit**

```
git add -A
git commit -m "Restructure kitchen: Players/Items containers, spawn points, KitchenNet, pan via spawner"
```

### Task 3: Player network authority and the two-peer ENet test

Each `Player` is owned by the peer it is named after. Only the owner reads input, runs movement, and has the live camera; everyone else sees a capsule driven by a `MultiplayerSynchronizer`. This task also lands the two-process ENet test harness that every later task extends.

**Files:**
- Create: `tests/net_test.gd` (launcher), `tests/net_test_body.gd` (checks)
- Create: `tests/run_net_test.ps1`
- Create: `scenes/sync/player_sync.tres`
- Modify: `scripts/player.gd` (rewrite)
- Modify: `scenes/player.tscn` (add synchronizer)

**Step 1: Create the test runner `tests/run_net_test.ps1`**

```powershell
# Runs tests/net_test.gd twice (host, then client) over ENet on localhost and
# merges their PASS/FAIL output. Exit code is non-zero if either half failed.
param(
    [string]$Godot = "$env:USERPROFILE\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe",
    [int]$Port = 7777
)
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$hostLog = Join-Path $env:TEMP "net_test_host.log"
$clientLog = Join-Path $env:TEMP "net_test_client.log"

$common = @("--headless", "--path", $projectRoot, "--script", "res://tests/net_test.gd", "--")
$hostProc = Start-Process -FilePath $Godot -ArgumentList ($common + @("role=host", "port=$Port")) `
    -PassThru -NoNewWindow -RedirectStandardOutput $hostLog
Start-Sleep -Seconds 4
$clientProc = Start-Process -FilePath $Godot -ArgumentList ($common + @("role=client", "port=$Port")) `
    -PassThru -NoNewWindow -RedirectStandardOutput $clientLog

if (-not $clientProc.WaitForExit(150000)) { $clientProc.Kill() }
if (-not $hostProc.WaitForExit(60000)) { $hostProc.Kill() }

Get-Content $hostLog | Select-String -Pattern "^(PASS|FAIL|XFAIL|SUMMARY)|SCRIPT ERROR|ERROR:"
Get-Content $clientLog | Select-String -Pattern "^(PASS|FAIL|XFAIL|SUMMARY)|SCRIPT ERROR|ERROR:"

$failed = ($hostProc.ExitCode -ne 0) -or ($clientProc.ExitCode -ne 0)
if ($failed) { Write-Host "NET TEST FAILED (host=$($hostProc.ExitCode) client=$($clientProc.ExitCode))"; exit 1 }
Write-Host "NET TEST PASSED"
exit 0
```

**Step 2: Create the launcher `tests/net_test.gd`**

Same split as `tests/smoke_test.gd` (see its header): a `--script` MainLoop is compiled before autoloads exist and eagerly compiles every `class_name` it types, and those scripts name `NetSession`. So the entry point is a tiny launcher and the checks live in a Node body loaded once the autoloads are on `root`.

```gdscript
extends SceneTree
## Two-process ENet replication test entry point. Run via tests/run_net_test.ps1
## or by hand (see net_test_body.gd). Split from the body for the same reason
## as smoke_test.gd: the body names class_name scripts that name autoloads.

const BODY_SCRIPT: String = "res://tests/net_test_body.gd"


func _initialize() -> void:
	var body_script: GDScript = load(BODY_SCRIPT) as GDScript
	var body: Node = body_script.new() as Node
	body.name = "NetTest"
	get_tree().root.add_child(body)
```

**Step 2b: Create the body `tests/net_test_body.gd` (the failing test)**

This is the complete scaffold, written as a Node like `tests/smoke_test_body.gd`. Later tasks insert extra checks into `tests/net_test_body.gd` at the marked `# --- Task N ---` lines and bump `EXPECTED_CHECKS`.

```gdscript
extends Node
## Two-process headless replication test over ENet on localhost (the checks;
## tests/net_test.gd is the --script launcher).
##
## Run both halves with tests/run_net_test.ps1, or by hand in two consoles:
##   Godot_console.exe --headless --path . --script res://tests/net_test.gd -- role=host port=7777
##   Godot_console.exe --headless --path . --script res://tests/net_test.gd -- role=client port=7777
##
## The host runs a scripted timeline (cook, wait for the client to grab,
## deliver, start the run); the client asserts what it sees replicated.
## Each half prints PASS/FAIL lines prefixed with its role and a SUMMARY
## line, and exits 1 if any check failed or the watchdog tripped.

const KITCHEN_SCENE: String = "res://scenes/kitchen.tscn"
const PHYSICS_TPS: int = 60
const WATCHDOG_SECONDS: float = 120.0
const EXPECTED_CHECKS: Dictionary = {"host": 4, "client": 5}

# Kitchen geometry, see scenes/kitchen.tscn and tests/smoke_test.gd.
const STOVE_PAN_POS: Vector3 = Vector3(0.0, 1.0605681, 0.0)
const EGG_IN_PAN_OFFSET: Vector3 = Vector3(0.0, 0.15, 0.0)
const COUNTER_EGG_POS: Vector3 = Vector3(-2.5, 1.15, 0.5)
const PASS_PLATE_POS: Vector3 = Vector3(0.0, 1.05, 3.0)
const PASS_EGG_POS: Vector3 = Vector3(0.0, 1.15, 3.0)
const CLIENT_STAND_POS: Vector3 = Vector3(0.0, 0.1, 2.0)
const SPAWN_POINT_1: Vector3 = Vector3(-2.0, 0.1, 4.0)
const STIR_INTERVAL: int = 20
const STIR_DRIFT: float = 0.05

var _role: String = "host"
var _port: int = 7777
var _passed: int = 0
var _failed: int = 0
var _start_msec: int = 0
var _finished: bool = false

var _kitchen: Node3D
var _net: KitchenNet
var _loop: KitchenLoop
var _client_id: int = 0
var _client_gone: bool = false
var _connected: bool = false


func _ready() -> void:
	# Keep the watchdog ticking even if something pauses the tree.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_args()
	Engine.physics_ticks_per_second = PHYSICS_TPS
	_start_msec = Time.get_ticks_msec()
	_ensure_autoloads()
	# Deferred: root is still mid-add_child during _ready.
	if _role == "host":
		_run_host.call_deferred()
	else:
		_run_client.call_deferred()


func _process(_delta: float) -> void:
	if _finished:
		return
	if float(Time.get_ticks_msec() - _start_msec) / 1000.0 > WATCHDOG_SECONDS:
		print("FAIL %s.watchdog: did not finish within %.0f s" % [_role, WATCHDOG_SECONDS])
		_failed += 1
		_finish()


# ---------------------------------------------------------------------------
# Host timeline
# ---------------------------------------------------------------------------

func _run_host() -> void:
	var err: Error = NetSession.host_enet(_port)
	if not _check("host.listen", err == OK, "create_server returned %d" % err):
		_finish()
		return
	multiplayer.peer_connected.connect(func(id: int) -> void: _client_id = id)
	multiplayer.peer_disconnected.connect(func(_id: int) -> void: _client_gone = true)
	_load_kitchen()
	await _step(30)

	# --- Task 5: host holds the plate before anyone joins ---

	var joined: int = await _wait_until(func() -> bool: return _client_id != 0, PHYSICS_TPS * 40)
	if not _check("host.client_connected", joined >= 0, "no peer within 40 s"):
		_finish()
		return
	await _step(30)
	_check("host.client_player_spawned", _net.get_player(_client_id) != null,
		"no Players/%d on host" % _client_id)

	# --- Task 4: cook the egg for the client to watch ---
	# --- Task 5: wait for the client's grab and release ---
	# --- Task 6: deliver, then start the run ---

	var gone: int = await _wait_until(func() -> bool: return _client_gone, PHYSICS_TPS * 60)
	_check("host.client_left", gone >= 0, "client never disconnected")
	NetSession.leave()
	_finish()


# ---------------------------------------------------------------------------
# Client timeline
# ---------------------------------------------------------------------------

func _run_client() -> void:
	multiplayer.connected_to_server.connect(func() -> void: _connected = true)
	NetSession.prepare_client_enet("127.0.0.1", _port)
	_load_kitchen()  # KitchenNet._ready -> NetSession.kitchen_ready() connects
	var connected: int = await _wait_until(func() -> bool: return _connected, PHYSICS_TPS * 20)
	if not _check("client.connected", connected >= 0, "connected_to_server never fired"):
		_finish()
		return
	var me: int = multiplayer.get_unique_id()
	_check("client.peer_id", me > 1, "unique id=%d" % me)
	var spawned: int = await _wait_until(func() -> bool: return _net.get_player(me) != null, PHYSICS_TPS * 10)
	if not _check("client.player_spawned", spawned >= 0, "no Players/%d after 10 s" % me):
		_finish_client()
		return
	var player: Player = _net.get_player(me)
	_check("client.player_authority", player.is_multiplayer_authority(),
		"authority=%d" % player.get_multiplayer_authority())
	var host_player: Player = _net.get_player(1)
	_check("client.host_player_visible",
		host_player != null and not host_player.is_multiplayer_authority(),
		"host player missing or wrongly owned")

	# --- Task 4: item replication checks ---
	# --- Task 5: grab / release through the host ---
	# --- Task 6: delivery, mode, timer, teleport ---

	_finish_client()


func _finish_client() -> void:
	NetSession.leave()
	_finish()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _load_kitchen() -> void:
	var packed: PackedScene = load(KITCHEN_SCENE)
	_kitchen = packed.instantiate() as Node3D
	get_tree().root.add_child(_kitchen)
	get_tree().current_scene = _kitchen
	_net = _kitchen.get_node("Net") as KitchenNet
	_loop = _kitchen.get_node("KitchenLoop") as KitchenLoop


func _parse_args() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.split("=", true, 1)
		if parts.size() != 2:
			continue
		match parts[0]:
			"role":
				_role = parts[1]
			"port":
				_port = int(parts[1])


func _ensure_autoloads() -> void:
	var autoloads: Array = [
		["SteamManager", "res://scripts/net/steam_manager.gd"],
		["NetSession", "res://scripts/net/netNetSession.gd"],
	]
	for entry: Array in autoloads:
		if get_tree().root.has_node(entry[0]):
			continue
		var node: Node = (load(entry[1]) as GDScript).new()
		node.name = entry[0]
		get_tree().root.add_child(node)


func _finish() -> void:
	_finished = true
	var total: int = _passed + _failed
	var expected: int = EXPECTED_CHECKS[_role]
	if total != expected:
		_failed += 1
		print("FAIL %s.summary.count: %d checks ran, expected %d" % [_role, total, expected])
	print("SUMMARY %s: %d passed, %d failed" % [_role, _passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(check_name: String, ok: bool, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("PASS %s" % check_name)
	else:
		_failed += 1
		print("FAIL %s: %s" % [check_name, detail])
	return ok


func _step(frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame


func _wait_until(pred: Callable, max_frames: int) -> int:
	for i in range(max_frames):
		if pred.call():
			return i
		await get_tree().physics_frame
	if pred.call():
		return max_frames
	return -1


func _teleport(body: RigidBody3D, pos: Vector3) -> void:
	body.global_transform = Transform3D(Basis.IDENTITY, pos)
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.sleeping = false


func _horizontal_distance(a: Node3D, b: Node3D) -> float:
	var d: Vector3 = a.global_position - b.global_position
	return Vector2(d.x, d.z).length()


## Drops the egg into the pan (assumed on the stove) and stirs until COOKED.
func _cook_until_cooked(egg: FoodItem, pan: Pan) -> bool:
	_teleport(egg, pan.global_position + EGG_IN_PAN_OFFSET)
	var budget: int = int(egg.cook_duration * PHYSICS_TPS * 1.5) + 10
	for i in range(budget):
		if egg.state == FoodItem.State.COOKED:
			return true
		if i % STIR_INTERVAL == 0 and _horizontal_distance(egg, pan) > STIR_DRIFT:
			_teleport(egg, pan.global_position + EGG_IN_PAN_OFFSET)
		await get_tree().physics_frame
	return egg.state == FoodItem.State.COOKED
```

**Step 3: Run the net test to see it fail**

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_net_test.ps1
```

Expected: the client's `client.player_authority` fails (authority is still 1 because `Player` does not yet set it from its name), and the host player has `is_multiplayer_authority()` true on the client, failing `client.host_player_visible`. If instead the client never connects, check that Windows Firewall did not block Godot (the bind is 127.0.0.1, so it should not prompt).

**Step 4: Create the replication config `scenes/sync/player_sync.tres`**

Continuous transforms are `always` (mode 1); the crouch flag is `on_change` (mode 2). `spawn = true` so a late joiner gets the current values with the spawn.

```
[gd_resource type="SceneReplicationConfig" format=3]

[resource]
properties/0/path = NodePath(".:position")
properties/0/spawn = true
properties/0/replication_mode = 1
properties/1/path = NodePath(".:rotation")
properties/1/spawn = true
properties/1/replication_mode = 1
properties/2/path = NodePath("Head:position")
properties/2/spawn = true
properties/2/replication_mode = 1
properties/3/path = NodePath("Head:rotation")
properties/3/spawn = true
properties/3/replication_mode = 1
properties/4/path = NodePath(".:crouched")
properties/4/spawn = true
properties/4/replication_mode = 2
```

**Step 5: Add the synchronizer to `scenes/player.tscn`**

Insert after the `2_grab` ext_resource line:

```
[ext_resource type="SceneReplicationConfig" path="res://scenes/sync/player_sync.tres" id="3_sync"]
```

Append at the end of the file:

```

[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]
replication_interval = 0.033
delta_interval = 0.033
replication_config = ExtResource("3_sync")
```

**Step 6: Rewrite `scripts/player.gd`**

```gdscript
class_name Player
extends CharacterBody3D
## First-person player. Named after the peer that owns it ("1" for the host
## or solo); that peer alone reads input, moves the body and looks through
## the camera. Other peers receive position, rotation, head transform and the
## crouch flag from the MultiplayerSynchronizer in player.tscn.

@export var move_speed := 8.0
@export var acceleration := 40.0
@export var friction := 30.0
@export var air_control := 0.3
@export var jump_velocity := 9.0
@export var gravity := 25.0
@export var mouse_sensitivity := 0.0022
@export_range(-89.0, 0.0) var min_pitch := -85.0
@export_range(0.0, 89.0) var max_pitch := 85.0

@export_group("Crouch")
## Metres added to the Head's standing Y while crouched (negative = lower).
@export var crouch_height_offset := -0.6
## move_speed is multiplied by this while crouched.
@export var crouch_speed_multiplier := 0.55
## Exponential rate of the Head height lerp; higher snaps faster.
@export var crouch_lerp_speed := 12.0
## Total CapsuleShape3D height while crouched (standing height comes from the scene).
@export var crouch_capsule_height := 1.3

## The stand-up probe's bottom is lifted this far off the floor so resting on
## the ground never counts as an obstruction; its top stays at standing height.
const STAND_PROBE_LIFT: float = 0.05

## Replicated on change. The setter resizes the capsule so remote copies
## block the right volume.
var crouched: bool = false:
	set(value):
		if crouched == value:
			return
		crouched = value
		_resize_capsule(value)

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var grab_controller: GrabController = $Head/Camera3D/GrabController
@onready var skin: MeshInstance3D = $Skin
@onready var crosshair: CanvasLayer = $Crosshair

var _standing_head_y: float = 0.0
var _standing_shape_y: float = 0.0
var _standing_capsule_height: float = 0.0
# Runtime copy of the scene's capsule; mutating the shared resource would
# resize every instance of player.tscn (and dirty the editor's copy).
var _capsule: CapsuleShape3D
# Standing-sized capsule used only for the ceiling clearance query.
var _stand_probe: CapsuleShape3D


func _enter_tree() -> void:
	# Before _ready and before the MultiplayerSynchronizer initialises, so
	# it knows which peer sends and which receive.
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())


func _ready() -> void:
	_standing_head_y = head.position.y
	_standing_shape_y = collision_shape.position.y
	_capsule = (collision_shape.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
	collision_shape.shape = _capsule
	_standing_capsule_height = _capsule.height
	_stand_probe = CapsuleShape3D.new()
	_stand_probe.radius = _capsule.radius
	_stand_probe.height = _standing_capsule_height - STAND_PROBE_LIFT * 2.0
	if crouched:
		_resize_capsule(true)  # spawn state may have arrived before _ready

	var mine: bool = is_multiplayer_authority()
	camera.current = mine
	crosshair.visible = mine
	skin.visible = not mine
	if mine:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		call_deferred("_register_debug_watches")


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clamp(
			head.rotation.x,
			deg_to_rad(min_pitch),
			deg_to_rad(max_pitch),
		)


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	_update_crouch(delta)

	if not is_on_floor():
		velocity.y -= gravity * delta

	# Design choice: no jumping while crouched. A crouch-jump would let the
	# shorter capsule slip onto counters and under geometry the standing
	# player is meant to be blocked by; stand up first.
	if Input.is_action_just_pressed("jump") and is_on_floor() and not crouched:
		velocity.y = jump_velocity

	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward"),
	)
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	var speed: float = move_speed * (crouch_speed_multiplier if crouched else 1.0)
	var control := 1.0 if is_on_floor() else air_control
	if direction != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, direction.x * speed, acceleration * control * delta)
		velocity.z = move_toward(velocity.z, direction.z * speed, acceleration * control * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, friction * control * delta)
		velocity.z = move_toward(velocity.z, 0.0, friction * control * delta)

	move_and_slide()


func is_crouched() -> bool:
	return crouched


## Moves this body on its owning peer. The host calls send_teleport; the
## RPC lands on whichever peer owns the node.
func send_teleport(pos: Vector3) -> void:
	if is_multiplayer_authority():
		teleport(pos)
	else:
		teleport.rpc_id(get_multiplayer_authority(), pos)


@rpc("any_peer", "reliable")
func teleport(pos: Vector3) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return  # only the host may move players
	global_position = pos
	velocity = Vector3.ZERO


## Crouch is a held action: down while "crouch" is pressed, up as soon as it is
## released AND there is headroom. The capsule switches size instantly (physics
## needs a definite shape); only the Head eases toward its target height.
func _update_crouch(delta: float) -> void:
	var wants_crouch: bool = Input.is_action_pressed("crouch")
	if wants_crouch and not crouched:
		crouched = true
	elif not wants_crouch and crouched and _has_stand_clearance():
		crouched = false

	var target_head_y: float = _standing_head_y + (crouch_height_offset if crouched else 0.0)
	var weight: float = 1.0 - exp(-crouch_lerp_speed * delta)
	head.position.y = lerpf(head.position.y, target_head_y, weight)


## Resizes the capsule and shifts CollisionShape3D so its bottom stays on the
## same floor level (centre = standing centre minus half the height change).
func _resize_capsule(is_crouched_now: bool) -> void:
	if _capsule == null:
		return
	var height: float = crouch_capsule_height if is_crouched_now else _standing_capsule_height
	_capsule.height = height
	collision_shape.position.y = _standing_shape_y - (_standing_capsule_height - height) * 0.5


## True when a standing-height capsule fits at the player's position. Bodies in
## the "held" group are ignored so a carried pan cannot pin the player crouched.
func _has_stand_clearance() -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _stand_probe
	query.transform = global_transform * Transform3D(
		Basis.IDENTITY, Vector3(0.0, _standing_shape_y + STAND_PROBE_LIFT, 0.0))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	var hits: Array[Dictionary] = get_world_3d().direct_space_state.intersect_shape(query, 8)
	for hit: Dictionary in hits:
		var collider: Node = hit.get("collider") as Node
		if collider == null or not collider.is_in_group(Groups.HELD):
			return false
	return true


func _register_debug_watches() -> void:
	var overlay: Node = get_tree().get_first_node_in_group(Groups.DEBUG_OVERLAY)
	if overlay == null:
		return
	var grab: GrabController = grab_controller
	overlay.watch("held", Callable(grab, "held_body_name"))
	overlay.watch("crouched", func() -> String: return str(crouched))
	overlay.watch("egg.state", func() -> String:
		var f: FoodItem = get_tree().get_first_node_in_group(Groups.FOOD) as FoodItem
		return f.state_name() if f else "-")
	overlay.watch("egg.seconds", func() -> String:
		var f: FoodItem = get_tree().get_first_node_in_group(Groups.FOOD) as FoodItem
		return "%.1fs" % f.cook_elapsed_seconds() if f else "-")
	overlay.watch("egg.progress", func() -> String:
		var f: FoodItem = get_tree().get_first_node_in_group(Groups.FOOD) as FoodItem
		return "%.2f" % f.cook_progress if f else "-")
	overlay.watch("pan.on_stove", func() -> String:
		var p: Pan = get_tree().get_first_node_in_group(Groups.PAN) as Pan
		return p.on_stove_text() if p else "-")
	overlay.watch("plate.contents", func() -> String:
		var pl: Plate = get_tree().get_first_node_in_group(Groups.PLATE) as Plate
		return pl.container.contents_text() if pl else "-")
	var orders: OrderSystem = get_node_or_null("/root/Kitchen/OrderSystem") as OrderSystem
	if orders:
		overlay.watch("order", Callable(orders, "current_order_text"))
```

**Step 7: Run both tests**

```powershell
& $GODOT --headless --path . --script res://tests/smoke_test.gd
powershell -ExecutionPolicy Bypass -File tests/run_net_test.ps1
```

Expected: smoke `SUMMARY: 94 passed, 0 failed, 1 xfailed` (the `crouch.*` checks still pass because `_set_crouched` became the `crouched` setter). Net test: `SUMMARY host: 4 passed, 0 failed`, `SUMMARY client: 5 passed, 0 failed`, `NET TEST PASSED`.

If `client.player_spawned` fails with a console error like `Condition "!node" is true` on the client, the host sent the spawn before the client's kitchen existed: confirm `NetSession.kitchen_ready()` is only called from `KitchenNet._ready` (after the scene is in the tree).

**Step 8: Commit**

```
git add -A
git commit -m "Player authority per peer, player synchronizer, two-peer ENet test harness"
```

### Task 4: Item replication and authority gating

Every item (egg, pan, plate) gets a `NetBody` child that the host samples and the clients ease toward, plus a `MultiplayerSynchronizer`. Cooking, delivery and spawning already run only on the authority (Task 2); this task gates the remaining per-frame systems and makes egg colour follow synced progress on clients.

**Files:**
- Create: `scripts/net/net_body.gd`
- Create: `scenes/sync/egg_sync.tres`, `scenes/sync/container_sync.tres`
- Modify: `scenes/items/egg.tscn` (rewrite), `scenes/items/pan.tscn`, `scenes/items/plate.tscn` (append)
- Modify: `scripts/items/food_item.gd`, `scripts/systems/cook_slot.gd`, `scripts/systems/delivery_zone.gd`
- Modify: `tests/net_test.gd`

**Step 1: Add the failing checks to `tests/net_test.gd`**

In `tests/net_test_body.gd`, set `EXPECTED_CHECKS` to `{"host": 5, "client": 11}`.

Replace the host line `# --- Task 4: cook the egg for the client to watch ---` with:

```gdscript
	var egg: FoodItem = get_tree().get_first_node_in_group("food") as FoodItem
	var pan: Pan = get_tree().get_first_node_in_group("pan") as Pan
	var cooked: bool = await _cook_until_cooked(egg, pan)
	_check("host.egg_cooked", cooked, "state=%s" % egg.state_name())
	# Park it on the counter so it stops cooking while the client reacts.
	_teleport(egg, COUNTER_EGG_POS)
```

Replace the client line `# --- Task 4: item replication checks ---` with:

```gdscript
	var egg_seen: int = await _wait_until(
		func() -> bool: return get_tree().get_first_node_in_group("food") != null, PHYSICS_TPS * 5)
	if not _check("client.sees_egg", egg_seen >= 0, "no food node replicated in 5 s"):
		_finish_client()
		return
	var egg: FoodItem = get_tree().get_first_node_in_group("food") as FoodItem
	_check("client.egg_frozen", egg.freeze, "client egg is simulating physics")
	_check("client.egg_parent", egg.get_parent() == _kitchen.get_node("Items"),
		"parent=%s" % egg.get_parent().name)
	var progressing: int = await _wait_until(
		func() -> bool: return egg.cook_progress > 0.25, PHYSICS_TPS * 20)
	_check("client.cook_progress_syncs", progressing >= 0, "progress=%.2f" % egg.cook_progress)
	var cooked: int = await _wait_until(
		func() -> bool: return egg.state == FoodItem.State.COOKED, PHYSICS_TPS * 20)
	_check("client.state_syncs", cooked >= 0, "state=%s" % egg.state_name())
	var on_counter: int = await _wait_until(
		func() -> bool: return egg.global_position.distance_to(COUNTER_EGG_POS) < 0.5, PHYSICS_TPS * 5)
	_check("client.position_syncs", on_counter >= 0, "egg at %s" % egg.global_position)
```

**Step 2: Run the net test to see it fail**

Expected: `client.sees_egg` fails (nothing replicates yet: the item scenes have no synchronizer, and without `spawn`-flagged state the client copy never moves). The host half passes its 5.

**Step 3: Create `scripts/net/net_body.gd`**

```gdscript
class_name NetBody
extends Node
## Replication helper parented to every networked RigidBody3D item (egg,
## pan, plate). The item's MultiplayerSynchronizer streams this node's
## properties from the host:
##  - net_position / net_rotation: sampled from the body every physics tick
##    on the host; on clients the frozen body eases toward them and snaps
##    when the error exceeds snap_distance (respawn, teleport).
##  - held_by: peer id of the player holding the item, or NOBODY. Written by
##    the host's GrabController; clients mirror it into the "held" group and
##    a collision exception with their own player.

const NOBODY: int = -1

@export var snap_distance: float = 1.0
## Exponential approach rate toward the last received transform.
@export var smoothing: float = 20.0

var net_position: Vector3 = Vector3.ZERO:
	set(value):
		net_position = value
		_received = true
var net_rotation: Vector3 = Vector3.ZERO
var held_by: int = NOBODY:
	set(value):
		var previous: int = held_by
		held_by = value
		if _body != null and not NetSession.is_authority():
			_apply_held_by(previous)

var _body: RigidBody3D
var _received: bool = false


static func of(body: Node) -> NetBody:
	return body.get_node_or_null("NetBody") as NetBody


func _ready() -> void:
	_body = get_parent() as RigidBody3D
	if NetSession.is_authority():
		net_position = _body.global_position
		net_rotation = _body.global_rotation
		_received = false
		return
	_body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_body.freeze = true
	if held_by != NOBODY:
		_apply_held_by(NOBODY)


func _physics_process(delta: float) -> void:
	if NetSession.is_authority():
		net_position = _body.global_position
		net_rotation = _body.global_rotation
		return
	if not _received:
		return
	var target_basis := Basis.from_euler(net_rotation)
	if _body.global_position.distance_to(net_position) > snap_distance:
		_body.global_transform = Transform3D(target_basis, net_position)
		return
	var weight: float = 1.0 - exp(-smoothing * delta)
	var from_quat := Quaternion(_body.global_basis.orthonormalized())
	var to_quat := Quaternion(target_basis)
	_body.global_transform = Transform3D(
		Basis(from_quat.slerp(to_quat, weight)),
		_body.global_position.lerp(net_position, weight))


func _apply_held_by(previous: int) -> void:
	if held_by == NOBODY:
		_body.remove_from_group(Groups.HELD)
	else:
		_body.add_to_group(Groups.HELD)
	var me: int = multiplayer.get_unique_id()
	var my_player: Player = _local_player()
	if my_player == null:
		return
	if previous == me and held_by != me:
		_body.remove_collision_exception_with(my_player)
	elif held_by == me and previous != me:
		_body.add_collision_exception_with(my_player)


func _local_player() -> Player:
	var net: KitchenNet = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	return net.get_player(multiplayer.get_unique_id()) if net else null
```

**Step 4: Create the replication configs**

`scenes/sync/egg_sync.tres`:

```
[gd_resource type="SceneReplicationConfig" format=3]

[resource]
properties/0/path = NodePath("NetBody:net_position")
properties/0/spawn = true
properties/0/replication_mode = 1
properties/1/path = NodePath("NetBody:net_rotation")
properties/1/spawn = true
properties/1/replication_mode = 1
properties/2/path = NodePath(".:cook_progress")
properties/2/spawn = true
properties/2/replication_mode = 1
properties/3/path = NodePath(".:state")
properties/3/spawn = true
properties/3/replication_mode = 2
properties/4/path = NodePath("NetBody:held_by")
properties/4/spawn = true
properties/4/replication_mode = 2
```

`scenes/sync/container_sync.tres` (pan and plate share it):

```
[gd_resource type="SceneReplicationConfig" format=3]

[resource]
properties/0/path = NodePath("NetBody:net_position")
properties/0/spawn = true
properties/0/replication_mode = 1
properties/1/path = NodePath("NetBody:net_rotation")
properties/1/spawn = true
properties/1/replication_mode = 1
properties/2/path = NodePath("NetBody:held_by")
properties/2/spawn = true
properties/2/replication_mode = 2
```

**Step 5: Rewrite `scenes/items/egg.tscn`**

```
[gd_scene load_steps=6 format=3]

[ext_resource type="Script" path="res://scripts/items/food_item.gd" id="1_food"]
[ext_resource type="Script" path="res://scripts/net/net_body.gd" id="2_net_body"]
[ext_resource type="SceneReplicationConfig" path="res://scenes/sync/egg_sync.tres" id="3_sync"]

[sub_resource type="SphereShape3D" id="SphereShape3D_egg"]
radius = 0.07

[sub_resource type="SphereMesh" id="SphereMesh_egg"]
radius = 0.07
height = 0.14

[node name="Egg" type="RigidBody3D"]
collision_layer = 4
collision_mask = 7
mass = 0.1
continuous_cd = true
script = ExtResource("1_food")

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
shape = SubResource("SphereShape3D_egg")

[node name="MeshInstance3D" type="MeshInstance3D" parent="."]
mesh = SubResource("SphereMesh_egg")

[node name="NetBody" type="Node" parent="."]
script = ExtResource("2_net_body")

[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]
replication_interval = 0.033
delta_interval = 0.033
replication_config = ExtResource("3_sync")
```

**Step 6: Extend `scenes/items/pan.tscn` and `scenes/items/plate.tscn`**

For **pan.tscn**, insert after the `[ext_resource ... cook_slot.gd ...]` line:

```
[ext_resource type="Script" path="res://scripts/net/net_body.gd" id="4_net_body"]
[ext_resource type="SceneReplicationConfig" path="res://scenes/sync/container_sync.tres" id="5_sync"]
```

and append to the end of the file:

```

[node name="NetBody" type="Node" parent="."]
script = ExtResource("4_net_body")

[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]
replication_interval = 0.033
delta_interval = 0.033
replication_config = ExtResource("5_sync")
```

For **plate.tscn**, insert after the `[ext_resource ... food_container.gd ...]` line:

```
[ext_resource type="Script" path="res://scripts/net/net_body.gd" id="3_net_body"]
[ext_resource type="SceneReplicationConfig" path="res://scenes/sync/container_sync.tres" id="4_sync"]
```

and append the same two nodes with `ExtResource("3_net_body")` and `ExtResource("4_sync")`.

Check the ids you chose do not collide with existing ids in each file (`grep 'id="' scenes/items/pan.tscn`). If they do, pick free ones and use them consistently.

**Step 7: Client-side egg colour and authority gates**

`scripts/items/food_item.gd`: add

```gdscript
func _process(_delta: float) -> void:
	# Clients never tick_cook; cook_progress arrives from the host, so the
	# colour has to follow it here.
	if not NetSession.is_authority():
		_update_color()
```

`scripts/systems/cook_slot.gd`, first lines of `_physics_process`:

```gdscript
	if not NetSession.is_authority():
		return
```

`scripts/systems/delivery_zone.gd`, first lines of `_physics_process`:

```gdscript
	if not NetSession.is_authority():
		return
```

**Step 8: Run both tests**

Expected: smoke unchanged; net `SUMMARY host: 5 passed`, `SUMMARY client: 11 passed`, `NET TEST PASSED`.

Failure guide:
- `client.egg_frozen` fails: `NetBody._ready` ran with `NetSession.is_authority()` true on the client. The client's role must be `CLIENT` before the kitchen loads (`prepare_client_enet` runs first in the test).
- `client.position_syncs` fails but `cook_progress_syncs` passes: `net_position` is not in the config, or `NetBody` is not the node name the config path uses.
- `client.state_syncs` fails while progress passes: `state` is an enum stored as int; make sure the path is `.:state` on the egg root, not on `NetBody`.

**Step 9: Commit**

```
git add -A
git commit -m "Replicate items: NetBody smoothing, item synchronizers, authority gates"
```

### Task 5: Grab, release and throw through the host

The owning peer still aims locally (ray + assist against its frozen copies), but taking an item is a request the host validates. `NetBody.held_by` is the replicated truth; a client's `is_holding()` reads it back.

**Files:**
- Modify: `scripts/systems/grab_controller.gd` (rewrite)
- Modify: `tests/net_test.gd`

**Step 1: Add the failing checks to `tests/net_test.gd`**

In `tests/net_test_body.gd`, set `EXPECTED_CHECKS` to `{"host": 8, "client": 17}`.

Replace the host line `# --- Task 5: host holds the plate before anyone joins ---` with:

```gdscript
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var host_grab: GrabController = _net.get_player(1).grab_controller
	host_grab.request_grab(plate.get_path())
	await _step(2)
	_check("host.plate_held",
		host_grab.is_holding() and NetBody.of(plate).held_by == 1,
		"holding=%s held_by=%d" % [host_grab.is_holding(), NetBody.of(plate).held_by])
```

Replace the host line `# --- Task 5: wait for the client's grab and release ---` with:

```gdscript
	var egg_net: NetBody = NetBody.of(egg)
	var grabbed: int = await _wait_until(
		func() -> bool: return egg_net.held_by == _client_id, PHYSICS_TPS * 20)
	_check("host.client_grabbed_egg", grabbed >= 0, "held_by=%d" % egg_net.held_by)
	var released: int = await _wait_until(
		func() -> bool: return egg_net.held_by == NetBody.NOBODY, PHYSICS_TPS * 20)
	_check("host.client_released_egg", released >= 0, "held_by=%d" % egg_net.held_by)
	host_grab.request_release()
	await _step(2)
```

Replace the client line `# --- Task 5: grab / release through the host ---` with:

```gdscript
	var plate_seen: int = await _wait_until(func() -> bool:
		var p: Node = get_tree().get_first_node_in_group("plate")
		return p != null and NetBody.of(p) != null and NetBody.of(p).held_by == 1, PHYSICS_TPS * 5)
	_check("client.late_join_held_by", plate_seen >= 0, "plate held_by never became 1")
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	_check("client.late_join_held_group", plate != null and plate.is_in_group("held"),
		"plate not in 'held' group on the client")

	player.global_position = CLIENT_STAND_POS  # ours to move
	await _step(5)
	var grab: GrabController = player.grab_controller
	grab.request_grab(plate.get_path())
	await _step(30)
	_check("client.grab_taken_rejected",
		not grab.is_holding() and grab.last_reject == GrabController.Reject.TAKEN,
		"holding=%s reject=%d" % [grab.is_holding(), grab.last_reject])

	grab.request_grab(egg.get_path())
	var held: int = await _wait_until(func() -> bool: return grab.is_holding(), PHYSICS_TPS * 5)
	_check("client.grab_rpc", held >= 0 and NetBody.of(egg).held_by == me,
		"holding=%s held_by=%d" % [grab.is_holding(), NetBody.of(egg).held_by])
	_check("client.held_name", grab.held_body_name() == egg.name,
		"held=%s expected=%s" % [grab.held_body_name(), egg.name])
	await _step(30)
	grab.request_release()
	var released: int = await _wait_until(func() -> bool: return not grab.is_holding(), PHYSICS_TPS * 5)
	_check("client.release_rpc", released >= 0 and NetBody.of(egg).held_by == NetBody.NOBODY,
		"holding=%s held_by=%d" % [grab.is_holding(), NetBody.of(egg).held_by])
```

**Step 2: Run the net test to see it fail**

Expected: parse error in `net_test.gd` (`request_grab`, `last_reject`, `Reject` do not exist). That is the failing state.

**Step 3: Rewrite `scripts/systems/grab_controller.gd`**

```gdscript
class_name GrabController
extends Node3D
## Grabs, carries, releases and throws RigidBody3D items.
##
## Aiming (the centre ray and the sphere-sweep assist) runs on the peer that
## owns the player. Taking an item is a request to the host, who owns every
## item: a direct call when this peer is the host, an RPC otherwise. The host
## validates, takes the item exactly as in solo play (gravity off, "held"
## group, collision exception with the holder's body) and records the holder
## in NetBody.held_by, which replicates to everyone. On a client, is_holding()
## reads that property back rather than any local state.

@export var grab_range: float = 4.0
@export var break_distance: float = 1.75
@export var throw_speed: float = 22.0
@export var pull_strength: float = 25.0
@export var max_pull_speed: float = 20.0
@export var orientation_stiffness: float = 25.0
@export var max_angular_speed: float = 20.0

@export_node_path("Node3D") var hold_target_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("CollisionObject3D") var exclude_body_path: NodePath

@export_group("Grab assist")
## When the precise centre ray misses, sweep a small sphere along the aim
## line so fiddly items (egg radius 0.07) can still be picked up.
@export var grab_assist_enabled: bool = true
## Radius of the assist sphere in metres. Larger is more forgiving.
@export var grab_assist_radius: float = 0.12

enum Reject { NONE, TAKEN, OUT_OF_REACH, NOT_GRABBABLE }

## Spacing of the assist sphere samples along the aim line, in metres.
const GRAB_ASSIST_STEP: float = 0.25
## Slack the host allows beyond grab_range when re-checking a client's
## request, to absorb one round trip of movement.
const REACH_TOLERANCE: float = 0.5

## Physics layers (see [layer_names] in project.godot): 1 = World, 4 = Items.
const LAYER_WORLD: int = 1
const LAYER_ITEMS: int = 4

## Why the last request from this peer was refused (hook for a "taken" cue).
var last_reject: Reject = Reject.NONE

var _held_body: RigidBody3D = null  # host side only
var _cached_gravity_scale: float = 1.0

@onready var hold_target: Node3D = get_node(hold_target_path)
@onready var camera: Camera3D = get_node(camera_path)
@onready var _exclude_body: CollisionObject3D = (
	get_node_or_null(exclude_body_path) as CollisionObject3D
	if not exclude_body_path.is_empty()
	else null
)


func is_holding() -> bool:
	return _current_held() != null


func held_body_name() -> String:
	var body: RigidBody3D = _current_held()
	return body.name if body else "<none>"


## Host: the body this controller is pulling. Client: the item whose
## NetBody.held_by names this controller's peer.
func _current_held() -> RigidBody3D:
	if NetSession.is_authority():
		if not is_instance_valid(_held_body):
			_held_body = null
		return _held_body
	var me: int = get_multiplayer_authority()
	for node in get_tree().get_nodes_in_group(Groups.GRABBABLE):
		var net: NetBody = NetBody.of(node)
		if net != null and net.held_by == me:
			return node as RigidBody3D
	return null


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event.is_action_pressed("interact"):
		if is_holding():
			request_release()
		else:
			var candidate: RigidBody3D = _find_ray_candidate()
			if candidate == null and grab_assist_enabled:
				candidate = _find_assist_candidate()
			if candidate != null:
				request_grab(candidate.get_path())
	elif event.is_action_pressed("throw") and is_holding():
		request_throw()


# --- Requests (owning peer) --------------------------------------------------

func request_grab(item_path: NodePath) -> void:
	last_reject = Reject.NONE
	if NetSession.is_authority():
		_server_grab(item_path)
	else:
		_server_grab.rpc_id(1, item_path)


func request_release() -> void:
	if NetSession.is_authority():
		_server_release()
	else:
		_server_release.rpc_id(1)


func request_throw() -> void:
	if NetSession.is_authority():
		_server_throw()
	else:
		_server_throw.rpc_id(1)


# --- Host side ---------------------------------------------------------------

@rpc("any_peer", "reliable")
func _server_grab(item_path: NodePath) -> void:
	if not NetSession.is_authority() or not _sender_is_owner():
		return
	if is_holding():
		return
	var body: RigidBody3D = get_node_or_null(item_path) as RigidBody3D
	var reason: Reject = _validate_grab(body)
	if reason != Reject.NONE:
		_notify_rejected(reason)
		return
	_take(body)


@rpc("any_peer", "reliable")
func _server_release() -> void:
	if NetSession.is_authority() and _sender_is_owner():
		_release()


@rpc("any_peer", "reliable")
func _server_throw() -> void:
	if NetSession.is_authority() and _sender_is_owner():
		_throw()


## Drops whatever this controller holds (peer left, kitchen reset).
func force_release() -> void:
	if NetSession.is_authority():
		_release()


func _validate_grab(body: RigidBody3D) -> Reject:
	if body == null or not body.is_in_group(Groups.GRABBABLE):
		return Reject.NOT_GRABBABLE
	var net: NetBody = NetBody.of(body)
	if net != null and net.held_by != NetBody.NOBODY:
		return Reject.TAKEN
	if body.is_in_group(Groups.HELD):
		return Reject.TAKEN
	if body.global_position.distance_to(camera.global_position) > grab_range + REACH_TOLERANCE:
		return Reject.OUT_OF_REACH
	return Reject.NONE


## True when the call came from this controller's own peer: locally (sender
## 0) or over RPC from the player that owns this node.
func _sender_is_owner() -> bool:
	var sender: int = multiplayer.get_remote_sender_id()
	return sender == 0 or sender == get_multiplayer_authority()


func _notify_rejected(reason: Reject) -> void:
	var owner_peer: int = get_multiplayer_authority()
	if owner_peer == multiplayer.get_unique_id():
		_on_grab_rejected(reason)
	else:
		_on_grab_rejected.rpc_id(owner_peer, reason)


@rpc("any_peer", "reliable")
func _on_grab_rejected(reason: int) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	last_reject = reason as Reject


func _take(body: RigidBody3D) -> void:
	_cached_gravity_scale = body.gravity_scale
	_held_body = body
	body.gravity_scale = 0.0
	body.add_to_group(Groups.HELD)
	if _exclude_body:
		body.add_collision_exception_with(_exclude_body)
	var net: NetBody = NetBody.of(body)
	if net != null:
		net.held_by = get_multiplayer_authority()


func _release() -> void:
	if is_instance_valid(_held_body):
		_held_body.gravity_scale = _cached_gravity_scale
		_held_body.remove_from_group(Groups.HELD)
		if _exclude_body:
			_held_body.remove_collision_exception_with(_exclude_body)
		var net: NetBody = NetBody.of(_held_body)
		if net != null:
			net.held_by = NetBody.NOBODY
	_held_body = null


func _throw() -> void:
	if not is_instance_valid(_held_body):
		_held_body = null
		return
	var body: RigidBody3D = _held_body
	var forward: Vector3 = -camera.global_transform.basis.z
	_release()
	body.linear_velocity = forward * throw_speed


# --- Carrying (host physics) -------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not NetSession.is_authority():
		return
	if not is_instance_valid(_held_body):
		_held_body = null
		return
	var to_target: Vector3 = hold_target.global_position - _held_body.global_position
	var distance: float = to_target.length()
	if distance > break_distance:
		_release()
		return
	var desired_velocity: Vector3 = to_target * pull_strength
	if desired_velocity.length() > max_pull_speed:
		desired_velocity = desired_velocity.normalized() * max_pull_speed
	_held_body.linear_velocity = desired_velocity
	_apply_orientation_control()


func _apply_orientation_control() -> void:
	var target_quat: Quaternion = Quaternion(hold_target.global_transform.basis.orthonormalized())
	var current_quat: Quaternion = Quaternion(_held_body.global_transform.basis.orthonormalized())
	var rot_diff: Quaternion = target_quat * current_quat.inverse()
	if rot_diff.w < 0.0:
		rot_diff = Quaternion(-rot_diff.x, -rot_diff.y, -rot_diff.z, -rot_diff.w)
	var desired_angular: Vector3 = Vector3(rot_diff.x, rot_diff.y, rot_diff.z) * 2.0 * orientation_stiffness
	if desired_angular.length() > max_angular_speed:
		desired_angular = desired_angular.normalized() * max_angular_speed
	_held_body.angular_velocity = desired_angular


# --- Aiming (owning peer) ----------------------------------------------------

## Precise attempt: a single ray from the camera along its forward axis.
## Returns the grabbable body it hits, or null.
func _find_ray_candidate() -> RigidBody3D:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var to: Vector3 = from + (-camera.global_transform.basis.z) * grab_range
	# World is included so a wall or counter between the camera and an item
	# stops the ray (a StaticBody3D hit is simply not a grabbable RigidBody3D).
	var query := PhysicsRayQueryParameters3D.create(from, to, LAYER_WORLD | LAYER_ITEMS)
	query.collide_with_bodies = true
	if _exclude_body:
		query.exclude = [_exclude_body.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider := hit["collider"] as RigidBody3D
	if collider == null or not collider.is_in_group(Groups.GRABBABLE):
		return null
	return collider


## Forgiving attempt: overlap a sphere of grab_assist_radius at sample
## points every GRAB_ASSIST_STEP metres along the aim line, stopping at the
## first sample that contains a grabbable body. Among the bodies in that
## sample the one closest to the aim line wins. A candidate is only
## accepted if the camera has a clear line of sight to it, so the assist
## never grabs through walls or counters.
func _find_assist_candidate() -> RigidBody3D:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var forward: Vector3 = -camera.global_transform.basis.z
	var sphere := SphereShape3D.new()
	sphere.radius = grab_assist_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.collision_mask = LAYER_ITEMS
	query.collide_with_bodies = true
	query.collide_with_areas = false
	if _exclude_body:
		query.exclude = [_exclude_body.get_rid()]
	var distance: float = GRAB_ASSIST_STEP
	while distance <= grab_range:
		query.transform = Transform3D(Basis.IDENTITY, from + forward * distance)
		var best: RigidBody3D = null
		var best_offset: float = INF
		for result: Dictionary in space.intersect_shape(query):
			var body := result["collider"] as RigidBody3D
			if body == null or not body.is_in_group(Groups.GRABBABLE):
				continue
			var to_body: Vector3 = body.global_position - from
			var offset: float = (to_body - forward * to_body.dot(forward)).length()
			if offset < best_offset and _has_line_of_sight(from, body):
				best = body
				best_offset = offset
		if best != null:
			return best
		distance += GRAB_ASSIST_STEP
	return null


## True when a ray from `from` to the body's origin reaches it without
## touching any other body (the player and the body itself are ignored).
func _has_line_of_sight(from: Vector3, body: RigidBody3D) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		from, body.global_position, LAYER_WORLD | LAYER_ITEMS)
	query.collide_with_bodies = true
	var exclude: Array[RID] = [body.get_rid()]
	if _exclude_body:
		exclude.append(_exclude_body.get_rid())
	query.exclude = exclude
	return space.intersect_ray(query).is_empty()
```

**Step 4: Run both tests**

Expected: smoke `94 passed, 0 failed, 1 xfailed` (every `grab.*`, `carry.*`, `release.*`, `held_*` check runs the authority path unchanged). Net `SUMMARY host: 8 passed`, `SUMMARY client: 17 passed`, `NET TEST PASSED`.

Failure guide:
- `client.grab_rpc` fails with `held_by=-1`: the RPC never ran on the host. Check the console for `RPC ... not found` (the node path of the client's controller must be identical on both peers, which it is when the player is named by peer id) or `sender not owner`.
- `client.grab_taken_rejected` fails with `reject=0`: `_notify_rejected` RPC'd to the wrong peer; `get_multiplayer_authority()` on the controller must equal the client's id (authority propagates from `Player`).
- `host.client_released_egg` fails: the client's `request_release` is guarded by `is_holding()`, which scans `held_by`; make sure `held_by` is in `egg_sync.tres` as `on_change`.

**Step 5: Commit**

```
git add -A
git commit -m "Grab, release and throw as host-validated requests; held_by replicates"
```

### Task 6: Practice and run modes, in-place reset, late-join state, names

`KitchenNet` gains the `mode` flag, the host-only reset that swaps between practice and a fresh run without a scene change, a full-state RPC for late joiners (the static nodes' `on_change` properties are only sent when they change), and the peer-name roster.

**Files:**
- Create: `scenes/sync/loop_sync.tres`, `scenes/sync/orders_sync.tres`, `scenes/sync/net_sync.tres`
- Modify: `scripts/systems/kitchen_net.gd` (rewrite)
- Modify: `scenes/kitchen.tscn` (synchronizers on `KitchenLoop`, `OrderSystem`, `Net`)
- Modify: `tests/net_test.gd`

**Step 1: Add the failing checks to `tests/net_test.gd`**

In `tests/net_test_body.gd`, set `EXPECTED_CHECKS` to `{"host": 11, "client": 22}`.

Replace the host line `# --- Task 6: deliver, then start the run ---` with:

```gdscript
	_teleport(plate, PASS_PLATE_POS)
	await _step(10)
	_teleport(egg, PASS_EGG_POS)
	var delivered: int = await _wait_until(
		func() -> bool: return _loop.deliveries_made == 1, PHYSICS_TPS * 5)
	_check("host.delivered", delivered >= 0, "deliveries_made=%d" % _loop.deliveries_made)
	_check("host.practice_no_win", _loop.state == KitchenLoop.State.PLAYING and _net.mode == KitchenNet.Mode.PRACTICE,
		"state=%d mode=%d" % [_loop.state, _net.mode])
	await _step(30)
	await _net.start_run()
	_check("host.run_started",
		_net.mode == KitchenNet.Mode.RUN and _loop.deliveries_made == 0
		and get_tree().get_nodes_in_group("food").size() == 2 and get_tree().get_nodes_in_group("plate").size() == 2,
		"mode=%d deliveries=%d eggs=%d plates=%d" % [_net.mode, _loop.deliveries_made,
			get_tree().get_nodes_in_group("food").size(), get_tree().get_nodes_in_group("plate").size()])
```

(Two eggs and two plates: with two players in the kitchen the `min_players = 2` spawners are live.)

Replace the client line `# --- Task 6: delivery, mode, timer, teleport ---` with:

```gdscript
	_check("client.practice_mode_on_join", _net.mode == KitchenNet.Mode.PRACTICE,
		"mode=%d" % _net.mode)
	_check("client.names_synced", NetSession.peer_names.has(1) and NetSession.peer_names.has(me),
		"names=%s" % str(NetSession.peer_names))
	var delivered: int = await _wait_until(
		func() -> bool: return _loop.deliveries_made == 1, PHYSICS_TPS * 20)
	_check("client.delivery_syncs", delivered >= 0, "deliveries_made=%d" % _loop.deliveries_made)
	var run_mode: int = await _wait_until(
		func() -> bool: return _net.mode == KitchenNet.Mode.RUN, PHYSICS_TPS * 20)
	_check("client.mode_syncs", run_mode >= 0, "mode=%d" % _net.mode)
	var teleported: int = await _wait_until(
		func() -> bool: return player.global_position.distance_to(SPAWN_POINT_1) < 0.5, PHYSICS_TPS * 5)
	_check("client.teleport_rpc", teleported >= 0, "player at %s" % player.global_position)
	var ticking: int = await _wait_until(
		func() -> bool: return _loop.elapsed_time > 0.5, PHYSICS_TPS * 5)
	_check("client.timer_syncs", ticking >= 0, "elapsed_time=%.2f" % _loop.elapsed_time)
```

**Step 2: Run the net test to see it fail**

Expected: parse errors on `KitchenNet.Mode`, `_net.mode`, `_net.start_run`. That is the failing state.

**Step 3: Create the replication configs**

`scenes/sync/loop_sync.tres`:

```
[gd_resource type="SceneReplicationConfig" format=3]

[resource]
properties/0/path = NodePath(".:elapsed_time")
properties/0/spawn = true
properties/0/replication_mode = 1
properties/1/path = NodePath(".:state")
properties/1/spawn = true
properties/1/replication_mode = 2
properties/2/path = NodePath(".:deliveries_made")
properties/2/spawn = true
properties/2/replication_mode = 2
```

`scenes/sync/orders_sync.tres`:

```
[gd_resource type="SceneReplicationConfig" format=3]

[resource]
properties/0/path = NodePath(".:recipe_tag")
properties/0/spawn = true
properties/0/replication_mode = 2
properties/1/path = NodePath(".:required_count")
properties/1/spawn = true
properties/1/replication_mode = 2
```

`scenes/sync/net_sync.tres`:

```
[gd_resource type="SceneReplicationConfig" format=3]

[resource]
properties/0/path = NodePath(".:mode")
properties/0/spawn = true
properties/0/replication_mode = 2
```

**Step 4: Add the synchronizers to `scenes/kitchen.tscn`**

Insert after the `15_kitchen_net` ext_resource line:

```
[ext_resource type="SceneReplicationConfig" path="res://scenes/sync/loop_sync.tres" id="16_loop_sync"]
[ext_resource type="SceneReplicationConfig" path="res://scenes/sync/orders_sync.tres" id="17_orders_sync"]
[ext_resource type="SceneReplicationConfig" path="res://scenes/sync/net_sync.tres" id="18_net_sync"]
```

Insert directly after the `[node name="OrderSystem" ...]` block:

```
[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="OrderSystem"]
replication_config = ExtResource("17_orders_sync")
```

Directly after the `[node name="KitchenLoop" ...]` block:

```
[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="KitchenLoop"]
replication_interval = 0.033
delta_interval = 0.033
replication_config = ExtResource("16_loop_sync")
```

Directly after the `[node name="ItemReplicator" ...]` block (so it is a child of `Net`):

```
[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="Net"]
replication_config = ExtResource("18_net_sync")
```

**Step 5: Rewrite `scripts/systems/kitchen_net.gd`**

```gdscript
class_name KitchenNet
extends Node
## Owns the multiplayer shape of the kitchen: one Player per peer, the
## practice/run mode, the in-place reset between runs, the peer-name roster,
## and the full-state hand-off that late joiners need (the static nodes'
## on_change properties are only sent when they change). Lives at
## Kitchen/Net.

enum Mode { PRACTICE, RUN }

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")

@export_node_path("Node3D") var players_path: NodePath = NodePath("../Players")
@export_node_path("Node3D") var items_path: NodePath = NodePath("../Items")
@export_node_path("Node3D") var spawn_points_path: NodePath = NodePath("../SpawnPoints")
@export_node_path("KitchenLoop") var kitchen_loop_path: NodePath = NodePath("../KitchenLoop")
@export_node_path("OrderSystem") var order_system_path: NodePath = NodePath("../OrderSystem")

signal mode_changed(new_mode: Mode)

## Replicated on change (net_sync.tres). Solo play is always RUN; an online
## session starts in PRACTICE until the host starts a run.
var mode: Mode = Mode.RUN:
	set(value):
		mode = value
		_apply_mode()

@onready var _players: Node3D = get_node(players_path)
@onready var _items: Node3D = get_node(items_path)
@onready var _spawn_points: Node3D = get_node(spawn_points_path)
@onready var _loop: KitchenLoop = get_node(kitchen_loop_path)
@onready var _orders: OrderSystem = get_node(order_system_path)
@onready var _player_spawner: MultiplayerSpawner = $PlayerSpawner


func _ready() -> void:
	add_to_group(Groups.KITCHEN_NET)
	_player_spawner.spawn_function = _spawn_player_node
	if NetSession.is_authority():
		mode = Mode.PRACTICE if NetSession.is_online() else Mode.RUN
		spawn_player(multiplayer.get_unique_id())
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	else:
		_apply_mode()
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	NetSession.kitchen_ready()
	call_deferred("_register_debug_watches")


func player_count() -> int:
	return _players.get_child_count()


func get_player(peer_id: int) -> Player:
	return _players.get_node_or_null(str(peer_id)) as Player


func items_root() -> Node3D:
	return _items


func is_practice() -> bool:
	return mode == Mode.PRACTICE


# --- Players -----------------------------------------------------------------

## Host only. Spawns the Player for peer_id at the next spawn point and
## replicates it to every peer.
func spawn_player(peer_id: int) -> Player:
	var point: Node3D = _spawn_point_for(player_count())
	return _player_spawner.spawn([peer_id, point.global_position]) as Player


## MultiplayerSpawner.spawn_function: runs on every peer with the same data.
func _spawn_player_node(data: Variant) -> Node:
	var player: Player = PLAYER_SCENE.instantiate() as Player
	player.name = str(data[0])
	player.position = data[1]
	return player


func _spawn_point_for(index: int) -> Node3D:
	return _spawn_points.get_child(index % _spawn_points.get_child_count()) as Node3D


func _on_peer_connected(peer_id: int) -> void:
	spawn_player(peer_id)
	_apply_full_state.rpc_id(peer_id, mode, _loop.state, _loop.deliveries_made,
		_loop.elapsed_time, _orders.recipe_tag, _orders.required_count)


func _on_peer_disconnected(peer_id: int) -> void:
	NetSession.peer_names.erase(peer_id)
	_broadcast_names()
	var player: Player = get_player(peer_id)
	if player == null:
		return
	player.grab_controller.force_release()
	player.queue_free()


func _on_connected_to_server() -> void:
	_register_name.rpc_id(1, NetSession.local_name())


# --- Modes and reset ---------------------------------------------------------

## Host only. Locks the lobby and restarts the kitchen as a scored run.
func start_run() -> void:
	if not NetSession.is_authority():
		return
	NetSession.set_joinable(false)
	await reset_kitchen(Mode.RUN)


## Host only. Reopens the lobby and returns everyone to the practice kitchen.
func return_to_practice() -> void:
	if not NetSession.is_authority():
		return
	NetSession.set_joinable(true)
	await reset_kitchen(Mode.PRACTICE)


## Host only. Drops every held item, clears every item, returns every player
## to a spawn point, refills the spawners and restarts the loop in new_mode.
## No scene change: the spawners and synchronizers on every peer stay put.
func reset_kitchen(new_mode: Mode) -> void:
	if not NetSession.is_authority():
		return
	for node in _players.get_children():
		(node as Player).grab_controller.force_release()
	for item in _items.get_children():
		item.queue_free()
	await get_tree().process_frame
	for i in range(_players.get_child_count()):
		var player: Player = _players.get_child(i) as Player
		player.send_teleport(_spawn_point_for(i).global_position)
	_loop.reset()
	get_tree().paused = false
	for node in get_tree().get_nodes_in_group(Groups.SPAWNER):
		(node as ItemSpawner).spawn()
	mode = new_mode


func _apply_mode() -> void:
	if _loop == null:
		return  # setter ran before _ready (synchronizer spawn state)
	_loop.practice = mode == Mode.PRACTICE
	mode_changed.emit(mode)


# --- Late-join state and names ----------------------------------------------

@rpc("authority", "reliable")
func _apply_full_state(new_mode: int, loop_state: int, deliveries: int, elapsed: float,
		recipe: String, count: int) -> void:
	_loop.state = loop_state as KitchenLoop.State
	_loop.deliveries_made = deliveries
	_loop.elapsed_time = elapsed
	_orders.recipe_tag = recipe
	_orders.required_count = count
	mode = new_mode as Mode


@rpc("any_peer", "reliable")
func _register_name(display_name: String) -> void:
	if not NetSession.is_authority():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	NetSession.peer_names[sender] = display_name.substr(0, 32)
	_broadcast_names()


func _broadcast_names() -> void:
	NetSession.set_peer_names(NetSession.peer_names)
	if NetSession.is_online():
		_set_names.rpc(NetSession.peer_names)


@rpc("authority", "reliable")
func _set_names(names: Dictionary) -> void:
	NetSession.set_peer_names(names)


func _register_debug_watches() -> void:
	var overlay: Node = get_tree().get_first_node_in_group(Groups.DEBUG_OVERLAY)
	if overlay == null:
		return
	overlay.watch("net.role", func() -> String:
		return NetSession.Role.keys()[NetSession.role])
	overlay.watch("net.peer", func() -> String: return str(multiplayer.get_unique_id()))
	overlay.watch("net.players", func() -> String: return str(player_count()))
	overlay.watch("net.mode", func() -> String: return Mode.keys()[mode])
```

**Step 6: Run both tests**

Expected: smoke `94 passed, 0 failed, 1 xfailed` (solo stays `RUN`, `practice` false, and `KitchenLoop.reset` is never called). Net `SUMMARY host: 11 passed`, `SUMMARY client: 22 passed`, `NET TEST PASSED`.

Failure guide:
- `client.mode_syncs` or `client.timer_syncs` fails while `client.practice_mode_on_join` passes: the static-node synchronizers are not sending after the client's peer was swapped in. Fallback: have the host re-send `_apply_full_state` from a 0.5 s timer while online (unreliable is fine) and drop `loop_sync.tres`. Record which path you took in the design doc's "Known caveats".
- `client.teleport_rpc` fails: `send_teleport` targeted the wrong peer; the `Player`'s authority must be the client (Task 3).
- `host.run_started` reports `eggs=1`: `ItemSpawner._player_count()` found no `KitchenNet` in the group, or `min_players` was not set in the scene.

**Step 7: Commit**

```
git add -A
git commit -m "Practice/run modes with in-place reset, late-join full state, peer names"
```

### Task 7: UI for hosting, lobby, run control and clients

Menu gets Host / Solo; the Escape menu gets Invite and Start Run; a corner panel lists who is in the kitchen; HUD and end screen read replicated state instead of host-only signals; online play never pauses the tree.

**Files:**
- Create: `scenes/ui/lobby_panel.tscn`, `scripts/ui/lobby_panel.gd`
- Modify: `scenes/menu.tscn`, `scripts/menu.gd`
- Modify: `scenes/ui/pause_menu.tscn`, `scripts/ui/pause_menu.gd`
- Modify: `scenes/ui/end_screen.tscn`, `scripts/ui/end_screen.gd`
- Modify: `scripts/ui/hud.gd`, `scripts/ui/order_board.gd`
- Modify: `scenes/kitchen.tscn` (instance the lobby panel)

There is no automated test for UI. The check for this task is the smoke test staying green (it instances the HUD, pause menu and end screen) plus a manual run in the editor at the end.

**Step 1: Menu scene**

In `scenes/menu.tscn`:
- Change `text = "Start Game"` to `text = "Solo"`.
- Rename the `SettingsButton` node to `HostButton` (`name="HostButton"`) and its text to `"Host with Steam"`.
- Append a status label at the end of the file:

```

[node name="StatusLabel" type="Label" parent="Control/MarginContainer/VBoxContainer"]
layout_mode = 2
size_flags_horizontal = 0
theme_override_font_sizes/font_size = 20
text = ""
```

**Step 2: Menu script `scripts/menu.gd`**

```gdscript
extends CanvasLayer

@export_file("*.tscn") var game_scene: String = "res://scenes/kitchen.tscn"

@onready var solo_button: Button = $Control/MarginContainer/VBoxContainer/StartButton
@onready var host_button: Button = $Control/MarginContainer/VBoxContainer/HostButton
@onready var quit_button: Button = $Control/MarginContainer/VBoxContainer/QuitButton
@onready var status_label: Label = $Control/MarginContainer/VBoxContainer/StatusLabel


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	solo_button.pressed.connect(_on_solo_pressed)
	host_button.pressed.connect(_on_host_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	host_button.disabled = not SteamManager.is_ready()
	if NetSession.last_message != "":
		status_label.text = NetSession.last_message
		NetSession.last_message = ""
	elif SteamManager.is_ready():
		status_label.text = "Steam ready as %s. Accept a friend's invite or host." % SteamManager.persona_name()
	else:
		status_label.text = "Steam not detected: solo only"
	NetSession.session_ended.connect(func(reason: String) -> void: status_label.text = reason)


func _on_solo_pressed() -> void:
	NetSession.leave()
	get_tree().change_scene_to_file(game_scene)


func _on_host_pressed() -> void:
	status_label.text = "Creating Steam lobby..."
	host_button.disabled = true
	NetSession.host_steam()


func _on_quit_pressed() -> void:
	get_tree().quit()
```

**Step 3: Lobby panel**

`scenes/ui/lobby_panel.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/ui/lobby_panel.gd" id="1_lobby"]

[node name="LobbyPanel" type="CanvasLayer"]
script = ExtResource("1_lobby")

[node name="Label" type="Label" parent="."]
anchors_preset = 1
anchor_left = 1.0
anchor_right = 1.0
offset_left = -300.0
offset_top = 16.0
offset_right = -16.0
offset_bottom = 140.0
grow_horizontal = 0
horizontal_alignment = 2
text = ""
```

`scripts/ui/lobby_panel.gd`:

```gdscript
extends CanvasLayer
## Top-right roster: mode and who is in the kitchen. Hidden offline.

@onready var label: Label = $Label

var _net: KitchenNet


func _ready() -> void:
	_net = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	visible = NetSession.is_online()
	NetSession.peers_changed.connect(_refresh)
	if _net:
		_net.mode_changed.connect(func(_m: KitchenNet.Mode) -> void: _refresh())
	_refresh()


func _refresh() -> void:
	visible = NetSession.is_online()
	if not visible or _net == null:
		return
	var lines: Array[String] = []
	lines.append("PRACTICE  (host: Esc > Start Run)" if _net.is_practice() else "RUN")
	var ids: Array = NetSession.peer_names.keys()
	ids.sort()
	for id: int in ids:
		var tag: String = " (host)" if id == 1 else ""
		lines.append("%s%s" % [NetSession.peer_names[id], tag])
	label.text = "\n".join(lines)
```

Add to `scenes/kitchen.tscn` an ext_resource `[ext_resource type="PackedScene" path="res://scenes/ui/lobby_panel.tscn" id="19_lobby_panel"]` and, after the `HUD` instance block:

```

[node name="LobbyPanel" parent="." instance=ExtResource("19_lobby_panel")]
```

**Step 4: Pause menu**

In `scenes/ui/pause_menu.tscn` insert after the `ResumeButton` block:

```
[node name="InviteButton" type="Button" parent="MarginContainer/VBoxContainer"]
layout_mode = 2
text = "Invite friends"

[node name="StartRunButton" type="Button" parent="MarginContainer/VBoxContainer"]
layout_mode = 2
text = "Start Run"
```

Rewrite `scripts/ui/pause_menu.gd`:

```gdscript
extends CanvasLayer
## Escape menu. Offline it pauses the tree; online it only releases the
## mouse (pausing would stall replication), and the host gets Invite and
## Start Run here because the mouse is captured while playing.

@export_file("*.tscn") var menu_scene: String = "res://scenes/menu.tscn"

@onready var resume_button: Button = $MarginContainer/VBoxContainer/ResumeButton
@onready var invite_button: Button = $MarginContainer/VBoxContainer/InviteButton
@onready var start_run_button: Button = $MarginContainer/VBoxContainer/StartRunButton
@onready var menu_button: Button = $MarginContainer/VBoxContainer/MenuButton
@onready var quit_button: Button = $MarginContainer/VBoxContainer/QuitButton

var _net: KitchenNet


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	_net = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	resume_button.pressed.connect(_resume)
	invite_button.pressed.connect(_on_invite_pressed)
	start_run_button.pressed.connect(_on_start_run_pressed)
	menu_button.pressed.connect(_on_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if visible:
			_resume()
		else:
			_pause()


func _pause() -> void:
	var host: bool = NetSession.role == NetSession.Role.HOST
	invite_button.visible = host and SteamManager.is_ready()
	start_run_button.visible = host and _net != null and _net.is_practice()
	menu_button.text = "Leave" if NetSession.is_online() else "Main Menu"
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not NetSession.is_online():
		get_tree().paused = true


func _resume() -> void:
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_invite_pressed() -> void:
	SteamManager.open_invite_dialog(NetSession.lobby_id)


func _on_start_run_pressed() -> void:
	_resume()
	if _net:
		_net.start_run()


func _on_menu_pressed() -> void:
	get_tree().paused = false
	NetSession.leave()
	get_tree().change_scene_to_file(menu_scene)


func _on_quit_pressed() -> void:
	NetSession.leave()
	get_tree().quit()
```

**Step 5: End screen**

In `scenes/ui/end_screen.tscn` insert after the `PlayAgainButton` block:

```
[node name="PracticeButton" type="Button" parent="MarginContainer/VBoxContainer"]
layout_mode = 2
text = "Back to Practice"
```

Rewrite `scripts/ui/end_screen.gd`:

```gdscript
extends CanvasLayer
## Shown when KitchenLoop reaches WON. Polls the replicated state so it
## works on clients, where game_won never fires. Play Again and Back to
## Practice reset the kitchen in place (host only); Leave drops the session.

@export_file("*.tscn") var menu_scene: String = "res://scenes/menu.tscn"
@export_node_path("KitchenLoop") var kitchen_loop_path: NodePath

@onready var title_label: Label = $MarginContainer/VBoxContainer/TitleLabel
@onready var stars_label: Label = $MarginContainer/VBoxContainer/StarsLabel
@onready var time_label: Label = $MarginContainer/VBoxContainer/TimeLabel
@onready var play_again_button: Button = $MarginContainer/VBoxContainer/PlayAgainButton
@onready var practice_button: Button = $MarginContainer/VBoxContainer/PracticeButton
@onready var menu_button: Button = $MarginContainer/VBoxContainer/MenuButton
@onready var quit_button: Button = $MarginContainer/VBoxContainer/QuitButton

var _loop: KitchenLoop
var _net: KitchenNet


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	_loop = get_node(kitchen_loop_path)
	_net = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	play_again_button.pressed.connect(_on_play_again_pressed)
	practice_button.pressed.connect(_on_practice_pressed)
	menu_button.pressed.connect(_on_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _process(_delta: float) -> void:
	var won: bool = _loop.state == KitchenLoop.State.WON
	if won and not visible:
		_show()
	elif not won and visible:
		_hide()


func _show() -> void:
	var stars: int = _loop.get_stars()
	title_label.text = "Service Complete"
	stars_label.text = _stars_text(stars)
	time_label.text = "Time: %s" % _format_time(_loop.elapsed_time)
	var host: bool = NetSession.is_authority()
	play_again_button.visible = host
	practice_button.visible = host and NetSession.is_online()
	menu_button.text = "Leave" if NetSession.is_online() else "Main Menu"
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not NetSession.is_online():
		get_tree().paused = true


func _hide() -> void:
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_play_again_pressed() -> void:
	if _net:
		_net.start_run()


func _on_practice_pressed() -> void:
	if _net:
		_net.return_to_practice()


func _on_menu_pressed() -> void:
	get_tree().paused = false
	NetSession.leave()
	get_tree().change_scene_to_file(menu_scene)


func _on_quit_pressed() -> void:
	NetSession.leave()
	get_tree().quit()


func _stars_text(stars: int) -> String:
	var filled: String = "★".repeat(stars)
	var empty: String = "☆".repeat(3 - stars)
	return filled + empty


func _format_time(seconds: float) -> String:
	var t: int = int(seconds)
	var m: int = t / 60
	var s: int = t % 60
	return "%d:%02d" % [m, s]
```

Note: `reset_kitchen` already does `get_tree().paused = false`, so a solo Play Again unpauses through the reset.

**Step 6: HUD and order board read replicated state**

Rewrite `scripts/ui/hud.gd`:

```gdscript
extends CanvasLayer
## Delivered counter and timer. Reads KitchenLoop every frame so it works
## on clients, where the delivered signal never fires; the +1 popup keys
## off the replicated counter going up.

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath
@export_node_path("KitchenLoop") var kitchen_loop_path: NodePath
@export var popup_scene: PackedScene
@export var popup_offset: Vector3 = Vector3(0, 0.5, 0)

@onready var delivered_label: Label = $DeliveredLabel
@onready var timer_label: Label = $TimerLabel

var _zone: DeliveryZone
var _kitchen_loop: KitchenLoop
var _last_deliveries: int = 0


func _ready() -> void:
	_zone = get_node(delivery_zone_path)
	_kitchen_loop = get_node(kitchen_loop_path)
	_last_deliveries = _kitchen_loop.deliveries_made
	_refresh()


func _process(_delta: float) -> void:
	if _kitchen_loop.deliveries_made > _last_deliveries:
		_spawn_popup()
	_last_deliveries = _kitchen_loop.deliveries_made
	_refresh()


func _spawn_popup() -> void:
	if popup_scene == null or _zone == null:
		return
	var popup: Node3D = popup_scene.instantiate()
	get_tree().current_scene.add_child(popup)
	popup.global_position = _zone.global_position + popup_offset


func _refresh() -> void:
	if _kitchen_loop.practice:
		delivered_label.text = "Practice  Delivered: %d" % _kitchen_loop.deliveries_made
		timer_label.text = "--:--"
		return
	delivered_label.text = "Delivered: %d/%d" % [_kitchen_loop.deliveries_made, _kitchen_loop.delivery_goal]
	var t: float = _kitchen_loop.elapsed_time
	timer_label.text = "%d:%02d" % [int(t) / 60, int(t) % 60]
```

Rewrite `scripts/ui/order_board.gd`:

```gdscript
extends Label3D

@export_node_path("OrderSystem") var order_system_path: NodePath

var _system: OrderSystem


func _ready() -> void:
	_system = get_node(order_system_path)


func _process(_delta: float) -> void:
	# recipe_tag / required_count replicate to clients after _ready.
	if _system:
		text = _system.current_order_text()
```

**Step 7: Run the smoke test, then a manual solo run**

```powershell
& $GODOT --headless --path . --script res://tests/smoke_test.gd
```

Expected: `94 passed, 0 failed, 1 xfailed`. The `boot.*` group instances every UI scene, so a broken `.tscn` edit shows up here as a load error.

Then open the project in Godot 4.7.2 and press F5:
1. Menu shows Solo, Host with Steam (disabled without the extension), Quit and the status line `Steam not detected: solo only`.
2. Solo: kitchen loads, HUD shows `Delivered: 0/3` and a ticking timer, no lobby panel.
3. Escape: Resume / Main Menu / Quit only; the tree pauses (timer stops).
4. Deliver three eggs: end screen shows Play Again, Main Menu, Quit (no Back to Practice). Play Again resets in place: fresh egg, plate and pan, timer at 0, player back at the door.

**Step 8: Commit**

```
git add -A
git commit -m "Co-op UI: host/solo menu, invite and start-run in Escape menu, lobby roster, replicated HUD and end screen"
```

### Task 8: GodotSteam install and the Steam session flows

Everything Steam-shaped is already wired through `SteamManager` and `NetSession`; this task installs the extension, adds the dev App ID, and proves the flow with two Steam accounts.

**Files:**
- Create: `addons/godotsteam/` (downloaded, git-ignored)
- Create: `steam_appid.txt`
- Modify: `.gitignore`

**Step 1: Download and unpack GodotSteam 4.22.1 (GDExtension)**

Releases page: https://codeberg.org/godotsteam/godotsteam/releases . The GDExtension build is the tag `v4.22.1-gde`, asset `godotsteam-4.22.1-gdextension-plugin-4.4.zip` (built against godot-cpp 4.4, works on 4.4+ including 4.7.2). If the exact asset name differs, take the newest `gdextension-plugin` zip for Godot 4.4+.

```powershell
$zip = Join-Path $env:TEMP "godotsteam.zip"
Invoke-WebRequest -Uri "https://codeberg.org/godotsteam/godotsteam/releases/download/v4.22.1-gde/godotsteam-4.22.1-gdextension-plugin-4.4.zip" -OutFile $zip
Expand-Archive -Path $zip -DestinationPath (Join-Path $env:TEMP "godotsteam") -Force
Get-ChildItem (Join-Path $env:TEMP "godotsteam") -Recurse -Directory | Select-Object FullName
```

Copy the `addons/godotsteam` folder from the unpacked tree into the project so that `addons/godotsteam/godotsteam.gdextension` exists. Then delete the broken updater plugin (it has no effect on Steamworks and errors on 4.4+):

```powershell
Remove-Item -Recurse -Force addons/godotsteam/editors -ErrorAction SilentlyContinue
```

**Step 2: App ID for development**

Create `steam_appid.txt` in the project root containing exactly:

```
480
```

Do not ship this file in exports (see the design doc). It is fine to commit.

**Step 3: Git-ignore the binaries**

Append to `.gitignore`:

```

# GodotSteam GDExtension binaries (install per README: Co-op setup)
addons/godotsteam/
```

**Step 4: Verify the extension loads headless**

Create a throwaway script in your scratch directory (not the repo):

```gdscript
extends SceneTree
func _initialize() -> void:
	print("STEAM_SINGLETON=%s" % Engine.has_singleton("Steam"))
	print("STEAM_PEER_CLASS=%s" % ClassDB.class_exists("SteamMultiplayerPeer"))
	quit()
```

Run it from the project root with `--headless --path . --script <path>`. Expected output: both `true`. If `false`, the `.gdextension` file is not at `addons/godotsteam/godotsteam.gdextension` or the zip was for the wrong godot-cpp line.

Run the smoke and net tests again: both must still pass with the extension loaded (SteamManager skips init headless).

**Step 5: Manual Steam test (two accounts, two PCs or one PC + a VM)**

Both machines need Steam running and logged in to *different* accounts that are Steam friends. Add the Godot editor's *run* target as a Non-Steam Game on each (Steam > Add a Game > Add a Non-Steam Game, pointing at the Godot exe with `--path C:\Projects\firstPersonSandbox` as launch options) so the overlay works; alternatively export a Windows build (`Project > Export`, ship `steam_api64.dll` + `godotsteam.dll` next to the exe, no `steam_appid.txt`) and add that exe instead.

Checklist (record results in the README's "Steam checklist" table):

1. Both launch the game. Menu status line shows `Steam ready as <persona name>`.
2. Host presses **Host with Steam**. Kitchen loads in practice mode; lobby panel top-right shows `PRACTICE` and the host's name.
3. Host presses Escape > **Invite friends**; Steam overlay invite dialog opens; invite the second account.
4. Guest accepts the invite (overlay or Steam friends list). Guest's kitchen loads; both panels list both names; guest sees the host's capsule, the egg, pan and plate. F3 on the guest shows `net.role: CLIENT`.
5. Guest picks up the egg (E). Host sees it lift. Guest drops it in the pan; both see it cook (colour shift), F3 `egg.state` agrees on both.
6. Host holds the plate, guest tries E on it: nothing happens on the guest (rejected as taken).
7. Guest plates a cooked egg and sets it on the Pass. Both HUDs show `Practice  Delivered: 1`; items respawn on both.
8. Host presses Escape > **Start Run**. Both teleport to the door, items reset, HUD shows `Delivered: 0/3` and a timer on both.
9. Complete three deliveries together. End screen on both: host has Play Again / Back to Practice / Leave; guest has Leave only.
10. Host presses **Back to Practice**. Both return to practice, lobby panel says `PRACTICE`.
11. Guest presses Escape > **Leave**. Host's panel drops the guest; anything the guest held falls.
12. Guest re-joins via invite while the host holds the pan: the guest sees the pan held (in the host's hand) on arrival.
13. Host quits (Escape > Quit). Guest lands on the menu with `Host left`.

Note the measured feel of a held item on the guest (loose grip vs. lag) for the "Known caveats" section.

**Step 6: Commit**

```
git add -A
git commit -m "GodotSteam 4.22.1 setup: dev app id, ignore binaries, Steam checklist"
```

### Task 9: Documentation and final verification

**Files:**
- Modify: `README.md`
- Modify: `tests/README.md`
- Modify: `docs/WALKTHROUGH.md`
- Modify: `docs/plans/2026-09-22-coop-multiplayer-design.md` (caveats from testing)
- Modify: `C:\Users\Jake\.claude\projects\c--Jake-Old-PC-Docs-Resumes\memory\project-cooking-game.md`

**Step 1: README**

- **Status**: add a bullet `**Co-op shipped <date>:** Steam lobbies via GodotSteam, up to 4 players, host-authoritative physics, practice kitchen lobby, in-place run reset, two-peer ENet regression test.` and change "Next candidates" to `recipe variety, art pass, holder-owned physics if held-item lag bites`.
- **How to run**: add a `Co-op setup` subsection: install GodotSteam per Task 8 (link the releases page, note the `editors/` deletion and `steam_appid.txt`), Steam must be running, add the exe as a Non-Steam Game for the overlay.
- **How to play**: add `Co-op` steps: Host with Steam, Escape > Invite friends, guests accept, practice together, host Escape > Start Run, end screen Back to Practice.
- **Controls** table: add `Escape` row text `Pause menu (solo) / session menu with Invite and Start Run (online)`.
- **Debug overlay**: add `net.role`, `net.peer`, `net.players`, `net.mode`.
- **Automated tests**: rename the section `Automated tests`; keep the smoke test text; add the net test command, what its 33 checks cover in one paragraph, and that it needs no Steam.
- **Manual smoke test**: keep; add the Steam checklist from Task 8 as a second numbered list titled `Manual Steam test`, with a small table recording the date, Godot/GodotSteam versions, and measured held-item feel.
- **Project layout**: add `scripts/net/{net_session,steam_manager,net_body}.gd`, `scripts/systems/kitchen_net.gd`, `scripts/ui/lobby_panel.gd`, `scenes/sync/*.tres`, `scenes/ui/lobby_panel.tscn`, `tests/{net_test.gd,run_net_test.ps1}`.
- **Known limitations**: replace `Single player only; no networking` with the design doc's caveats: held-item lag on clients, chasing interpolation, no host migration, no drop-in to a live run, App ID 480 only.

**Step 2: tests/README.md**

Add a `## Two-peer net test` section: how to run (`run_net_test.ps1`, or two consoles by hand), the host timeline vs. client assertions split, the check table (`host.*` 11, `client.*` 22), that `EXPECTED_CHECKS` must be updated per role, the 120 s watchdog, the 4 s head start the runner gives the host, and that logs land in `%TEMP%\net_test_host.log` / `net_test_client.log`. Also note in the smoke-test section that the player now lives at `Players/1` and items under `Items`.

**Step 3: docs/WALKTHROUGH.md**

Add a `## Networking` block to the symptom table: `client sees frozen items that never move` (synchronizer/NetBody), `grab does nothing on a client` (RPC path / authority name), `late joiner sees wrong mode or counter` (`_apply_full_state`), `everything freezes when host opens Escape` (tree paused online), plus the F3 `net.*` watches and the two log files.

**Step 4: Design doc caveats**

Append to "Known caveats" whatever Task 6's fallback decision and Task 8's measured feel produced.

**Step 5: Memory**

Update `C:\Users\Jake\.claude\projects\c--Jake-Old-PC-Docs-Resumes\memory\project-cooking-game.md`: co-op shipped on <date>, commit hash, the two test commands, the GodotSteam install location and that `addons/godotsteam/` is git-ignored, and the open follow-ups. Update the one-line hook in `MEMORY.md` to match.

**Step 6: Final verification**

```powershell
& $GODOT --headless --path . --script res://tests/smoke_test.gd
powershell -ExecutionPolicy Bypass -File tests/run_net_test.ps1
git status --short
```

Expected: `SUMMARY: 94 passed, 0 failed, 1 xfailed`; `NET TEST PASSED` with `host: 11 passed` and `client: 22 passed`; clean tree after the commit below.

**Step 7: Commit**

```
git add -A
git commit -m "Document co-op: setup, play, tests, Steam checklist, known caveats"
```

---

## Open questions the executor should not guess on

1. **Static synchronizers after the client's peer swap** (Task 6, Step 6 failure guide). If they turn out not to send, use the periodic full-state RPC fallback and say so in the design doc. Do not restructure the scene tree to work around it.
2. **GodotSteam asset name** (Task 8, Step 1). If the release layout changed, take the newest GDExtension zip for godot-cpp 4.4+ and note the exact version installed in the README.
3. **`replication_mode` property name in `.tres` files**. If Godot 4.7 logs `Property not found: properties/0/replication_mode` when loading a sync config, open one `.tres` in the editor's inspector, set the modes there, save, and copy the resulting property names to the other files.

Everything else in this plan is a decision already made in the design doc.
