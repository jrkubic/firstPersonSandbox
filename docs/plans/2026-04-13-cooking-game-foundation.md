# Cooking Game Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a solo vertical slice of a PEAK-style first-person cooking game where the player picks up a raw egg, cooks it on a pan over a stove, plates it, and delivers it to a pass — in a grey-box kitchen — with physics-grabbed held items.

**Architecture:** First-person `CharacterBody3D` player with a `GrabController` on the camera that creates a `Generic6DOFJoint3D` between the player and grabbed rigidbodies, pulling them toward a `HoldTarget` offset in the bottom-right of the screen. Cookable food owns its own state machine; a pan's `CookSlot` ticks food cooking only while the pan's `StoveDetector` reports overlap with the stove. A plate's `FoodContainer` tracks food resting on it via physics, and a `DeliveryZone` on the pass queries the plate against a static `OrderSystem` order.

**Tech Stack:** Godot 4.6 (Forward+ renderer), Jolt Physics, GDScript. No addons.

**Testing approach:** No automated tests for this slice (design decision — physics-heavy, no gameplay worth regression-testing yet). Each task has a **Manual verification** step: what to open, what to press, what to look for. A debug overlay (toggled with F3) is added in Task 3 and used from then on.

**Design doc:** [2026-04-13-cooking-game-foundation-design.md](2026-04-13-cooking-game-foundation-design.md)

---

## Conventions

- **GDScript style:** static typing everywhere (`var x: int = 0`, `func foo(bar: Node3D) -> void`). Tabs for indent (Godot default). `snake_case` for files and variables, `PascalCase` for node names and classes.
- **Groups:** `"grabbable"` — any rigidbody the player can pick up. `"food"` — any `FoodItem`. `"plate"` — any `FoodContainer`. `"stove"` — the stove static body.
- **Physics layers:** Layer 1 = world (default), Layer 2 = player. The player body is on layer 2 and masks 1+2; world items mask 1. This keeps the grab raycast and camera from self-colliding.
- **File layout:**
  - `scenes/kitchen.tscn` — the gameplay scene (replaces `world.tscn`)
  - `scenes/items/` — `egg.tscn`, `pan.tscn`, `plate.tscn`
  - `scripts/items/` — `food_item.gd`, `pan.gd`, `plate.gd`
  - `scripts/systems/` — `grab_controller.gd`, `cook_slot.gd`, `stove_detector.gd`, `food_container.gd`, `delivery_zone.gd`, `order_system.gd`, `egg_spawner.gd`, `plate_spawner.gd`
  - `scripts/ui/` — `debug_overlay.gd`

---

## Task 1: Input actions + scene rename

**Files:**
- Modify: `project.godot` — add `interact` and `throw` actions
- Create: `scenes/kitchen.tscn` — new empty 3D scene (will be built up through the plan)
- Modify: `scripts/menu.gd:3` — change `game_scene` default to `res://scenes/kitchen.tscn`
- Delete: `scenes/world.tscn` (only after kitchen.tscn exists and loads)

**Step 1: Add input actions in project.godot**

Edit `project.godot`. Under the `[input]` section, after `jump`, add:

```ini
interact={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":0,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":69,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
throw={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":0,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":70,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
debug_overlay={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":0,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":4194334,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
```

Key codes: `69`=E (interact), `70`=F (throw), `4194334`=F3 (debug_overlay).

**Step 2: Create kitchen.tscn as a stub**

In Godot editor: `Scene → New Scene → 3D Scene`. Rename root to `Kitchen`. Save as `res://scenes/kitchen.tscn`. This is a stub — we'll populate it in Task 2.

**Step 3: Point menu at kitchen.tscn**

Edit `scripts/menu.gd`:

```gdscript
@export_file("*.tscn") var game_scene: String = "res://scenes/kitchen.tscn"
```

**Step 4: Manual verification**

1. Open the project in Godot 4.6.
2. `Project → Project Settings → Input Map` and confirm `interact`, `throw`, `debug_overlay` all appear with E / F / F3 bindings.
3. Press F5. The menu appears. Click Start Game. An empty 3D scene loads without errors (black viewport is fine for now).
4. Godot's output panel should show no errors.

**Step 5: Delete world.tscn**

Only after Step 4 passes. Delete `scenes/world.tscn` from the filesystem.

**Step 6: Commit**

```bash
git add project.godot scenes/kitchen.tscn scripts/menu.gd
git rm scenes/world.tscn
git commit -m "Add cooking-game inputs, swap world.tscn for kitchen.tscn stub"
```

---

## Task 2: Kitchen room, player, lighting

**Files:**
- Modify: `scenes/kitchen.tscn`

**Step 1: Build the sealed room**

In `scenes/kitchen.tscn`, add these children to the `Kitchen` root node:

