extends Node
## Headless smoke test for the cook loop: the checks. tests/smoke_test.gd is
## the --script entry point that loads this body once the autoloads exist
## (see its header for why the split is needed).
##
## Run from the project root:
##   Godot_console.exe --headless --path . --script res://tests/smoke_test.gd
##
## Loads scenes/kitchen.tscn, drives the physics items by teleporting them,
## and asserts the RAW -> COOKING -> COOKED -> BURNED loop, the delivery
## rules, respawn, and grab/throw. Prints one "PASS"/"FAIL"/"XFAIL" line per
## check and a final "SUMMARY" line. Exit code is 0 unless a non-expected
## check fails (or the wall-clock watchdog trips).
##
## Physics runs at a fixed 60 ticks/s. Every wait is counted in physics
## frames (await get_tree().physics_frame) rather than wall time, so the number of
## cook ticks an egg receives is deterministic.

const KITCHEN_SCENE: String = "res://scenes/kitchen.tscn"
const PHYSICS_TPS: int = 60
const WATCHDOG_SECONDS: float = 180.0
# Total PASS+FAIL+XFAIL lines a complete run prints. A script error inside a
# check function aborts that coroutine silently, so a short count is a failure.
const EXPECTED_CHECKS: int = 95

# Kitchen geometry (see scenes/kitchen.tscn). Y values are body centres that
# rest just above the surface they sit on.
const STOVE_PAN_POS: Vector3 = Vector3(0.0, 1.0605681, 0.0)
const COUNTER_PAN_POS: Vector3 = Vector3(-2.5, 1.0605681, 0.0)
const EGG_IN_PAN_OFFSET: Vector3 = Vector3(0.0, 0.15, 0.0)
const PASS_PLATE_POS: Vector3 = Vector3(0.0, 1.05, 3.0)
const PASS_EGG_POS: Vector3 = Vector3(0.0, 1.15, 3.0)
# Plate resting on top of the pan disc (pan top ~1.10, plate half-height 0.015)
# and an egg resting on that plate (plate top + egg radius 0.07).
const PLATE_ON_PAN_POS: Vector3 = Vector3(0.0, 1.12, 0.0)
const EGG_ON_PLATE_OFFSET: Vector3 = Vector3(0.0, 0.09, 0.0)
# "Stirring": while cooking, re-centre the egg in the pan every STIR_INTERVAL
# physics frames once it has drifted more than STIR_DRIFT metres off-axis.
const STIR_INTERVAL: int = 20
const STIR_DRIFT: float = 0.05
# An egg resting against the pan's rim wall (inner face at 0.244 m, egg
# radius 0.07) sits ~0.174 m off-axis; anything under this is still "in the
# pan" (the disc radius is 0.25 and the CookSlot box half-extent is 0.2).
const PAN_RIM_DRIFT: float = 0.2

var _passed: int = 0
var _failed: int = 0
var _xfailed: int = 0
var _delivered_count: int = 0
var _start_msec: int = 0
var _finished: bool = false

var _kitchen: Node3D
var _zone: DeliveryZone
var _loop: KitchenLoop
var _order_system: OrderSystem
var _egg_spawner: ItemSpawner
var _plate_spawner: ItemSpawner
var _player: Player
var _camera: Camera3D
var _grab: GrabController
var _items: Node3D
var _net: KitchenNet


func _ready() -> void:
	# Keep the watchdog ticking even if a check pauses the tree.
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.physics_ticks_per_second = PHYSICS_TPS
	_start_msec = Time.get_ticks_msec()
	_ensure_autoloads()
	# Deferred: root is still busy adding this node during _ready, so the
	# kitchen cannot be added to it until the current add_child finishes.
	_run.call_deferred()


func _process(_delta: float) -> void:
	if _finished:
		return
	if float(Time.get_ticks_msec() - _start_msec) / 1000.0 > WATCHDOG_SECONDS:
		print("FAIL watchdog: test did not finish within %.0f s" % WATCHDOG_SECONDS)
		_failed += 1
		_finish()


# ---------------------------------------------------------------------------
# Test driver
# ---------------------------------------------------------------------------

func _run() -> void:
	if not await _check_boot():
		_finish()
		return
	var egg: FoodItem = _first_food()
	var pan: Pan = get_tree().get_first_node_in_group("pan") as Pan
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	await _check_cook(egg, pan)
	await _check_pause(egg, pan)
	await _check_burn(egg, pan)
	await _check_no_deliver_burned(egg, plate)
	await _check_deliver(egg, pan, plate)
	await _check_held_no_deliver(pan)
	await _check_grab()
	await _check_grab_through_wall()
	await _check_crouch()
	await _check_plate_on_pan(pan)
	await _check_carry(pan)
	await _check_break_distance()
	await _check_release_into_pan(pan)
	await _check_throw_no_tunnel()
	await _check_crouch_blocked()
	await _check_held_egg(pan)
	await _check_occupied_slot(pan)
	_finish()


func _finish() -> void:
	_finished = true
	var total: int = _passed + _failed + _xfailed
	if total != EXPECTED_CHECKS:
		_failed += 1
		print("FAIL summary.count: %d checks ran, expected %d (a check group aborted?)" % [total, EXPECTED_CHECKS])
	print("SUMMARY: %d passed, %d failed, %d xfailed" % [_passed, _failed, _xfailed])
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

