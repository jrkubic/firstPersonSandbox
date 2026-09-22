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