1. **WorldEnvironment** — create a new `Environment` resource. Set `background_mode = Sky`, create a `ProceduralSkyMaterial`. Set `tonemap_mode = Filmic`. Set `ambient_light_source = Sky`.
2. **DirectionalLight3D** — rotate ~45° pitch, ~−30° yaw. Enable `shadow_enabled`.
3. **Room** (`StaticBody3D`) — add 6 child `MeshInstance3D`s with `BoxMesh` and matching `CollisionShape3D`s with `BoxShape3D`, forming a sealed 12×6×12 box:
   - Floor: size `(12, 0.2, 12)`, position `(0, -0.1, 0)`
   - Ceiling: size `(12, 0.2, 12)`, position `(0, 6, 0)`
   - Wall N: size `(12, 6, 0.2)`, position `(0, 3, -6)`
   - Wall S: size `(12, 6, 0.2)`, position `(0, 3, 6)`
   - Wall E: size `(0.2, 6, 12)`, position `(6, 3, 0)`
   - Wall W: size `(0.2, 6, 12)`, position `(-6, 3, 0)`
   - Floor material: light grey `(0.7, 0.7, 0.7)`. Walls: slightly cooler grey `(0.6, 0.6, 0.65)`.
4. **Player** — instance `res://scenes/player.tscn` at position `(0, 0.1, 4)` facing `-Z`.

**Step 2: Manual verification**

Press F5, Start Game. You should:
- Land inside a fully enclosed grey box room.
- Be able to walk (WASD) without falling through the floor.
- Look around with the mouse.
- Jump with space.
- See directional light + shadows.
- Press Escape → mouse releases.

**Step 3: Commit**

```bash
git add scenes/kitchen.tscn
git commit -m "Build sealed grey-box kitchen room with player and lighting"
```

---

## Task 3: Debug overlay (used from here on)

**Files:**
- Create: `scripts/ui/debug_overlay.gd`
- Create: `scenes/ui/debug_overlay.tscn`
- Modify: `scenes/kitchen.tscn` — add overlay instance

**Step 1: Write debug_overlay.gd**

```gdscript
extends CanvasLayer

@onready var label: Label = $Label

var _watched: Dictionary = {}


func _ready() -> void:
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_overlay"):
		visible = not visible


func _process(_delta: float) -> void:
	if not visible:
		return
	var lines: Array[String] = []
	for key in _watched.keys():
		var getter: Callable = _watched[key]
		var value: Variant = getter.call() if getter.is_valid() else "<invalid>"
		lines.append("%s: %s" % [key, value])
	label.text = "\n".join(lines)


func watch(key: String, getter: Callable) -> void:
	_watched[key] = getter


func unwatch(key: String) -> void:
	_watched.erase(key)
```

**Step 2: Build debug_overlay.tscn**

Scene root: `CanvasLayer` with script `res://scripts/ui/debug_overlay.gd`. Child: `Label` named `Label` with:
- `anchor_left = 0.01`, `anchor_top = 0.01`
- `theme_override_font_sizes/font_size = 20`
- `theme_override_colors/font_color = Color(1, 1, 0)`
- Starting text: `(debug)`

Save as `res://scenes/ui/debug_overlay.tscn`.

**Step 3: Instance the overlay in kitchen.tscn**

Add `debug_overlay.tscn` as a child of `Kitchen`. Name it `DebugOverlay`.

**Step 4: Manual verification**

F5 → Start Game → press F3. A yellow `(debug)` text appears in the top-left. Press F3 again → it disappears. Press Escape to release mouse, F3 to toggle — both should work without conflict.

**Step 5: Commit**

```bash
git add scripts/ui/debug_overlay.gd scenes/ui/debug_overlay.tscn scenes/kitchen.tscn
git commit -m "Add F3 debug overlay with watched-value API"
```

---

## Task 4: GrabController — raycast + hold joint

**Files:**
- Create: `scripts/systems/grab_controller.gd`
- Modify: `scenes/player.tscn` — add HoldTarget and GrabController children of Camera3D
- Modify: `scenes/kitchen.tscn` — add a temporary test cube in the `grabbable` group

**Step 1: Write grab_controller.gd**

