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


# --- ENet (localhost tests) -------------------------------------------------

func host_enet(port: int) -> Error:
	if is_online():
		return ERR_ALREADY_IN_USE
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
	if is_online():
		return
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
	var err: Error = ERR_UNAVAILABLE
	if peer != null and peer.has_method("create_host"):
		err = int(peer.call("create_host", 0)) as Error
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
		err = ERR_UNAVAILABLE
		if peer != null and peer.has_method("create_client"):
			err = int(peer.call("create_client", _pending_steam_host, 0)) as Error
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