## 1. Kitchen loads, spawners produce exactly one egg / plate, pan is on stove.
func _check_boot() -> bool:
	var packed: PackedScene = load(KITCHEN_SCENE)
	if packed == null:
		_check("boot", false, "could not load %s" % KITCHEN_SCENE)
		return false
	_kitchen = packed.instantiate() as Node3D
	get_tree().root.add_child(_kitchen)
	# HUD spawns its score popup under current_scene; mirror what the game does.
	get_tree().current_scene = _kitchen

	_zone = _kitchen.get_node_or_null("Pass/DeliveryZone") as DeliveryZone
	_loop = _kitchen.get_node_or_null("KitchenLoop") as KitchenLoop
	_order_system = _kitchen.get_node_or_null("OrderSystem") as OrderSystem
	_egg_spawner = _kitchen.get_node_or_null("Counter/EggSpawner") as ItemSpawner
	_plate_spawner = _kitchen.get_node_or_null("PlateRack/PlateSpawner") as ItemSpawner
	_items = _kitchen.get_node_or_null("Items") as Node3D
	_net = _kitchen.get_node_or_null("Net") as KitchenNet
	_player = _kitchen.get_node_or_null("Players/1") as Player
	_camera = _kitchen.get_node_or_null("Players/1/Head/Camera3D") as Camera3D
	_grab = _kitchen.get_node_or_null("Players/1/Head/Camera3D/GrabController") as GrabController
	var wiring_ok: bool = (
		_zone != null and _loop != null and _order_system != null
		and _egg_spawner != null and _plate_spawner != null
		and _player != null and _camera != null and _grab != null
		and _items != null and _net != null
	)
	if not _check("boot.wiring", wiring_ok, "missing node(s) under Kitchen"):
		return false
	_zone.delivered.connect(func() -> void: _delivered_count += 1)

	# Keep the debug overlay visible so its watch Callables run every frame
	# (including the "no egg / no plate" branches during respawn).
	var overlay: CanvasLayer = get_tree().get_first_node_in_group("debug_overlay") as CanvasLayer
	if overlay:
		overlay.visible = true

	# Spawns are call_deferred; then let everything drop onto its surface.
	await _step(30)

	var eggs: int = get_tree().get_nodes_in_group("food").size()
	var plates: int = get_tree().get_nodes_in_group("plate").size()
	var pans: int = get_tree().get_nodes_in_group("pan").size()
	var stoves: int = get_tree().get_nodes_in_group("stove").size()
	var counts_ok: bool = _check(
		"boot.items",
		eggs == 1 and plates == 1 and pans == 1 and stoves == 1,
		"eggs=%d plates=%d pans=%d stoves=%d" % [eggs, plates, pans, stoves],
	)
	if not counts_ok:
		return false
	var egg: FoodItem = _first_food()
	var pan: Pan = get_tree().get_first_node_in_group("pan") as Pan
	_check("boot.egg_raw", egg.state == FoodItem.State.RAW and egg.cook_progress == 0.0,
		"state=%s progress=%.2f" % [egg.state_name(), egg.cook_progress])
	_check("boot.pan_on_stove", pan.is_on_stove(), "pan.is_on_stove() == false")
	_check("boot.not_holding", not _grab.is_holding(), "held=%s" % _grab.held_body_name())
	return true


## 2. Egg in the pan on the stove: RAW -> COOKING quickly, COOKED by ~cook_duration.
func _check_cook(egg: FoodItem, pan: Pan) -> void:
	_teleport(egg, pan.global_position + EGG_IN_PAN_OFFSET)
	var to_cooking: int = await _wait_until(
		func() -> bool: return egg.state == FoodItem.State.COOKING, 10)
	_check("cook.starts", to_cooking >= 0,
		"state=%s after 10 frames" % egg.state_name())

	# Phase A (unassisted): leave the egg alone for 1.5 s and expect it to keep
	# cooking. The pan still settles at a slight pitch (its handle hangs in
	# the air), so the egg rolls toward the handle, but the rim wall segments
	# stop it inside the CookSlot and cook_progress keeps ticking. See
	# tests/README.md.
	var unassisted_frames: int = 90
	var p0: float = egg.cook_progress
	await _step(unassisted_frames)
	var gained: float = egg.cook_progress - p0
	var expected_gain: float = float(unassisted_frames) / (egg.cook_duration * PHYSICS_TPS)
	var in_pan: bool = _horizontal_distance(egg, pan) < PAN_RIM_DRIFT
	_check("cook.egg_stays_in_pan", in_pan and gained >= expected_gain - 0.02,
		"egg drifted %.2f m from pan axis; progress gained %.3f of expected %.3f in %d frames"
		% [_horizontal_distance(egg, pan), gained, expected_gain, unassisted_frames])

	# Phase B (stirred): keep re-centring the egg so CookSlot keeps ticking it,
	# and verify the tick rate: one 1/60 s tick per physics frame.
	var p1: float = egg.cook_progress
	var expected: int = int(ceil((1.0 - p1) * egg.cook_duration * PHYSICS_TPS))
	var budget: int = int(egg.cook_duration * PHYSICS_TPS * 1.5)
	var to_cooked: int = await _cook_until(egg, pan,
		func() -> bool: return egg.state == FoodItem.State.COOKED, budget)
	_check("cook.reaches_cooked", to_cooked >= 0,
		"state=%s progress=%.2f after %d frames" % [egg.state_name(), egg.cook_progress, budget])
	_check("cook.timing", to_cooked >= expected - 2 and to_cooked <= expected + 10,
		"COOKED after %d physics frames (expected ~%d from progress %.3f)" % [to_cooked, expected, p1])
	_check("cook.progress", egg.cook_progress >= 1.0 and egg.cook_progress < 1.2,
		"progress=%.3f" % egg.cook_progress)


