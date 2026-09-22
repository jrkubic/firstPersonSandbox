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

## Host only. Spawns the Player for peer_id at a free spawn point and
## replicates it to every peer.
func spawn_player(peer_id: int) -> Player:
	var point: Node3D = _free_spawn_point()
	return _player_spawner.spawn([peer_id, point.global_position]) as Player


## First spawn point with no current Player within 1 m of it; when every
## point is taken, cycles through them by player count.
func _free_spawn_point() -> Node3D:
	for point in _spawn_points.get_children():
		var taken: bool = false
		for player in _players.get_children():
			if player.is_queued_for_deletion():
				continue
			if (player as Node3D).global_position.distance_to(
					(point as Node3D).global_position) < 1.0:
				taken = true
				break
		if not taken:
			return point as Node3D
	return _spawn_point_for(player_count())


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