```gdscript
class_name GrabController
extends Node3D

@export var grab_range: float = 2.0
@export var break_distance: float = 1.5
@export var throw_impulse: float = 8.0
@export var hold_linear_stiffness: float = 2000.0
@export var hold_linear_damping: float = 80.0
@export var hold_angular_stiffness: float = 200.0
@export var hold_angular_damping: float = 20.0

@export_node_path("Node3D") var hold_target_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath

var _held_body: RigidBody3D = null
var _joint: Generic6DOFJoint3D = null

@onready var hold_target: Node3D = get_node(hold_target_path)
@onready var camera: Camera3D = get_node(camera_path)


func is_holding() -> bool:
	return _held_body != null


func held_body_name() -> String:
	return _held_body.name if _held_body else "<none>"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		if is_holding():
			_release()
		else:
			_try_grab()
	elif event.is_action_pressed("throw") and is_holding():
		_throw()


func _physics_process(_delta: float) -> void:
	if not is_holding():
		return
	var distance: float = _held_body.global_position.distance_to(hold_target.global_position)
	if distance > break_distance:
		_release()


func _try_grab() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var to: Vector3 = from + (-camera.global_transform.basis.z) * grab_range
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return
	var body: Node = hit.get("collider")
	if not body is RigidBody3D:
		return
	if not body.is_in_group("grabbable"):
		return
	_attach(body)


func _attach(body: RigidBody3D) -> void:
	_held_body = body
	body.freeze = false
	# Teleport the body to the hold target to avoid an explosive joint yank.
	body.global_position = hold_target.global_position
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO

	_joint = Generic6DOFJoint3D.new()
	add_child(_joint)
	_joint.global_transform = hold_target.global_transform
	_joint.node_a = hold_target.get_path()
	_joint.node_b = body.get_path()
	# Soft linear pull on all axes.
	for axis in [Vector3.AXIS_X, Vector3.AXIS_Y, Vector3.AXIS_Z]:
		_joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_SPRING, true) if axis == Vector3.AXIS_X else null
	_joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_SPRING, true)
	_joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_SPRING, true)
	_joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_SPRING, true)
	_joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_STIFFNESS, hold_linear_stiffness)
	_joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_STIFFNESS, hold_linear_stiffness)
	_joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_STIFFNESS, hold_linear_stiffness)
	_joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_DAMPING, hold_linear_damping)
	_joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_DAMPING, hold_linear_damping)
	_joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_DAMPING, hold_linear_damping)
	_joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
	_joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
	_joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
	_joint.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, hold_angular_stiffness)
	_joint.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, hold_angular_stiffness)
	_joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, hold_angular_stiffness)
	_joint.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, hold_angular_damping)
	_joint.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, hold_angular_damping)
	_joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, hold_angular_damping)


func _release() -> void:
	if _joint:
		_joint.queue_free()
		_joint = null
	_held_body = null


func _throw() -> void:
	var body: RigidBody3D = _held_body
	var forward: Vector3 = -camera.global_transform.basis.z
	_release()
	if body:
		body.apply_central_impulse(forward * throw_impulse)
```

**Note on the API:** Godot 4.6's `Generic6DOFJoint3D` uses `set_flag_x/y/z` and `set_param_x/y/z` as separate calls per axis. If a method signature is wrong at runtime, check the Godot 4.6 docs for `Generic6DOFJoint3D` and adjust — the intent is: enable linear spring + angular spring on all 3 axes, set stiffness/damping to the exported values.

**Step 2: Add HoldTarget and GrabController to player.tscn**

In `scenes/player.tscn`, under `Head → Camera3D`, add:

1. `HoldTarget` (Node3D) — position `(0.35, -0.35, -0.6)` in camera-local space (this is the bottom-right anchor).
2. `GrabController` (Node3D) — attach script `res://scripts/systems/grab_controller.gd`. Set exports:
   - `hold_target_path` → `../HoldTarget`
   - `camera_path` → `..` (the Camera3D)

**Step 3: Add a test cube to kitchen.tscn**

Temporarily add a `RigidBody3D` to `Kitchen` named `TestCube` at position `(0, 1, 0)`:
- `CollisionShape3D` with `BoxShape3D` size `(0.4, 0.4, 0.4)`
- `MeshInstance3D` with `BoxMesh` size `(0.4, 0.4, 0.4)`, red albedo
- Add node to group `grabbable` (in the Node tab → Groups → add "grabbable")

**Step 4: Wire the debug overlay to watch grab state**

In `scripts/player.gd`, add at the bottom of `_ready()`:

```gdscript
	var overlay: Node = get_tree().get_first_node_in_group("debug_overlay")
	if overlay:
		var grab: GrabController = $Head/Camera3D/GrabController
		overlay.watch("held", Callable(grab, "held_body_name"))
```

And in `scripts/ui/debug_overlay.gd:_ready()`, add:

```gdscript
	add_to_group("debug_overlay")
```

**Step 5: Manual verification**

F5 → Start Game. Walk up to the red cube, look at it, press E. The cube should snap to the bottom-right of your screen and hover there. Walk around — it sways slightly but stays near the hold point. Press E again → it falls. Press E while looking at it, then F → it launches forward. Toggle F3 overlay → confirm `held: TestCube` while holding, `held: <none>` otherwise.

**If the joint explodes, yanks the camera, or throws the cube across the map on grab:** stiffness is too high. Drop `hold_linear_stiffness` to 800 and `hold_angular_stiffness` to 80, retest.

**If the cube just drops on grab:** the group filter is wrong — confirm `TestCube` is in the `grabbable` group (Node tab → Groups in the editor, not a script call).

**Step 6: Commit**

```bash
git add scripts/systems/grab_controller.gd scenes/player.tscn scenes/kitchen.tscn scripts/player.gd scripts/ui/debug_overlay.gd
git commit -m "Add GrabController with 6DOF joint hold at bottom-right offset"
```

---

## Task 5: Egg (FoodItem) — raw for now