## 3. Pan off the stove pauses cooking; back on the stove resumes it.
func _check_pause(egg: FoodItem, pan: Pan) -> void:
	# Move pan (with egg) onto the counter, which is not in the "stove" group.
	_teleport(pan, COUNTER_PAN_POS)
	_teleport(egg, COUNTER_PAN_POS + EGG_IN_PAN_OFFSET)
	await _step(5)
	_check("pause.off_stove", not pan.is_on_stove(), "pan still reports on_stove")
	var before: float = egg.cook_progress
	await _step(60)
	_check("pause.progress_frozen", is_equal_approx(egg.cook_progress, before),
		"progress %.3f -> %.3f while off stove" % [before, egg.cook_progress])
	# Back onto the stove.
	_teleport(pan, STOVE_PAN_POS)
	_teleport(egg, STOVE_PAN_POS + EGG_IN_PAN_OFFSET)
	await _step(5)
	_check("pause.back_on_stove", pan.is_on_stove(), "pan.is_on_stove() == false")
	var resumed_from: float = egg.cook_progress
	await _step(30)
	_check("pause.progress_resumes", egg.cook_progress > resumed_from + 0.05,
		"progress %.3f -> %.3f after returning to stove" % [resumed_from, egg.cook_progress])


## 4. Cooking past cook_duration + burn_duration burns the egg; progress clamps at 2.0.
func _check_burn(egg: FoodItem, pan: Pan) -> void:
	var budget: int = int(egg.burn_duration * PHYSICS_TPS * 1.5)
	var to_burned: int = await _cook_until(egg, pan,
		func() -> bool: return egg.state == FoodItem.State.BURNED, budget)
	_check("burn.reaches_burned", to_burned >= 0,
		"state=%s progress=%.2f after %d frames" % [egg.state_name(), egg.cook_progress, budget])
	await _step(10)
	_check("burn.progress_clamped", is_equal_approx(egg.cook_progress, 2.0),
		"progress=%.3f" % egg.cook_progress)
	_check("burn.state_sticky", egg.state == FoodItem.State.BURNED,
		"state=%s" % egg.state_name())


## 5. A plated BURNED egg inside the delivery zone must not be delivered.
func _check_no_deliver_burned(egg: FoodItem, plate: Plate) -> void:
	_teleport(plate, PASS_PLATE_POS)
	await _step(10)
	_teleport(egg, PASS_EGG_POS)
	await _step(15)
	_check("no_deliver_burned.plated", plate.get_contents().has(egg),
		"plate contents: %s" % plate.container.contents_text())
	_check("no_deliver_burned.order_rejects", not _order_system.check_delivery(plate),
		"OrderSystem accepted a burned egg")
	var before: int = _delivered_count
	await _step(30)
	_check("no_deliver_burned.no_signal", _delivered_count == before,
		"delivered fired %d time(s)" % (_delivered_count - before))
	_check("no_deliver_burned.plate_alive",
		is_instance_valid(plate) and is_instance_valid(egg),
		"plate or egg was freed")


## 6. A plated COOKED egg in the zone is delivered; both are freed, both respawn.
func _check_deliver(burned_egg: FoodItem, pan: Pan, plate: Plate) -> void:
	# Bin the burned egg so the food count below stays meaningful, then cook
	# a fresh one.
	burned_egg.queue_free()
	await _step(2)
	var egg: FoodItem = _egg_spawner.spawn() as FoodItem
	var spawned_ok: bool = _check("deliver.fresh_egg",
		egg != null and get_tree().get_nodes_in_group("food").size() == 1,
		"food count=%d" % get_tree().get_nodes_in_group("food").size())
	if not spawned_ok:
		return
	await _step(2)
	var cooked: bool = await _cook_until_cooked(egg, pan)
	if not _check("deliver.egg_cooked", cooked,
			"state=%s progress=%.2f" % [egg.state_name(), egg.cook_progress]):
		return

	# Plate is already resting in the delivery zone from the previous check.
	_teleport(egg, PASS_EGG_POS)
	var before: int = _delivered_count
	var to_delivered: int = await _wait_until(
		func() -> bool: return _delivered_count > before, 30)
	_check("deliver.signal", to_delivered >= 0, "delivered did not fire within 30 frames")
	await _step(5)
	_check("deliver.items_freed",
		not is_instance_valid(plate) and not is_instance_valid(egg),
		"plate valid=%s egg valid=%s" % [is_instance_valid(plate), is_instance_valid(egg)])
	var new_plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var new_egg: FoodItem = _first_food()
	_check("deliver.respawn",
		new_plate != null and new_egg != null
		and get_tree().get_nodes_in_group("plate").size() == 1
		and get_tree().get_nodes_in_group("food").size() == 1
		and new_egg.state == FoodItem.State.RAW,
		"plates=%d eggs=%d" % [get_tree().get_nodes_in_group("plate").size(), get_tree().get_nodes_in_group("food").size()])
	_check("deliver.count", _loop.deliveries_made == 1,
		"deliveries_made=%d" % _loop.deliveries_made)
	# Spawned items live under Kitchen/Items, not under the StaticBody3D
	# that carries the spawner (Counter / PlateRack).
	_check("deliver.spawn_parent",
		new_egg != null and new_plate != null
		and new_egg.get_parent() == _items and new_plate.get_parent() == _items,
		"egg parent=%s plate parent=%s" % [
			new_egg.get_parent().name if new_egg else "<none>",
			new_plate.get_parent().name if new_plate else "<none>"])
	# Both respawned items sit in their slots, so the spawners report them
	# as occupied (this is what gates the next respawn).
	_check("deliver.slots_occupied",
		not _egg_spawner.is_slot_free() and not _plate_spawner.is_slot_free(),
		"egg free=%s plate free=%s" % [_egg_spawner.is_slot_free(), _plate_spawner.is_slot_free()])


