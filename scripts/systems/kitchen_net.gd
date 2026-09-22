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