**Files:**
- Create: `scripts/items/food_item.gd`
- Create: `scenes/items/egg.tscn`
- Modify: `scenes/kitchen.tscn` — swap test cube for an egg

**Step 1: Write food_item.gd**

```gdscript
class_name FoodItem
extends RigidBody3D

enum State { RAW, COOKING, COOKED, BURNED }

@export var recipe_tag: String = "egg"
@export var cook_duration: float = 1.5  # seconds from RAW to COOKED
@export var burn_duration: float = 1.5  # seconds from COOKED to BURNED

@export var raw_color: Color = Color(1.0, 1.0, 0.95)
@export var cooked_color: Color = Color(0.95, 0.75, 0.25)
@export var burned_color: Color = Color(0.1, 0.1, 0.1)

signal state_changed(new_state: State)

var state: State = State.RAW
var cook_progress: float = 0.0  # 0..1 is cook phase, 1..2 is burn phase

@onready var mesh: MeshInstance3D = $MeshInstance3D
var _material: StandardMaterial3D


func _ready() -> void:
	add_to_group("grabbable")
	add_to_group("food")
	_material = mesh.mesh.surface_get_material(0)
	if _material == null:
		_material = StandardMaterial3D.new()
		mesh.set_surface_override_material(0, _material)
	_update_color()


func tick_cook(delta: float) -> void:
	if state == State.BURNED:
		return
	var rate: float = 1.0 / cook_duration if cook_progress < 1.0 else 1.0 / burn_duration
	cook_progress += rate * delta
	var new_state: State = state
	if cook_progress >= 2.0:
		cook_progress = 2.0
		new_state = State.BURNED
	elif cook_progress >= 1.0:
		new_state = State.COOKED
	else:
		new_state = State.COOKING
	if new_state != state:
		state = new_state
		state_changed.emit(state)
	_update_color()


func state_name() -> String:
	return State.keys()[state]


func _update_color() -> void:
	if _material == null:
		return
	var c: Color
	if cook_progress <= 1.0:
		c = raw_color.lerp(cooked_color, cook_progress)
	else:
		c = cooked_color.lerp(burned_color, cook_progress - 1.0)
	_material.albedo_color = c
```

**Step 2: Build egg.tscn**

Scene root: `RigidBody3D` named `Egg`, script `food_item.gd`.
- `mass = 0.1`
- `CollisionShape3D` with `SphereShape3D` radius `0.07`
- `MeshInstance3D` with `SphereMesh` radius `0.07`, height `0.14`, with a new `StandardMaterial3D` as its material.

Save as `res://scenes/items/egg.tscn`.

**Step 3: Replace the test cube in kitchen.tscn**

Remove `TestCube` from `Kitchen`. Instance `res://scenes/items/egg.tscn` as a child of `Kitchen` at position `(0, 1.2, 0)`. Name it `Egg`.

**Step 4: Wire overlay**

In `scripts/player.gd:_ready()`, after the existing `watch("held", ...)`:

```gdscript
	var egg: FoodItem = get_tree().get_first_node_in_group("food") as FoodItem
	if egg and overlay:
		overlay.watch("egg.state", Callable(egg, "state_name"))
		overlay.watch("egg.progress", func() -> String: return "%.2f" % egg.cook_progress)
```

**Step 5: Manual verification**

F5 → Start Game → F3. You see `egg.state: RAW`, `egg.progress: 0.00`. Walk to the egg, press E → it hovers bottom-right. Walk around, press E again → it drops. Press F → it launches.

**Step 6: Commit**

```bash
git add scripts/items/food_item.gd scenes/items/egg.tscn scenes/kitchen.tscn scripts/player.gd
git commit -m "Add FoodItem with RAW/COOKING/COOKED/BURNED states and egg scene"
```

---

## Task 6: Counter, Stove, PlateRack, Pass, OrderBoard (static shells)

**Files:**
- Modify: `scenes/kitchen.tscn`

Purely scene work — all static bodies and meshes.

**Step 1: Place the four shells**

Add as children of `Kitchen`:

1. **Counter** (`StaticBody3D`) at `(-2.5, 0, 0)`:
   - `MeshInstance3D` + `CollisionShape3D`, `BoxShape3D`/`BoxMesh` size `(1.5, 1.0, 1.5)`, centered at `(0, 0.5, 0)` in local space.
   - Albedo: warm grey `(0.5, 0.45, 0.4)`.

2. **Stove** (`StaticBody3D`) at `(0, 0, 0)`, add to group `"stove"`:
   - `BoxShape3D`/`BoxMesh` size `(1.5, 1.0, 1.5)`, local `(0, 0.5, 0)`.
   - Albedo: dark grey `(0.25, 0.25, 0.28)`.

3. **PlateRack** (`StaticBody3D`) at `(2.5, 0, 0)`:
   - `BoxShape3D`/`BoxMesh` size `(1.0, 1.0, 1.0)`, local `(0, 0.5, 0)`.
   - Albedo: cool grey `(0.5, 0.55, 0.6)`.