## 7. A plate in the "held" group is never delivered; releasing it delivers.
func _check_held_no_deliver(pan: Pan) -> void:
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var egg: FoodItem = _first_food()
	if not _check("held_no_deliver.setup", plate != null and egg != null,
			"missing respawned plate/egg"):
		return
	plate.add_to_group("held")
	_teleport(plate, PASS_PLATE_POS)
	await _step(10)
	var cooked: bool = await _cook_until_cooked(egg, pan)
	if not _check("held_no_deliver.egg_cooked", cooked,
			"state=%s progress=%.2f" % [egg.state_name(), egg.cook_progress]):
		return
	_teleport(egg, PASS_EGG_POS)
	await _step(15)
	_check("held_no_deliver.plated", plate.get_contents().has(egg),
		"plate contents: %s" % plate.container.contents_text())
	var before: int = _delivered_count
	await _step(30)
	_check("held_no_deliver.blocked_while_held",
		_delivered_count == before and is_instance_valid(plate),
		"delivered fired %d time(s) while held" % (_delivered_count - before))
	plate.remove_from_group("held")
	var to_delivered: int = await _wait_until(
		func() -> bool: return _delivered_count > before, 30)
	_check("held_no_deliver.delivers_after_release", to_delivered >= 0,
		"delivered did not fire within 30 frames of release")
	await _step(5)
	_check("held_no_deliver.count", _loop.deliveries_made == 2,
		"deliveries_made=%d" % _loop.deliveries_made)


## 8. Interact grabs the egg in front of the camera; throw releases it fast.
## The sphere assist also grabs an egg slightly off the centre line.
func _check_grab() -> void:
	var egg: FoodItem = _first_food()
	if not _check("grab.setup", egg != null and not _grab.is_holding(),
			"no egg or already holding"):
		return
	var forward: Vector3 = -_camera.global_transform.basis.z
	_teleport(egg, _camera.global_position + forward * 1.0)
	await _step(2)
	_press_action("interact")
	var grabbed: int = await _wait_until(func() -> bool: return _grab.is_holding(), 5)
	_check("grab.holds", grabbed >= 0, "not holding after interact")
	_check("grab.held_name", _grab.held_body_name() == egg.name,
		"held=%s expected=%s" % [_grab.held_body_name(), egg.name])
	_check("grab.held_group", egg.is_in_group("held"), "egg not in 'held' group")
	await _step(5)
	_press_action("throw")
	var thrown: int = await _wait_until(func() -> bool: return not _grab.is_holding(), 5)
	_check("grab.throw_releases", thrown >= 0, "still holding after throw")
	var speed: float = egg.linear_velocity.length()
	_check("grab.throw_speed", speed >= _grab.throw_speed * 0.9,
		"egg speed=%.2f expected >= %.1f" % [speed, _grab.throw_speed * 0.9])
	_check("grab.released_group", not egg.is_in_group("held"), "egg still in 'held' group")

	# Off-axis: the egg sits 0.15 m right of the centre line at 1 m, so the
	# precise ray (egg radius 0.07) misses and only the sphere assist can
	# catch it. With the assist disabled the same aim must fail.
	var right: Vector3 = _camera.global_transform.basis.x
	var off_axis: Vector3 = _camera.global_position + forward * 1.0 + right * 0.15
	_grab.grab_assist_enabled = false
	_teleport(egg, off_axis)
	await _step(2)
	_press_action("interact")
	await _step(3)
	_check("grab.assist_off_misses", not _grab.is_holding(),
		"held=%s with assist disabled" % _grab.held_body_name())
	if _grab.is_holding():
		_press_action("interact")
		await _step(1)
	_grab.grab_assist_enabled = true
	_teleport(egg, off_axis)
	await _step(2)
	_press_action("interact")
	var assisted: int = await _wait_until(func() -> bool: return _grab.is_holding(), 5)
	_check("grab.assist_off_axis", assisted >= 0 and _grab.held_body_name() == egg.name,
		"held=%s expected=%s" % [_grab.held_body_name(), egg.name])
	_press_action("interact")
	await _step(2)
	_check("grab.assist_release", not _grab.is_holding(), "still holding after release")


## 8b. Neither the precise ray nor the assist may grab an item hidden behind
## world geometry: the egg lies on the floor behind the Pass counter and the
## player aims straight at it over the counter top.
func _check_grab_through_wall() -> void:
	var egg: FoodItem = _first_food()
	if not _check("grab.through_wall_setup", egg != null and not _grab.is_holding(),
			"no egg or already holding"):
		return
	var head: Node3D = _player.get_node("Head")
	var saved_player: Transform3D = _player.global_transform
	var saved_head: Vector3 = head.rotation
	# Pass box is x+-1, y 0..1, z 2.6..3.4; the egg sits just behind it.
	var hidden_pos: Vector3 = Vector3(0.0, 0.07, 3.55)
	_player.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0))
	_player.rotation = Vector3(0.0, PI, 0.0)
	_teleport(egg, hidden_pos)
	await _step(2)
	head.look_at(egg.global_position)
	await _step(1)
	_press_action("interact")
	await _step(3)
	_check("grab.through_wall_blocked", not _grab.is_holding(),
		"held=%s through the Pass counter" % _grab.held_body_name())
	if _grab.is_holding():
		_press_action("interact")
		await _step(1)
	_player.global_transform = saved_player
	head.rotation = saved_head
	await _step(2)


