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
const EXPECTED_CHECKS: Dictionary = {"host": 12, "client": 25}

# Kitchen geometry, see scenes/kitchen.tscn and tests/smoke_test.gd.
const STOVE_PAN_POS: Vector3 = Vector3(0.0, 1.0605681, 0.0)
const EGG_IN_PAN_OFFSET: Vector3 = Vector3(0.0, 0.15, 0.0)
const COUNTER_EGG_POS: Vector3 = Vector3(-2.5, 1.15, 0.5)
const PASS_PLATE_POS: Vector3 = Vector3(0.0, 1.05, 3.0)
const PASS_EGG_POS: Vector3 = Vector3(0.0, 1.15, 3.0)
const CLIENT_STAND_POS: Vector3 = Vector3(0.0, 0.1, 2.0)
## In front of the Counter: the parked egg sits within break_distance of
## the hold target from here, so a grab is a sustained hold, not one tick.
const COUNTER_STAND_POS: Vector3 = Vector3(-2.65, 0.1, 1.9)
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
var _orders: OrderSystem
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
	# Deterministic ticket: the delivery below must not re-draw recipe 1.
	_orders.randomize_orders = false
	await _step(30)

	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var host_grab: GrabController = _net.get_player(1).grab_controller
	# The rack is out of reach of SpawnPoint0 (and past break_distance), so
	# bring the plate to hand first, as the smoke test does before grabs.
	_teleport(plate, host_grab.hold_target.global_position)
	await _step(2)
	host_grab.request_grab(plate.get_path())
	await _step(2)
	_check("host.plate_held",
		host_grab.is_holding() and NetBody.of(plate).held_by == 1,
		"holding=%s held_by=%d" % [host_grab.is_holding(), NetBody.of(plate).held_by])

	var joined: int = await _wait_until(func() -> bool: return _client_id != 0, PHYSICS_TPS * 40)
	if not _check("host.client_connected", joined >= 0, "no peer within 40 s"):
		_finish()
		return
	await _step(30)
	_check("host.client_player_spawned", _net.get_player(_client_id) != null,
		"no Players/%d on host" % _client_id)
	# Switch the ticket after the client joined so the change replicates
	# (on_change), not only the late-join snapshot.
	_orders.set_current(1)

	var egg: FoodItem = _first_egg()
	var pan: Pan = get_tree().get_first_node_in_group("pan") as Pan
	var cooked: bool = await _cook_until_cooked(egg, pan)
	_check("host.egg_cooked", cooked, "state=%s" % egg.state_name())
	# Park it on the counter so it stops cooking while the client reacts.
	_teleport(egg, COUNTER_EGG_POS)
	var egg_net: NetBody = NetBody.of(egg)
	var grabbed: int = await _wait_until(
		func() -> bool: return egg_net.held_by == _client_id, PHYSICS_TPS * 20)
	_check("host.client_grabbed_egg", grabbed >= 0, "held_by=%d" % egg_net.held_by)
	var released: int = await _wait_until(
		func() -> bool: return egg_net.held_by == NetBody.NOBODY, PHYSICS_TPS * 20)
	_check("host.client_released_egg", released >= 0, "held_by=%d" % egg_net.held_by)
	host_grab.request_release()
	await _step(2)
	_teleport(plate, PASS_PLATE_POS)
	await _step(10)
	# The ticket stayed on recipe 1 through the client's grab (the client read
	# the board right after its release). A fried egg cannot satisfy Egg on
	# Toast, so switch back before plating it.
	_check("host.order_index", _orders.current_index == 1, "index=%d" % _orders.current_index)
	_orders.set_current(0)
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
		and _foods_tagged("egg").size() == 2 and get_tree().get_nodes_in_group("plate").size() == 2,
		"mode=%d deliveries=%d eggs=%d plates=%d" % [_net.mode, _loop.deliveries_made,
			_foods_tagged("egg").size(), get_tree().get_nodes_in_group("plate").size()])

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

	var egg_seen: int = await _wait_until(
		func() -> bool: return _first_egg() != null, PHYSICS_TPS * 5)
	if not _check("client.sees_egg", egg_seen >= 0, "no egg node replicated in 5 s"):
		_finish_client()
		return
	var egg: FoodItem = _first_egg()
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

	player.global_position = COUNTER_STAND_POS
	await _step(5)
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
	player.global_position = CLIENT_STAND_POS
	_check("client.practice_mode_on_join", _net.mode == KitchenNet.Mode.PRACTICE,
		"mode=%d" % _net.mode)
	_check("client.names_synced", NetSession.peer_names.has(1) and NetSession.peer_names.has(me),
		"names=%s" % str(NetSession.peer_names))
	var order_synced: int = await _wait_until(
		func() -> bool: return _orders.current_index == 1, PHYSICS_TPS * 10)
	_check("client.order_index_syncs", order_synced >= 0, "index=%d" % _orders.current_index)
	var board: Label3D = _kitchen.get_node("OrderBoard/TicketLabel") as Label3D
	await get_tree().process_frame
	_check("client.order_board_text", board.text == "1× Egg on Toast", "board=%s" % board.text)
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

	# Stay connected long enough for the host's spawned-player check (it runs
	# 30 frames after peer_connected); leaving sooner frees Players/<me> there.
	await _step(PHYSICS_TPS * 2)
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
	_orders = _kitchen.get_node("OrderSystem") as OrderSystem


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
		["NetSession", "res://scripts/net/net_session.gd"],
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


## Every FoodItem with the given recipe tag (bread shares the "food" group).
func _foods_tagged(tag: String) -> Array[FoodItem]:
	var out: Array[FoodItem] = []
	for node in get_tree().get_nodes_in_group("food"):
		var food: FoodItem = node as FoodItem
		if food != null and food.recipe_tag == tag:
			out.append(food)
	return out


func _first_egg() -> FoodItem:
	var eggs: Array[FoodItem] = _foods_tagged("egg")
	return eggs[0] if not eggs.is_empty() else null


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