4. **Pass** (`StaticBody3D`) at `(0, 0, 3)`:
   - `BoxShape3D`/`BoxMesh` size `(2.0, 1.0, 0.8)`, local `(0, 0.5, 0)`.
   - Albedo: light warm `(0.7, 0.6, 0.45)`.

5. **OrderBoard** (`StaticBody3D`) at `(0, 2.5, -5.8)`:
   - `BoxShape3D`/`BoxMesh` size `(2.0, 1.2, 0.1)`.
   - Child `Label3D` named `TicketLabel` at `(0, 0, 0.06)` — text `"1× Fried Egg"`, `pixel_size = 0.01`, `font_size = 64`, `horizontal_alignment = Center`, `vertical_alignment = Center`, `modulate = Color(1, 1, 1)`.

**Step 2: Move egg spawn onto counter**

Move the existing `Egg` instance to `(-2.5, 1.2, 0)` — sitting on the counter.

**Step 3: Manual verification**

F5 → Start Game. The kitchen now has four distinguishable shapes visible. The egg sits on the counter. You can grab it (E), walk it around the kitchen, and release it (E) — it falls onto whatever you're standing near. The `1× Fried Egg` text is readable on the wall.

**Step 4: Commit**

```bash
git add scenes/kitchen.tscn
git commit -m "Add grey-box counter, stove, plate rack, pass and order board"
```

---

## Task 7: Pan scene + StoveDetector

**Files:**
- Create: `scripts/items/pan.gd`
- Create: `scripts/systems/stove_detector.gd`
- Create: `scenes/items/pan.tscn`
- Modify: `scenes/kitchen.tscn` — instance pan on stove

**Step 1: Write stove_detector.gd**

```gdscript
class_name StoveDetector
extends Area3D

var _overlapping_stoves: int = 0


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func is_on_stove() -> bool:
	return _overlapping_stoves > 0


func _on_body_entered(body: Node) -> void:
	if body.is_in_group("stove"):
		_overlapping_stoves += 1


func _on_body_exited(body: Node) -> void:
	if body.is_in_group("stove"):
		_overlapping_stoves = max(0, _overlapping_stoves - 1)
```

**Step 2: Write pan.gd**

```gdscript
class_name Pan
extends RigidBody3D

@onready var stove_detector: StoveDetector = $StoveDetector


func _ready() -> void:
	add_to_group("grabbable")
	add_to_group("pan")


func is_on_stove() -> bool:
	return stove_detector.is_on_stove()


func on_stove_text() -> String:
	return "true" if is_on_stove() else "false"
```

**Step 3: Build pan.tscn**

Scene root: `Pan` (`RigidBody3D`, script `pan.gd`).
- `mass = 0.8`
- `CollisionShape3D` — `CylinderShape3D` radius `0.25`, height `0.08`
- `MeshInstance3D` — `CylinderMesh` top/bottom radius `0.25`, height `0.08`, dark grey `(0.15, 0.15, 0.15)`

Child nodes:
- **StoveDetector** (`Area3D`, script `stove_detector.gd`):
  - child `CollisionShape3D` with `BoxShape3D` size `(0.45, 0.1, 0.45)`, position `(0, -0.1, 0)` — a thin disc just below the pan so contact with the stove surface registers as overlap.

Save as `res://scenes/items/pan.tscn`.

**Step 4: Instance pan on the stove**