## 9. Holding crouch lowers the Head and shrinks the capsule (bottom fixed);
## releasing it under open ceiling stands back up.
func _check_crouch() -> void:
	var head: Node3D = _player.head
	var shape: CollisionShape3D = _player.collision_shape
	var standing_head_y: float = head.position.y
	var standing_height: float = (shape.shape as CapsuleShape3D).height
	var standing_bottom: float = shape.position.y - standing_height * 0.5
	_check("crouch.setup", not _player.is_crouched(), "already crouched")

	_set_action("crouch", true)
	await _step(30)
	_check("crouch.flag", _player.is_crouched(), "is_crouched() == false while held")
	_check("crouch.head_lowered", head.position.y < standing_head_y - 0.3,
		"head y %.3f -> %.3f" % [standing_head_y, head.position.y])
	var crouched_height: float = (shape.shape as CapsuleShape3D).height
	var crouched_bottom: float = shape.position.y - crouched_height * 0.5
	_check("crouch.capsule_shrunk", crouched_height < standing_height,
		"capsule height %.2f -> %.2f" % [standing_height, crouched_height])
	_check("crouch.capsule_bottom_fixed", is_equal_approx(crouched_bottom, standing_bottom),
		"capsule bottom %.3f -> %.3f" % [standing_bottom, crouched_bottom])

	_set_action("crouch", false)
	await _step(30)
	_check("crouch.stands_up", not _player.is_crouched(), "still crouched after release")
	_check("crouch.head_restored", head.position.y > standing_head_y - 0.05,
		"head y %.3f (standing %.3f)" % [head.position.y, standing_head_y])
	_check("crouch.capsule_restored",
		is_equal_approx((shape.shape as CapsuleShape3D).height, standing_height),
		"capsule height %.2f" % (shape.shape as CapsuleShape3D).height)


## 10. A plated COOKED egg set down on the pan on the stove must not re-cook:
## CookSlot still overlaps the egg but skips food a FoodContainer reports as
## contained, so cook_progress is frozen and the state stays COOKED.
func _check_plate_on_pan(pan: Pan) -> void:
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var egg: FoodItem = _first_food()
	if not _check("plate_on_pan.setup",
			plate != null and egg != null and pan.is_on_stove() and not _grab.is_holding(),
			"plate=%s egg=%s on_stove=%s held=%s" % [plate, egg, pan.is_on_stove(), _grab.held_body_name()]):
		return
	var cooked: bool = await _cook_until_cooked(egg, pan)
	if not _check("plate_on_pan.egg_cooked", cooked,
			"state=%s progress=%.2f" % [egg.state_name(), egg.cook_progress]):
		return
	# Park the egg on the Pass (no plate there any more), set the plate down on
	# the pan, then rest the egg on the plate.
	_teleport(egg, PASS_EGG_POS)
	await _step(5)
	_teleport(plate, PLATE_ON_PAN_POS)
	await _step(10)
	_teleport(egg, plate.global_position + EGG_ON_PLATE_OFFSET)
	await _step(15)
	var slot: CookSlot = pan.get_node("CookSlot") as CookSlot
	_check("plate_on_pan.plated", plate.get_contents().has(egg) and egg.is_contained(),
		"plate contents: %s; containers=%d" % [plate.container.contents_text(), egg.containers])
	_check("plate_on_pan.in_cook_slot", slot.has_food(egg),
		"egg %.2f m from pan axis, y=%.3f" % [_horizontal_distance(egg, pan), egg.global_position.y])
	# Stir as in the cook checks: the pan sits at a slight pitch, so without
	# re-centring the egg rolls off the plate (and out of both volumes) within
	# ~1 s, which would freeze progress for the wrong reason.
	# 260 frames is longer than burn_duration (240 ticks), so a re-cooking egg
	# would flip to BURNED and state_stays_cooked is real evidence, not vacuous.
	var before: float = egg.cook_progress
	for i in range(260):
		if i % STIR_INTERVAL == 0:
			if _horizontal_distance(plate, pan) > STIR_DRIFT:
				_teleport(plate, PLATE_ON_PAN_POS)
			if _horizontal_distance(egg, plate) > STIR_DRIFT:
				_teleport(egg, plate.global_position + EGG_ON_PLATE_OFFSET)
		await get_tree().physics_frame
	_check("plate_on_pan.progress_frozen", is_equal_approx(egg.cook_progress, before),
		"progress %.3f -> %.3f over 260 frames on the plate" % [before, egg.cook_progress])
	_check("plate_on_pan.state_stays_cooked", egg.state == FoodItem.State.COOKED,
		"state=%s" % egg.state_name())
	# Proves the freeze came from is_contained(), not from the egg escaping.
	_check("plate_on_pan.still_overlapping", slot.has_food(egg) and plate.get_contents().has(egg),
		"in_slot=%s plated=%s dist=%.2f" % [slot.has_food(egg), plate.get_contents().has(egg), _horizontal_distance(egg, pan)])
	# Lifting the egg off the plate hands it back to the stove: progress resumes.
	_teleport(plate, PASS_PLATE_POS)
	_teleport(egg, pan.global_position + EGG_IN_PAN_OFFSET)
	await _step(10)
	_check("plate_on_pan.released", not egg.is_contained(), "containers=%d" % egg.containers)
	var resumed_from: float = egg.cook_progress
	await _step(30)
	_check("plate_on_pan.progress_resumes", egg.cook_progress > resumed_from + 0.05,
		"progress %.3f -> %.3f after unplating" % [resumed_from, egg.cook_progress])


## 11. Carrying the pan: the egg left in the pan by check 10 should ride along
## inside the rim while the GrabController pulls the pan to the hold target.
## KNOWN BUG (expected failure): GrabController sets the pan's linear and
## angular velocity instantly (up to 20 m/s and 20 rad/s) the frame it is
## grabbed, so the disc and rim hit the resting egg like a bat and it is
## thrown out, whatever the grab distance. Probed 2026-09-11 with real
## physics: continuous_cd on the pan, velocity ramps (20-80 m/s^2) and
## speed caps down to 5 m/s / 4 rad/s all still lose the egg at one or
## more of 1.2 / 1.5 / 2.0 m. Needs a hands-on feel pass on the grab
## controller (see the plan's backlog); flip _xfail to _check once fixed.
func _check_carry(pan: Pan) -> void:
	var egg: FoodItem = _first_food()
	if not _check("carry.setup", egg != null and not _grab.is_holding() and pan.is_on_stove(),
			"egg=%s held=%s on_stove=%s" % [egg, _grab.held_body_name(), pan.is_on_stove()]):
		return
	var head: Node3D = _player.head
	var saved_player: Transform3D = _player.global_transform
	var saved_head: Vector3 = head.rotation
	_teleport(pan, STOVE_PAN_POS)
	_teleport(egg, pan.global_position + EGG_IN_PAN_OFFSET)
	# Stand 1.5 m in front of the stove, facing -Z, aiming at the pan.
	_player.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 1.5))
	await _step(20)
	head.look_at(pan.global_position)
	await _step(1)
	_press_action("interact")
	var held: int = await _wait_until(func() -> bool: return _grab.held_body_name() == pan.name, 5)
	if not _check("carry.holds_pan", held >= 0, "held=%s" % _grab.held_body_name()):
		_player.global_transform = saved_player
		head.rotation = saved_head
		return
	# With the hold point 1.2 m ahead the pan is still over the stove from
	# here; level the view and step back so it is carried off the heat.
	head.rotation = Vector3.ZERO
	_player.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.3))
	var lifted: int = await _wait_until(func() -> bool: return not pan.is_on_stove(), 30)
	_check("carry.pan_leaves_stove", lifted >= 0, "pan still reports on_stove while held")
	# Measured only once the stove detector has cleared: the last ticks before
	# that are legitimate heat. Vacuous if the egg was already thrown out (see
	# the expected failure below), so it guards the CookSlot rule, not the rim.
	var before: float = egg.cook_progress
	await _step(100)
	var slot: CookSlot = pan.get_node("CookSlot")
	_check("carry.no_cook_off_stove", not pan.is_on_stove() and is_equal_approx(egg.cook_progress, before),
		"on_stove=%s progress %.3f -> %.3f" % [pan.is_on_stove(), before, egg.cook_progress])
	_xfail("carry.pan_keeps_egg", _horizontal_distance(egg, pan) < PAN_RIM_DRIFT and slot.has_food(egg),
		"egg %.3f m off the pan axis, in_slot=%s, pan at %s" % [_horizontal_distance(egg, pan), slot.has_food(egg), pan.global_position])
	_press_action("interact")
	await _step(2)
	_check("carry.release", not _grab.is_holding(), "still holding the pan")
	_player.global_transform = saved_player
	head.rotation = saved_head
	# Park the pan back on the stove and the egg on the counter (off the heat).
	_teleport(pan, STOVE_PAN_POS)
	_teleport(egg, COUNTER_PAN_POS + Vector3(0.6, 0.1, 0.0))
	await _step(10)


## 12. A held item that gets farther than break_distance from the hold
## target is dropped automatically.
func _check_break_distance() -> void:
	var egg: FoodItem = _first_food()
	if not _check("grab.break_setup", egg != null and not _grab.is_holding(), "no egg or already holding"):
		return
	var forward: Vector3 = -_camera.global_transform.basis.z
	_teleport(egg, _camera.global_position + forward * 1.0)
	await _step(2)
	_press_action("interact")
	var grabbed: int = await _wait_until(func() -> bool: return _grab.is_holding(), 5)
	if not _check("grab.break_holds", grabbed >= 0, "not holding after interact"):
		return
	_teleport(egg, _grab.hold_target.global_position + Vector3(0.0, 0.0, _grab.break_distance + 1.0))
	await _step(2)
	_check("grab.break_distance_releases", not _grab.is_holding(),
		"still holding %s beyond break_distance" % _grab.held_body_name())
	_check("grab.break_released_group", not egg.is_in_group("held"), "egg still in 'held' group")
	if _grab.is_holding():
		_press_action("interact")
		await _step(1)