In `kitchen.tscn`, add `res://scenes/items/pan.tscn` as a child of `Kitchen` at `(0, 1.05, 0)` (just above the stove's top surface). Name it `Pan`.

**Step 5: Wire overlay**

In `scripts/player.gd:_ready()`:

```gdscript
	var pan: Pan = get_tree().get_first_node_in_group("pan") as Pan
	if pan and overlay:
		overlay.watch("pan.on_stove", Callable(pan, "on_stove_text"))
```

**Step 6: Manual verification**

F5 → F3. `pan.on_stove: true` on scene start (pan sitting on stove). Grab the pan (E) and walk away → `pan.on_stove: false`. Return and drop it on the stove → `true` again. Drop it on the floor → `false`.

**Step 7: Commit**

```bash
git add scripts/items/pan.gd scripts/systems/stove_detector.gd scenes/items/pan.tscn scenes/kitchen.tscn scripts/player.gd
git commit -m "Add Pan rigidbody with StoveDetector Area3D"
```

---

## Task 8: CookSlot — pan cooks food on stove

**Files:**
- Create: `scripts/systems/cook_slot.gd`
- Modify: `scenes/items/pan.tscn` — add CookSlot child

**Step 1: Write cook_slot.gd**

```gdscript
class_name CookSlot
extends Area3D

@export_node_path("Pan") var pan_path: NodePath

var _foods: Array[FoodItem] = []
@onready var _pan: Pan = get_node(pan_path)


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(delta: float) -> void:
	if _foods.is_empty():
		return
	if not _pan.is_on_stove():
		return
	for food in _foods:
		food.tick_cook(delta)


func _on_body_entered(body: Node) -> void:
	if body is FoodItem:
		_foods.append(body)


func _on_body_exited(body: Node) -> void:
	if body is FoodItem:
		_foods.erase(body)
```

**Step 2: Add CookSlot to pan.tscn**

In `scenes/items/pan.tscn`, add a child `Area3D` to `Pan` named `CookSlot` with script `cook_slot.gd`.
- Child `CollisionShape3D` with `BoxShape3D` size `(0.4, 0.15, 0.4)`, position `(0, 0.08, 0)` — a thin volume sitting just above the pan's interior.
- Set `CookSlot.pan_path` export to `..` (the Pan).

**Step 3: Manual verification**

F5 → F3. Grab the egg, walk to the stove, release it over the pan. The egg should drop into the pan. Watch the overlay:
- `egg.state: RAW → COOKING → COOKED` over ~1.5s
- `egg.progress: 0.00 → 1.00`
- Egg albedo lerps white → golden
- Continuing to wait: `COOKED → BURNED` over another ~1.5s, albedo → black

Grab the pan mid-cook, walk away → `pan.on_stove: false`, `egg.progress` freezes. Drop pan back on stove → resumes. Grab just the egg out of the pan → state stays whatever it was.

**Step 4: Commit**

```bash
git add scripts/systems/cook_slot.gd scenes/items/pan.tscn
git commit -m "Add CookSlot that ticks food only while pan is on stove"
```

---

## Task 9: Plate + FoodContainer

**Files:**
- Create: `scripts/items/plate.gd`
- Create: `scripts/systems/food_container.gd`
- Create: `scenes/items/plate.tscn`
- Modify: `scenes/kitchen.tscn` — instance plate on rack

**Step 1: Write food_container.gd**

```gdscript
class_name FoodContainer
extends Area3D

var _foods: Array[FoodItem] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func get_contents() -> Array[FoodItem]:
	return _foods.duplicate()


func contents_text() -> String:
	if _foods.is_empty():
		return "empty"
	var parts: Array[String] = []
	for f in _foods:
		parts.append("%s(%s)" % [f.recipe_tag, f.state_name()])
	return ", ".join(parts)


func _on_body_entered(body: Node) -> void:
	if body is FoodItem and not _foods.has(body):
		_foods.append(body)


func _on_body_exited(body: Node) -> void:
	if body is FoodItem:
		_foods.erase(body)
```

**Step 2: Write plate.gd**

```gdscript
class_name Plate
extends RigidBody3D

@onready var container: FoodContainer = $FoodContainer


func _ready() -> void:
	add_to_group("grabbable")
	add_to_group("plate")


func get_contents() -> Array[FoodItem]:
	return container.get_contents()
```

**Step 3: Build plate.tscn**

Scene root: `Plate` (`RigidBody3D`, script `plate.gd`).
- `mass = 0.3`
- `CollisionShape3D` — `CylinderShape3D` radius `0.22`, height `0.03`
- `MeshInstance3D` — `CylinderMesh` top/bottom radius `0.22`, height `0.03`, white `(0.95, 0.95, 0.95)`

Child:
- `FoodContainer` (`Area3D`, script `food_container.gd`) with `CollisionShape3D` `BoxShape3D` size `(0.4, 0.15, 0.4)`, position `(0, 0.09, 0)` — sits just above the plate's top surface.

Save as `res://scenes/items/plate.tscn`.

**Step 4: Instance plate on rack**

In `kitchen.tscn`, add `res://scenes/items/plate.tscn` as child of `Kitchen` at `(2.5, 1.05, 0)`. Name it `Plate`.

**Step 5: Wire overlay**

In `scripts/player.gd:_ready()`:

```gdscript
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	if plate and overlay:
		overlay.watch("plate.contents", Callable(plate.container, "contents_text"))
```

**Step 6: Manual verification**

F5 → F3. `plate.contents: empty`. Cook an egg (Task 8 flow), grab the pan, walk to plate, tip the pan — the egg slides out onto the plate. `plate.contents: egg(COOKED)`. Grab the plate → egg rides on it (might slide off if you turn too fast — intentional).

**Step 7: Commit**

```bash
git add scripts/items/plate.gd scripts/systems/food_container.gd scenes/items/plate.tscn scenes/kitchen.tscn scripts/player.gd
git commit -m "Add Plate rigidbody with FoodContainer Area3D"
```

---

## Task 10: OrderSystem + DeliveryZone

**Files:**
- Create: `scripts/systems/order_system.gd`
- Create: `scripts/systems/delivery_zone.gd`
- Modify: `scenes/kitchen.tscn` — add OrderSystem node, DeliveryZone on Pass

**Step 1: Write order_system.gd**

```gdscript
class_name OrderSystem
extends Node

@export var recipe_tag: String = "egg"
@export var required_count: int = 1


func current_order_text() -> String:
	return "%d× %s(COOKED)" % [required_count, recipe_tag]


func check_delivery(plate: Plate) -> bool:
	var contents: Array[FoodItem] = plate.get_contents()
	if contents.size() != required_count:
		return false
	for f in contents:
		if f.recipe_tag != recipe_tag:
			return false
		if f.state != FoodItem.State.COOKED:
			return false
	return true
```

**Step 2: Write delivery_zone.gd**

```gdscript
class_name DeliveryZone
extends Area3D

@export_node_path("OrderSystem") var order_system_path: NodePath

signal delivered

@onready var _order_system: OrderSystem = get_node(order_system_path)


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if not body is Plate:
		return
	if not _order_system.check_delivery(body):
		return
	delivered.emit()
	for food in body.get_contents():
		food.queue_free()
	body.queue_free()
```

**Step 3: Add OrderSystem + DeliveryZone to kitchen.tscn**

1. Add a plain `Node` child of `Kitchen` named `OrderSystem`, script `order_system.gd`.
2. As a child of the existing `Pass` static body, add an `Area3D` named `DeliveryZone` with script `delivery_zone.gd`:
   - Child `CollisionShape3D` with `BoxShape3D` size `(1.8, 0.8, 0.6)`, position `(0, 1.2, 0)` — just above the pass's top surface, the player drops the plate there.
   - Set `DeliveryZone.order_system_path` export to `../../OrderSystem`.

**Step 4: Wire overlay**

In `scripts/player.gd:_ready()`:

```gdscript
	var orders: OrderSystem = get_node_or_null("/root/Kitchen/OrderSystem") as OrderSystem
	if orders and overlay:
		overlay.watch("order", Callable(orders, "current_order_text"))
```

Update the OrderBoard label to read dynamically. Create `scripts/ui/order_board.gd`:

```gdscript
extends Label3D

@export_node_path("OrderSystem") var order_system_path: NodePath


func _ready() -> void:
	var system: OrderSystem = get_node(order_system_path)
	text = system.current_order_text()
```

Attach this script to the `TicketLabel` Label3D on the OrderBoard, set `order_system_path` to `../../OrderSystem`.

**Step 5: Manual verification**

F5 → F3. Order board reads `1× egg(COOKED)`. Do the full loop: grab egg → pan → cook → plate → carry to pass → drop plate into the DeliveryZone volume. The plate and its food disappear. No more plate in the world until Task 11 respawns one. `plate.contents` watch shows nothing (plate was freed).

**Failure cases to test:**
- Deliver a raw egg on the plate → plate doesn't disappear, bounces off the pass (works because `body_entered` still fires but check fails and no action is taken).
- Deliver a burned egg → same.
- Deliver an empty plate → same.
- Deliver the pan (no plate script) → nothing happens.

**Step 6: Commit**

```bash
git add scripts/systems/order_system.gd scripts/systems/delivery_zone.gd scripts/ui/order_board.gd scenes/kitchen.tscn scripts/player.gd
git commit -m "Add OrderSystem and DeliveryZone with fixed fried-egg order"
```

---

## Task 11: Spawners — loop resets after delivery

**Files:**
- Create: `scripts/systems/item_spawner.gd`
- Modify: `scenes/kitchen.tscn` — add EggSpawner and PlateSpawner nodes; wire DeliveryZone.delivered signal

**Step 1: Write a generic item_spawner.gd**

```gdscript
class_name ItemSpawner
extends Node3D

@export var item_scene: PackedScene
@export var spawn_on_ready: bool = true

var _last_spawned: Node = null


func _ready() -> void:
	if spawn_on_ready:
		spawn()


func spawn() -> Node:
	if item_scene == null:
		return null
	var instance: Node = item_scene.instantiate()
	get_parent().add_child(instance)
	if instance is Node3D:
		(instance as Node3D).global_position = global_position
	_last_spawned = instance
	return instance
```

**Step 2: Replace the hard-placed egg and plate with spawners**

In `scenes/kitchen.tscn`:

1. Delete the `Egg` and `Plate` instances (we'll spawn them instead).
2. Add `EggSpawner` (`Node3D`, script `item_spawner.gd`) as a child of `Counter` at local `(0, 1.2, 0)`.
   - `item_scene` → `res://scenes/items/egg.tscn`
   - Leave `spawn_on_ready = true` so an egg exists from the start.
3. Add `PlateSpawner` (`Node3D`, script `item_spawner.gd`) as a child of `PlateRack` at local `(0, 1.1, 0)`.
   - `item_scene` → `res://scenes/items/plate.tscn`
   - `spawn_on_ready = true`.

**Step 3: Respawn on delivery**

Add a small script `scripts/systems/kitchen_loop.gd`:

```gdscript
extends Node

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath
@export_node_path("ItemSpawner") var plate_spawner_path: NodePath
@export_node_path("ItemSpawner") var egg_spawner_path: NodePath


func _ready() -> void:
	var zone: DeliveryZone = get_node(delivery_zone_path)
	zone.delivered.connect(_on_delivered)


func _on_delivered() -> void:
	var plate_spawner: ItemSpawner = get_node(plate_spawner_path)
	plate_spawner.spawn()
	# Ensure there's always a raw egg available, in case the player delivered the only one.
	var egg_spawner: ItemSpawner = get_node(egg_spawner_path)
	if get_tree().get_nodes_in_group("food").is_empty():
		egg_spawner.spawn()
```

Add a `Node` to `Kitchen` named `KitchenLoop`, script `kitchen_loop.gd`. Wire its three exports.

**Step 4: Make the player-side overlay hooks late-binding**

The overlay watches pick up concrete node references at `_ready()`, but after a delivery those nodes get freed. Replace the hooks in `scripts/player.gd` with callables that look up the node each frame:

```gdscript
	if overlay:
		var grab: GrabController = $Head/Camera3D/GrabController
		overlay.watch("held", Callable(grab, "held_body_name"))
		overlay.watch("egg.state", func() -> String:
			var f: FoodItem = get_tree().get_first_node_in_group("food") as FoodItem
			return f.state_name() if f else "-")
		overlay.watch("egg.progress", func() -> String:
			var f: FoodItem = get_tree().get_first_node_in_group("food") as FoodItem
			return "%.2f" % f.cook_progress if f else "-")
		overlay.watch("pan.on_stove", func() -> String:
			var p: Pan = get_tree().get_first_node_in_group("pan") as Pan
			return p.on_stove_text() if p else "-")
		overlay.watch("plate.contents", func() -> String:
			var pl: Plate = get_tree().get_first_node_in_group("plate") as Plate
			return pl.container.contents_text() if pl else "empty")
		var orders: OrderSystem = get_node_or_null("/root/Kitchen/OrderSystem") as OrderSystem
		if orders:
			overlay.watch("order", Callable(orders, "current_order_text"))
```

**Step 5: Manual verification**

Full loop smoke test (this is the slice's canonical manual test — keep this list, you'll use it after every change from here on):

1. F5 → Start Game. Overlay (F3) shows `held: <none>`, `egg.state: RAW`, `egg.progress: 0.00`, `pan.on_stove: true`, `plate.contents: empty`, `order: 1× egg(COOKED)`.
2. Walk to counter, grab egg (E). `held: Egg`.
3. Walk to stove, release egg into pan (E). `held: <none>`. `egg.progress` starts climbing.
4. Wait ~1.5s. `egg.state: COOKED`, egg is golden.
5. Grab pan (E), tip over plate. Egg slides onto plate. `plate.contents: egg(COOKED)`.
6. Release pan (E).
7. Grab plate (E).
8. Walk to pass. Release plate into DeliveryZone area.
9. Plate + egg vanish. New plate spawns on rack. New egg spawns on counter (if one isn't already present).
10. Repeat from step 2.

**Step 6: Commit**

```bash
git add scripts/systems/item_spawner.gd scripts/systems/kitchen_loop.gd scenes/kitchen.tscn scripts/player.gd
git commit -m "Add ItemSpawner and KitchenLoop respawn; slice loop complete"
```

---

## Task 12: README smoke test + polish

**Files:**
- Modify: `README.md`

**Step 1: Update README**

Replace the existing README with a version that describes this as the cooking game slice, not the generic first-person sandbox. Keep the same sections (What's included, Requirements) but add a **How to play** section with the 10-step smoke test from Task 11, and a **Debug overlay** section listing the F3 watches.

**Step 2: Final manual verification**

Do the 10-step smoke test one more time. Additionally:
- Drop the egg on the floor instead of in the pan → pick it up again, try again.
- Let the egg burn (wait extra long). Deliver it → plate bounces (check fails).
- Throw the egg (F while holding it) at a wall. Should bounce and come to rest, still RAW.
- Grab the pan, walk to the pass, try to deliver it → nothing happens (type check).
- Grab plate with COOKED egg, walk plate to pass → delivery works.

**Step 3: Commit**

```bash
git add README.md
git commit -m "Document cooking slice in README with smoke test"
```

---

## Out of scope (reminder)

Do NOT add any of the following in this plan. They are deliberate non-goals for the slice:

- Timer, score, or run/fail state
- Customer NPC or dining area
- Additional recipes
- Save/load or settings
- Networking / multiplayer
- Pause menu
- Sound design (the "ding" stays as a TODO)
- Per-item hold offsets (pan looks huge — accepted for the slice)
- Real art (pure primitives only)
- Automated tests

If one of these becomes necessary to unblock a task, **stop and talk to the user** before adding it.

---

## Post-slice backlog (future work, not part of the 12 tasks)

Captured during execution — do NOT address in the slice. Revisit after Task 12:

- **Crouch movement.** Floor-level items like the egg are awkward to reach because you can't lower the camera. Add `crouch` action + smooth `Head` Y-offset lerp while held. Pairs well with collision shape resizing during crouch.
- **Grab aim forgiveness.** Small items (egg radius 0.07) are fiddly to raycast-click. Options: bump `GrabController.grab_range` from 2.5 to 3.5+, or upgrade the ray to a short sphere cast (`PhysicsShapeQueryParameters3D`) for a more forgiving aim cone.