## 12b. The core interaction: standing at the stove with a level view, an
## egg released from the hold point must drop into the pan and start
## cooking. Guards the HoldTarget offset (0.15, -0.3, -1.2): the earlier
## (0.35, -0.35, -0.6) landed the egg on the stove top from every spot.
func _check_release_into_pan(pan: Pan) -> void:
	var egg: FoodItem = _first_food()
	if not _check("release.setup", egg != null and not _grab.is_holding() and pan.is_on_stove(),
			"egg=%s held=%s on_stove=%s" % [egg, _grab.held_body_name(), pan.is_on_stove()]):
		return
	var head: Node3D = _player.head
	var saved_player: Transform3D = _player.global_transform
	var saved_head: Vector3 = head.rotation
	_teleport(pan, STOVE_PAN_POS)
	# Pressed against the stove front (capsule radius 0.4, stove face z=0.75).
	_player.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 1.15))
	head.rotation = Vector3.ZERO
	await _step(20)
	_teleport(egg, _camera.global_position + Vector3(0.0, 0.0, -1.0))
	await _step(2)
	_press_action("interact")
	var held: int = await _wait_until(func() -> bool: return _grab.held_body_name() == egg.name, 5)
	if not _check("release.holds_egg", held >= 0, "held=%s" % _grab.held_body_name()):
		_player.global_transform = saved_player
		head.rotation = saved_head
		return
	await _step(40)
	_press_action("interact")
	var slot: CookSlot = pan.get_node("CookSlot")
	var landed: int = await _wait_until(func() -> bool: return slot.has_food(egg) and not _grab.is_holding(), 90)
	_check("release.egg_in_pan", landed >= 0,
		"egg rel=%s in_slot=%s" % [egg.global_position - pan.global_position, slot.has_food(egg)])
	var before: float = egg.cook_progress
	await _step(30)
	_check("release.cooking_resumes", egg.cook_progress > before,
		"progress %.3f -> %.3f after release into the pan" % [before, egg.cook_progress])
	_player.global_transform = saved_player
	head.rotation = saved_head
	_teleport(egg, COUNTER_PAN_POS + Vector3(0.6, 0.1, 0.0))
	await _step(10)


## 12c. A thrown egg must bounce off the room walls, not tunnel through
## them (continuous_cd on the egg): thrown at the north wall from 2.2 m.
func _check_throw_no_tunnel() -> void:
	var egg: FoodItem = _first_food()
	if not _check("throw.setup", egg != null and not _grab.is_holding(), "no egg or already holding"):
		return
	var head: Node3D = _player.head
	var saved_player: Transform3D = _player.global_transform
	var saved_head: Vector3 = head.rotation
	# North wall inner face is z = -5.9; stand 2.2 m from it facing -Z.
	_player.global_transform = Transform3D(Basis.IDENTITY, Vector3(1.5, 0.0, -3.7))
	head.rotation = Vector3.ZERO
	await _step(20)
	_teleport(egg, _camera.global_position + Vector3(0.0, 0.0, -1.0))
	await _step(2)
	_press_action("interact")
	var held: int = await _wait_until(func() -> bool: return _grab.held_body_name() == egg.name, 5)
	if not _check("throw.holds_egg", held >= 0, "held=%s" % _grab.held_body_name()):
		_player.global_transform = saved_player
		head.rotation = saved_head
		return
	await _step(10)
	_press_action("throw")
	var min_z: float = egg.global_position.z
	for i in range(90):
		await get_tree().physics_frame
		min_z = minf(min_z, egg.global_position.z)
	_check("throw.no_tunnel", min_z > -5.9 and egg.global_position.y > -0.5,
		"egg min z=%.3f final=%s" % [min_z, egg.global_position])
	_player.global_transform = saved_player
	head.rotation = saved_head
	_teleport(egg, COUNTER_PAN_POS + Vector3(0.6, 0.1, 0.0))
	await _step(10)


## 13. Standing up is refused while a world body blocks the standing capsule,
## allowed once it is gone, and never blocked by a body in the "held" group.
func _check_crouch_blocked() -> void:
	if not _check("crouch.blocked_setup", not _player.is_crouched() and _player.is_on_floor(),
			"crouched=%s on_floor=%s" % [_player.is_crouched(), _player.is_on_floor()]):
		return
	_set_action("crouch", true)
	await _step(30)
	# A "ceiling" slab 1.5..1.7 m above the player's feet: above the crouched
	# capsule (top 1.3 m) but inside the standing one (top 2.0 m).
	var ceiling := StaticBody3D.new()
	var ceiling_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 0.2, 1.0)
	ceiling_shape.shape = box
	ceiling.add_child(ceiling_shape)
	_kitchen.add_child(ceiling)
	ceiling.global_position = _player.global_position + Vector3(0.0, 1.6, 0.0)
	await _step(2)
	_set_action("crouch", false)
	await _step(10)
	_check("crouch.blocked_by_ceiling", _player.is_crouched(), "stood up into the ceiling slab")
	ceiling.queue_free()
	await _step(30)
	_check("crouch.stands_after_clear", not _player.is_crouched(), "still crouched after the slab was removed")

	_set_action("crouch", true)
	await _step(30)
	var carried := RigidBody3D.new()
	carried.freeze = true
	carried.collision_layer = 4
	carried.collision_mask = 0
	var carried_shape := CollisionShape3D.new()
	carried_shape.shape = box.duplicate()
	carried.add_child(carried_shape)
	carried.add_to_group("held")
	_kitchen.add_child(carried)
	carried.global_position = _player.global_position + Vector3(0.0, 1.6, 0.0)
	await _step(2)
	_set_action("crouch", false)
	await _step(10)
	_check("crouch.held_item_not_blocking", not _player.is_crouched(), "a held body pinned the player crouched")
	carried.queue_free()
	_set_action("crouch", false)
	await _step(30)


## 14. A cooked egg that is being held while resting on a plate in the zone
## must not be delivered out of the player's hand; releasing it delivers.
## The delivery goal is raised first so this and check 15 never reach the
## WON state, which pauses the tree.
func _check_held_egg(pan: Pan) -> void:
	_loop.delivery_goal = 10
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var egg: FoodItem = _first_food()
	if not _check("held_egg.setup", plate != null and egg != null and not _grab.is_holding()
			and egg.state == FoodItem.State.COOKED,
			"plate=%s egg=%s state=%s" % [plate, egg, egg.state_name() if egg else "-"]):
		return
	_teleport(plate, PASS_PLATE_POS)
	await _step(10)
	_teleport(egg, PASS_EGG_POS)
	egg.add_to_group("held")
	var before: int = _delivered_count
	await _step(30)
	_check("held_egg.blocked", _delivered_count == before and is_instance_valid(plate),
		"delivered fired %d time(s) while the egg was held" % (_delivered_count - before))
	egg.remove_from_group("held")
	var fired: int = await _wait_until(func() -> bool: return _delivered_count > before, 30)
	_check("held_egg.delivers_after_release", fired >= 0, "no delivery after releasing the egg")
	await _step(5)
	_check("held_egg.count", _loop.deliveries_made == 3, "deliveries_made=%d" % _loop.deliveries_made)
	await _step(5)


## 15. Respawn is gated per spawner: a delivery while a fresh egg still sits
## in the egg slot must not stack a second egg onto it.
func _check_occupied_slot(pan: Pan) -> void:
	await _step(10)
	var slot_egg: FoodItem = _first_food()
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	if not _check("occupied.setup", slot_egg != null and plate != null and not _egg_spawner.is_slot_free(),
			"egg=%s plate=%s slot_free=%s" % [slot_egg, plate, _egg_spawner.is_slot_free()]):
		return
	var extra: FoodItem = _egg_spawner.item_scene.instantiate() as FoodItem
	_kitchen.add_child(extra)
	extra.global_position = STOVE_PAN_POS + EGG_IN_PAN_OFFSET
	await _step(2)
	var cooked: bool = await _cook_until_cooked(extra, pan)
	_check("occupied.extra_cooked", cooked, "extra egg state=%s" % extra.state_name())
	_teleport(plate, PASS_PLATE_POS)
	await _step(10)
	_teleport(extra, PASS_EGG_POS)
	var before: int = _delivered_count
	var fired: int = await _wait_until(func() -> bool: return _delivered_count > before, 60)
	_check("occupied.delivered", fired >= 0, "extra egg on the plate was not delivered")
	await _step(10)
	_check("occupied.no_extra_egg", get_tree().get_nodes_in_group("food").size() == 1 and is_instance_valid(slot_egg),
		"%d eggs in the world (slot egg valid=%s)" % [get_tree().get_nodes_in_group("food").size(), is_instance_valid(slot_egg)])
	_check("occupied.slot_still_full", not _egg_spawner.is_slot_free(), "egg slot reported free")
	_check("occupied.plate_respawned", get_tree().get_nodes_in_group("plate").size() == 1 and _plate_spawner.is_slot_free() == false,
		"%d plates, plate slot free=%s" % [get_tree().get_nodes_in_group("plate").size(), _plate_spawner.is_slot_free()])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _check(check_name: String, ok: bool, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("PASS %s" % check_name)
	else:
		_failed += 1
		print("FAIL %s: %s" % [check_name, detail])
	return ok


## Expected failure: counted separately and never fails the run. Use for
## checks that document a known gameplay bug (see tests/README.md).
func _xfail(check_name: String, ok: bool, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("PASS %s (expected failure now passes)" % check_name)
	else:
		_xfailed += 1
		print("XFAIL %s: %s" % [check_name, detail])
	return ok


func _step(frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame


## Steps physics until pred() is true. Returns the number of frames waited,
## or -1 if max_frames elapsed first.
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


## Steps physics until pred() is true while "stirring": every STIR_INTERVAL
## frames the egg is re-centred in the pan if it has drifted, so the tilted
## pan (see cook.egg_stays_in_pan) cannot roll it out of the CookSlot.
## Returns frames waited, or -1 if max_frames elapsed first.
func _cook_until(egg: FoodItem, pan: Pan, pred: Callable, max_frames: int) -> int:
	for i in range(max_frames):
		if pred.call():
			return i
		if i % STIR_INTERVAL == 0 and _horizontal_distance(egg, pan) > STIR_DRIFT:
			_teleport(egg, pan.global_position + EGG_IN_PAN_OFFSET)
		await get_tree().physics_frame
	if pred.call():
		return max_frames
	return -1


## Drops egg into the pan (assumed on the stove) and stirs until COOKED.
func _cook_until_cooked(egg: FoodItem, pan: Pan) -> bool:
	_teleport(egg, pan.global_position + EGG_IN_PAN_OFFSET)
	var budget: int = int(egg.cook_duration * PHYSICS_TPS * 1.5) + 10
	var frames: int = await _cook_until(egg, pan,
		func() -> bool: return egg.state == FoodItem.State.COOKED, budget)
	return frames >= 0


func _horizontal_distance(a: Node3D, b: Node3D) -> float:
	var d: Vector3 = a.global_position - b.global_position
	return Vector2(d.x, d.z).length()


func _first_food() -> FoodItem:
	return get_tree().get_first_node_in_group("food") as FoodItem


## Adds the autoloads by name if they are not on root (they always are in a
## --script run; this keeps the body usable from other entry points).
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


## Simulates a press of an InputMap action the same way a key press reaches
## the game: through the Input singleton, which routes it to the root
## Viewport and on to every _unhandled_input.
func _press_action(action: String) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	var release := InputEventAction.new()
	release.action = action
	release.pressed = false
	Input.parse_input_event(release)


## Holds or releases an InputMap action (for actions polled with
## Input.is_action_pressed, such as "crouch").
func _set_action(action: String, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)
