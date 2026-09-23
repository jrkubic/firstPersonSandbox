# Menu Polish Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task.

**Goal:** Tighten grab reach, give the menu a Play > Solo / Multiplayer > Host via Steam flow, and replace the Sketchfab background with a code-built animated kitchen diorama of three chefs.

**Architecture:** Grab range becomes 2.5 m so aim and pickup agree. The menu keeps one `CanvasLayer` scene but its buttons live in three page containers toggled by script. The diorama is a `Node3D` scene whose script builds every mesh from primitives in `_ready` and drives motion with tweens; it owns the menu camera, so the old `SubViewport` chain goes away. A headless menu test (launcher + body, like the other tests) covers page switching, wiring and that the diorama animates.

**Tech Stack:** Godot 4.7.2, GDScript, primitives (`BoxMesh`, `CylinderMesh`, `SphereMesh`, `CapsuleMesh`), `Tween`, `GPUParticles3D`.

**Deferred by the user:** a cooking-progress indicator on the pan (design was: billboard bar + RAW/COOKING/COOKED/BURNING label reading the egg's replicated `cook_progress`). Not in this plan.

---

## Conventions

- Project root `C:\Projects\firstPersonSandbox`, branch `polish`.
- `GODOT` = `C:\Users\Jake\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe`; `GODOT_WIN` = the same folder's `Godot_v4.7.2-stable_win64.exe` (windowed).
- Headless tests are a SceneTree launcher that loads a Node body (see `tests/smoke_test.gd` header for why). Bodies prefix SceneTree calls with `get_tree().`.
- Smoke: `& $GODOT --headless --path . --script res://tests/smoke_test.gd` → `SUMMARY: 94 passed, 0 failed, 1 xfailed`.
- Net: `powershell -ExecutionPolicy Bypass -File tests/run_net_test.ps1` → `host: 11 passed`, `client: 23 passed`, `NET TEST PASSED`.
- Menu (new in Task A): `& $GODOT --headless --path . --script res://tests/menu_test.gd`.
- Commit per task; trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task A: Grab reach and the Play / Solo / Multiplayer menu

**Files:**
- Modify: `scripts/systems/grab_controller.gd` (one export default)
- Modify: `docs/WALKTHROUGH.md` (one table cell)
- Modify: `scenes/menu.tscn` (Control subtree)
- Modify: `scripts/menu.gd` (rewrite)
- Create: `tests/menu_test.gd`, `tests/menu_test_body.gd`
- Modify: `README.md`, `tests/README.md` (menu test + flow)

**Step 1: Write the failing menu test**

`tests/menu_test.gd`:

```gdscript
extends SceneTree
## Headless menu test entry point (launcher + body split, see smoke_test.gd).
##   Godot_console.exe --headless --path . --script res://tests/menu_test.gd

const BODY_SCRIPT: String = "res://tests/menu_test_body.gd"


func _initialize() -> void:
	var body_script: GDScript = load(BODY_SCRIPT) as GDScript
	if body_script == null:
		printerr("FAIL launcher: could not load %s" % BODY_SCRIPT)
		quit(1)
		return
	var body: Node = body_script.new() as Node
	body.name = "MenuTest"
	root.add_child(body)
```

`tests/menu_test_body.gd`:

```gdscript
extends Node
## Headless checks for scenes/menu.tscn: page flow, button wiring, status
## text, and (Task B) that the diorama builds and animates. Steam is never
## available headless, so the Multiplayer page must show Host disabled.

const MENU_SCENE: String = "res://scenes/menu.tscn"
const WATCHDOG_SECONDS: float = 60.0
const EXPECTED_CHECKS: int = 12

var _passed: int = 0
var _failed: int = 0
var _start_msec: int = 0
var _finished: bool = false
var _menu: CanvasLayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_start_msec = Time.get_ticks_msec()
	_run.call_deferred()


func _process(_delta: float) -> void:
	if _finished:
		return
	if float(Time.get_ticks_msec() - _start_msec) / 1000.0 > WATCHDOG_SECONDS:
		print("FAIL watchdog: did not finish within %.0f s" % WATCHDOG_SECONDS)
		_failed += 1
		_finish()


func _run() -> void:
	var packed: PackedScene = load(MENU_SCENE)
	if packed == null:
		_check("menu.load", false, "could not load %s" % MENU_SCENE)
		_finish()
		return
	_menu = packed.instantiate() as CanvasLayer
	get_tree().root.add_child(_menu)
	get_tree().current_scene = _menu
	await get_tree().process_frame

	var main_page: Control = _menu.get_node_or_null("%MainPage") as Control
	var play_page: Control = _menu.get_node_or_null("%PlayPage") as Control
	var mp_page: Control = _menu.get_node_or_null("%MultiplayerPage") as Control
	var status: Label = _menu.get_node_or_null("%StatusLabel") as Label
	if not _check("menu.pages_exist",
			main_page != null and play_page != null and mp_page != null and status != null,
			"missing unique-named page or StatusLabel"):
		_finish()
		return
	_check("menu.main_first", main_page.visible and not play_page.visible and not mp_page.visible,
		"main=%s play=%s mp=%s" % [main_page.visible, play_page.visible, mp_page.visible])
	_check("menu.status_offline", status.text == "Steam not detected: solo only",
		"status=%s" % status.text)

	_press("%PlayButton")
	_check("menu.play_opens_play_page", play_page.visible and not main_page.visible,
		"play=%s main=%s" % [play_page.visible, main_page.visible])
	_press("%PlayBackButton")
	_check("menu.play_back", main_page.visible and not play_page.visible, "back did not return to main")

	_press("%PlayButton")
	_press("%MultiplayerButton")
	_check("menu.multiplayer_opens_mp_page", mp_page.visible and not play_page.visible,
		"mp=%s play=%s" % [mp_page.visible, play_page.visible])
	var host: Button = _menu.get_node("%HostButton") as Button
	_check("menu.host_disabled_without_steam", host.disabled, "Host enabled with no Steam")
	_check("menu.host_text", host.text == "Host via Steam", "host text=%s" % host.text)
	_press("%MultiplayerBackButton")
	_check("menu.mp_back", play_page.visible and not mp_page.visible, "back did not return to play page")

	var solo: Button = _menu.get_node("%SoloButton") as Button
	_check("menu.solo_wired", solo.pressed.get_connections().size() == 1,
		"solo connections=%d" % solo.pressed.get_connections().size())
	var quit: Button = _menu.get_node("%QuitButton") as Button
	_check("menu.quit_wired", quit.pressed.get_connections().size() == 1,
		"quit connections=%d" % quit.pressed.get_connections().size())

	# --- Task B: diorama checks ---

	_finish()


func _press(unique_name: String) -> void:
	var button: Button = _menu.get_node(unique_name) as Button
	button.pressed.emit()


func _finish() -> void:
	_finished = true
	var total: int = _passed + _failed
	if total != EXPECTED_CHECKS:
		_failed += 1
		print("FAIL summary.count: %d checks ran, expected %d" % [total, EXPECTED_CHECKS])
	print("SUMMARY: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(check_name: String, ok: bool, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("PASS %s" % check_name)
	else:
		_failed += 1
		print("FAIL %s: %s" % [check_name, detail])
	return ok
```

Run: `& $GODOT --headless --path . --script res://tests/menu_test.gd`. Expected: `FAIL menu.pages_exist` then a count failure, exit 1.

**Step 2: Grab reach**

`scripts/systems/grab_controller.gd`: `@export var grab_range: float = 2.5`. In `docs/WALKTHROUGH.md` change `out of \`grab_range\` (4 m)` to `(2.5 m)`.

**Step 3: Menu scene**

In `scenes/menu.tscn`, keep everything up to and including the `[node name="Control" ...]` block's `MarginContainer`, then replace the `VBoxContainer` and all its children (GameTitle through StatusLabel) with the tree below. Every button copies the existing button block's `theme_override_*` lines verbatim (same `SubResource` ids: `FontVariation_con2f`, `StyleBoxEmpty_mhnvy`, `_4ytvr`, `_g3eks`, `_v86rl`, `_13sgg`, `_i6lef`, `_70i5f`, `_mj5lg`, `_ufwb2`, `_6cdou`, `_i42df`); the snippet shows them once as `<BUTTON STYLE>` for brevity, paste the real lines in each button. `unique_name_in_owner = true` on every node the test addresses with `%`.

```
[node name="VBoxContainer" type="VBoxContainer" parent="Control/MarginContainer"]
layout_mode = 2

[node name="GameTitle" type="Label" parent="Control/MarginContainer/VBoxContainer"]
layout_mode = 2
size_flags_horizontal = 0
theme_override_fonts/font = SubResource("FontVariation_vjb58")
theme_override_font_sizes/font_size = 62
text = "Jakes 3D Game"
horizontal_alignment = 1

[node name="Spacer" type="MarginContainer" parent="Control/MarginContainer/VBoxContainer"]
custom_minimum_size = Vector2(0, 80)
layout_mode = 2

[node name="MainPage" type="VBoxContainer" parent="Control/MarginContainer/VBoxContainer"]
unique_name_in_owner = true
layout_mode = 2

[node name="PlayButton" type="Button" parent="Control/MarginContainer/VBoxContainer/MainPage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 0
<BUTTON STYLE>
text = "Play"

[node name="QuitButton" type="Button" parent="Control/MarginContainer/VBoxContainer/MainPage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 0
<BUTTON STYLE>
text = "Quit"

[node name="PlayPage" type="VBoxContainer" parent="Control/MarginContainer/VBoxContainer"]
unique_name_in_owner = true
visible = false
layout_mode = 2

[node name="SoloButton" type="Button" parent="Control/MarginContainer/VBoxContainer/PlayPage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 0
<BUTTON STYLE>
text = "Solo"

[node name="MultiplayerButton" type="Button" parent="Control/MarginContainer/VBoxContainer/PlayPage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 0
<BUTTON STYLE>
text = "Multiplayer"

[node name="PlayBackButton" type="Button" parent="Control/MarginContainer/VBoxContainer/PlayPage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 0
<BUTTON STYLE>
text = "Back"

[node name="MultiplayerPage" type="VBoxContainer" parent="Control/MarginContainer/VBoxContainer"]
unique_name_in_owner = true
visible = false
layout_mode = 2

[node name="HostButton" type="Button" parent="Control/MarginContainer/VBoxContainer/MultiplayerPage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 0
<BUTTON STYLE>
text = "Host via Steam"

[node name="HelpLabel" type="Label" parent="Control/MarginContainer/VBoxContainer/MultiplayerPage"]
layout_mode = 2
size_flags_horizontal = 0
theme_override_font_sizes/font_size = 20
text = "Friends join through a Steam invite once you're hosting."

[node name="MultiplayerBackButton" type="Button" parent="Control/MarginContainer/VBoxContainer/MultiplayerPage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 0
<BUTTON STYLE>
text = "Back"

[node name="StatusLabel" type="Label" parent="Control/MarginContainer/VBoxContainer"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 0
theme_override_font_sizes/font_size = 20
text = ""
```

**Step 4: Menu script**

`scripts/menu.gd`:

```gdscript
extends CanvasLayer
## Title menu: Play > Solo / Multiplayer > Host via Steam. Join is by Steam
## invite only, so the Multiplayer page has a single action plus help text.

@export_file("*.tscn") var game_scene: String = "res://scenes/kitchen.tscn"

@onready var main_page: Control = %MainPage
@onready var play_page: Control = %PlayPage
@onready var multiplayer_page: Control = %MultiplayerPage
@onready var play_button: Button = %PlayButton
@onready var quit_button: Button = %QuitButton
@onready var solo_button: Button = %SoloButton
@onready var multiplayer_button: Button = %MultiplayerButton
@onready var play_back_button: Button = %PlayBackButton
@onready var host_button: Button = %HostButton
@onready var multiplayer_back_button: Button = %MultiplayerBackButton
@onready var status_label: Label = %StatusLabel


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	play_button.pressed.connect(func() -> void: _show_page(play_page))
	quit_button.pressed.connect(_on_quit_pressed)
	solo_button.pressed.connect(_on_solo_pressed)
	multiplayer_button.pressed.connect(func() -> void: _show_page(multiplayer_page))
	play_back_button.pressed.connect(func() -> void: _show_page(main_page))
	host_button.pressed.connect(_on_host_pressed)
	multiplayer_back_button.pressed.connect(func() -> void: _show_page(play_page))
	_refresh_host_button()
	if NetSession.last_message != "":
		status_label.text = NetSession.last_message
		NetSession.last_message = ""
	elif SteamManager.is_ready():
		status_label.text = "Steam ready as %s." % SteamManager.persona_name()
	else:
		status_label.text = "Steam not detected: solo only"
	NetSession.session_ended.connect(_on_session_ended)
	_show_page(main_page)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if multiplayer_page.visible:
			_show_page(play_page)
		elif play_page.visible:
			_show_page(main_page)


func _show_page(page: Control) -> void:
	for candidate: Control in [main_page, play_page, multiplayer_page]:
		candidate.visible = candidate == page


func _refresh_host_button() -> void:
	host_button.disabled = not SteamManager.is_ready()


func _on_session_ended(reason: String) -> void:
	status_label.text = reason
	_refresh_host_button()
	NetSession.last_message = ""


func _on_solo_pressed() -> void:
	NetSession.leave()
	get_tree().change_scene_to_file(game_scene)


func _on_host_pressed() -> void:
	status_label.text = "Creating Steam lobby..."
	host_button.disabled = true
	NetSession.host_steam()


func _on_quit_pressed() -> void:
	NetSession.leave()
	get_tree().quit()
```

**Step 5: Run everything**

Menu test → `SUMMARY: 12 passed, 0 failed`, exit 0. Smoke → `94 passed, 0 failed, 1 xfailed`. Net → `NET TEST PASSED`.

**Step 6: Docs**

`README.md`: How to run says Play > Solo or Play > Multiplayer > Host via Steam; the Automated tests section gets a `### Menu test` paragraph (command, 12 checks, no Steam). `tests/README.md`: a `## Menu test` section. Update the Escape row note only if it mentions the menu (it doesn't).

**Step 7: Commit**

`git commit -m "Grab range 2.5 m; Play > Solo / Multiplayer menu flow with headless menu test"`

---

### Task B: Animated kitchen diorama for the menu

**Files:**
- Create: `scripts/ui/menu_diorama.gd`, `scenes/ui/menu_diorama.tscn`
- Modify: `scenes/menu.tscn` (Background subtree)
- Modify: `tests/menu_test_body.gd` (diorama checks; `EXPECTED_CHECKS` 12 → 16)
- Modify: `README.md` (menu diorama mention, `scene.gltf` note)

**Step 1: Failing checks**

Replace `# --- Task B: diorama checks ---` in `tests/menu_test_body.gd` with:

```gdscript
	var diorama: Node3D = _menu.get_node_or_null("Background/MenuDiorama") as Node3D
	if _check("diorama.present", diorama != null, "Background/MenuDiorama missing"):
		var chefs: Array[Node] = diorama.get_node("Chefs").get_children()
		_check("diorama.three_chefs", chefs.size() == 3, "chefs=%d" % chefs.size())
		var camera: Camera3D = diorama.get_node_or_null("Camera3D") as Camera3D
		_check("diorama.camera_current", camera != null and camera.current, "no current camera")
		var before: Array[Vector3] = []
		for chef: Node in chefs:
			before.append((chef as Node3D).global_position)
		for i in range(90):
			await get_tree().process_frame
		var moved: int = 0
		for i in range(chefs.size()):
			if (chefs[i] as Node3D).global_position.distance_to(before[i]) > 0.05:
				moved += 1
		_check("diorama.chefs_move", moved >= 2, "only %d chefs moved in 90 frames" % moved)
	else:
		_check("diorama.three_chefs", false, "skipped")
		_check("diorama.camera_current", false, "skipped")
		_check("diorama.chefs_move", false, "skipped")
```

Set `EXPECTED_CHECKS = 16`. Run the menu test: expect the four `diorama.*` failures.

**Step 2: The diorama scene**

`scenes/ui/menu_diorama.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/ui/menu_diorama.gd" id="1_diorama"]

[node name="MenuDiorama" type="Node3D"]
script = ExtResource("1_diorama")

[node name="Chefs" type="Node3D" parent="."]

[node name="Camera3D" type="Camera3D" parent="."]
current = true
fov = 48.0
```

**Step 3: The diorama script**

`scripts/ui/menu_diorama.gd`. Everything is built in `_ready` from primitives so it matches the kitchen's flat look; motion is tweens on loop. Sizes in metres; the set is about 6 m wide.

```gdscript
extends Node3D
## Title-screen diorama: a flat-shaded kitchen with three capsule chefs who
## loop between stations (stove, counter with egg crate, pass window). Built
## entirely from primitives in _ready so it needs no assets and matches the
## grey-box game. The camera orbits slowly around the set.

const FLOOR_COLOR := Color(0.82, 0.78, 0.72)
const WALL_COLOR := Color(0.93, 0.90, 0.84)
const COUNTER_COLOR := Color(0.55, 0.42, 0.32)
const STOVE_COLOR := Color(0.25, 0.26, 0.30)
const BURNER_COLOR := Color(1.0, 0.45, 0.15)
const PASS_COLOR := Color(0.75, 0.62, 0.45)
const SKIN_COLOR := Color(0.96, 0.80, 0.66)
const HAT_COLOR := Color(0.98, 0.98, 0.96)
const EGG_COLOR := Color(1.0, 0.98, 0.92)
const PLATE_COLOR := Color(0.95, 0.95, 0.97)
const PAN_COLOR := Color(0.18, 0.18, 0.2)
const APRON_COLORS: Array[Color] = [Color(0.85, 0.25, 0.2), Color(0.2, 0.45, 0.85), Color(0.25, 0.7, 0.35)]

const STOVE_POS := Vector3(-1.8, 0.0, -0.6)
const COUNTER_POS := Vector3(1.8, 0.0, -0.6)
const PASS_POS := Vector3(0.0, 0.0, -2.2)
const ORBIT_RADIUS := 6.2
const ORBIT_HEIGHT := 3.0
const ORBIT_SPEED := 0.12  # radians per second
const LOOK_AT := Vector3(0.0, 0.7, -0.8)

@onready var _chefs_root: Node3D = $Chefs
@onready var _camera: Camera3D = $Camera3D

var _orbit_angle: float = 0.6
var _pan_egg: MeshInstance3D
var _carried_plate: Node3D
var _carried_egg: Node3D


func _ready() -> void:
	_build_environment()
	_build_set()
	_build_chefs()
	_start_camera()


func _process(delta: float) -> void:
	_orbit_angle += ORBIT_SPEED * delta
	_camera.global_position = Vector3(
		sin(_orbit_angle) * ORBIT_RADIUS, ORBIT_HEIGHT, cos(_orbit_angle) * ORBIT_RADIUS - 0.8)
	_camera.look_at(LOOK_AT, Vector3.UP)


# --- Environment and set ------------------------------------------------------

func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.55, 0.72, 0.95)
	sky_material.sky_horizon_color = Color(0.95, 0.85, 0.75)
	sky_material.ground_bottom_color = Color(0.6, 0.55, 0.5)
	sky_material.ground_horizon_color = Color(0.95, 0.85, 0.75)
	var sky := Sky.new()
	sky.sky_material = sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.1
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	add_child(sun)


func _build_set() -> void:
	_box(Vector3(0.0, -0.1, -0.8), Vector3(7.0, 0.2, 5.0), FLOOR_COLOR)          # floor
	_box(Vector3(0.0, 1.5, -3.2), Vector3(7.0, 3.0, 0.2), WALL_COLOR)            # back wall
	# Pass window: a shelf through the wall with two plates waiting.
	_box(PASS_POS + Vector3(0.0, 0.5, -0.6), Vector3(2.2, 1.0, 0.5), PASS_COLOR)
	_box(PASS_POS + Vector3(0.0, 1.9, -0.9), Vector3(2.4, 0.15, 0.6), PASS_COLOR)  # window header
	_cylinder(PASS_POS + Vector3(-0.5, 1.02, -0.6), 0.22, 0.03, PLATE_COLOR)
	_cylinder(PASS_POS + Vector3(0.5, 1.02, -0.6), 0.22, 0.03, PLATE_COLOR)
	# Stove with two burners and a pan on the front one.
	_box(STOVE_POS + Vector3(0.0, 0.45, 0.0), Vector3(1.2, 0.9, 1.0), STOVE_COLOR)
	_cylinder(STOVE_POS + Vector3(-0.3, 0.91, 0.2), 0.18, 0.02, BURNER_COLOR, true)
	_cylinder(STOVE_POS + Vector3(0.3, 0.91, -0.25), 0.18, 0.02, BURNER_COLOR, true)
	var pan := _cylinder(STOVE_POS + Vector3(-0.3, 0.95, 0.2), 0.26, 0.05, PAN_COLOR)
	var handle := _box(Vector3(0.0, 0.0, 0.42), Vector3(0.05, 0.03, 0.4), PAN_COLOR)
	handle.reparent(pan)
	handle.position = Vector3(0.0, 0.0, 0.42)
	_pan_egg = _sphere(STOVE_POS + Vector3(-0.3, 1.05, 0.2), 0.08, EGG_COLOR)
	_start_egg_flip(pan)
	_start_steam(STOVE_POS + Vector3(-0.3, 1.1, 0.2))
	# Counter with an egg crate.
	_box(COUNTER_POS + Vector3(0.0, 0.45, 0.0), Vector3(1.2, 0.9, 1.0), COUNTER_COLOR)
	_box(COUNTER_POS + Vector3(0.0, 0.96, 0.0), Vector3(0.6, 0.12, 0.45), Color(0.8, 0.7, 0.5))
	for i in range(6):
		var x: float = -0.18 + 0.18 * (i % 3)
		var z: float = -0.1 + 0.2 * (i / 3)
		_sphere(COUNTER_POS + Vector3(x, 1.06, z), 0.07, EGG_COLOR)


# --- Chefs ---------------------------------------------------------------------

func _build_chefs() -> void:
	var stove_side: Vector3 = STOVE_POS + Vector3(0.0, 0.0, 0.9)
	var counter_side: Vector3 = COUNTER_POS + Vector3(0.0, 0.0, 0.9)
	var pass_side: Vector3 = PASS_POS + Vector3(0.0, 0.0, 0.9)
	var middle: Vector3 = Vector3(0.0, 0.0, 0.6)

	# Chef 0 works the stove: bobs in place and flips the pan.
	var cook: Node3D = _make_chef(APRON_COLORS[0], stove_side, Vector3(0.0, 0.0, -1.0))
	_loop_bob(cook, 0.9)

	# Chef 1 runs plates from the counter to the pass and back.
	var runner: Node3D = _make_chef(APRON_COLORS[1], counter_side, Vector3(-1.0, 0.0, 0.0))
	_carried_plate = _cylinder(Vector3.ZERO, 0.2, 0.03, PLATE_COLOR)
	_carried_plate.reparent(runner)
	_carried_plate.position = Vector3(0.0, 1.05, -0.35)
	_loop_path(runner, [counter_side, middle, pass_side, middle], [1.1, 0.9, 1.3, 0.9], 0.35)

	# Chef 2 ferries eggs from the crate to the stove.
	var fetcher: Node3D = _make_chef(APRON_COLORS[2], middle + Vector3(0.9, 0.0, 0.9), Vector3(0.0, 0.0, -1.0))
	_carried_egg = _sphere(Vector3.ZERO, 0.08, EGG_COLOR)
	_carried_egg.reparent(fetcher)
	_carried_egg.position = Vector3(0.2, 1.0, -0.35)
	_loop_path(fetcher,
		[counter_side + Vector3(0.0, 0.0, 0.6), stove_side + Vector3(0.0, 0.0, 0.7),
			counter_side + Vector3(0.0, 0.0, 0.6)],
		[1.4, 1.4, 0.0], 0.6)


## A chef: apron-coloured capsule body, skin sphere head, tall white hat with
## a brim, two hand spheres. Faces `facing` (a horizontal direction).
func _make_chef(apron: Color, at: Vector3, facing: Vector3) -> Node3D:
	var chef := Node3D.new()
	chef.position = at
	_chefs_root.add_child(chef)
	var body := _capsule(Vector3(0.0, 0.55, 0.0), 0.22, 0.75, apron)
	body.reparent(chef, false)
	var head := _sphere(Vector3(0.0, 1.12, 0.0), 0.17, SKIN_COLOR)
	head.reparent(chef, false)
	var hat := _cylinder(Vector3(0.0, 1.42, 0.0), 0.14, 0.32, HAT_COLOR)
	hat.reparent(chef, false)
	var brim := _cylinder(Vector3(0.0, 1.27, 0.0), 0.2, 0.05, HAT_COLOR)
	brim.reparent(chef, false)
	for side: float in [-1.0, 1.0]:
		var hand := _sphere(Vector3(0.26 * side, 0.85, -0.15), 0.07, SKIN_COLOR)
		hand.reparent(chef, false)
	if facing.length() > 0.0:
		chef.look_at(at + facing, Vector3.UP)
	return chef


# --- Motion --------------------------------------------------------------------

## Moves a chef around a closed list of points forever; each leg takes
## `durations[i]` seconds and the chef turns to face its travel direction.
## `hop` is the little bounce height per leg.
func _loop_path(chef: Node3D, points: Array[Vector3], durations: Array[float], hop: float) -> void:
	var tween := create_tween().set_loops()
	for i in range(points.size()):
		var target: Vector3 = points[(i + 1) % points.size()]
		var duration: float = durations[i]
		if duration <= 0.0:
			continue
		tween.tween_callback(func() -> void:
			var flat: Vector3 = Vector3(target.x, chef.position.y, target.z)
			if flat.distance_to(chef.position) > 0.01:
				chef.look_at(flat, Vector3.UP))
		tween.tween_property(chef, "position", target, duration).set_trans(Tween.TRANS_SINE)
		tween.parallel().tween_method(func(t: float) -> void:
			chef.position.y = sin(t * PI * 3.0) * hop * 0.15, 0.0, 1.0, duration)
		tween.tween_interval(0.25)


## Stationary chef: bobs up and down.
func _loop_bob(chef: Node3D, period: float) -> void:
	var tween := create_tween().set_loops()
	tween.tween_property(chef, "position:y", 0.08, period * 0.5).set_trans(Tween.TRANS_SINE)
	tween.tween_property(chef, "position:y", 0.0, period * 0.5).set_trans(Tween.TRANS_SINE)


## The pan tips and its egg pops up and lands back in, forever.
func _start_egg_flip(pan: Node3D) -> void:
	var rest: Vector3 = _pan_egg.position
	var tween := create_tween().set_loops()
	tween.tween_interval(0.8)
	tween.tween_property(pan, "rotation:x", -0.35, 0.15).set_trans(Tween.TRANS_QUAD)
	tween.parallel().tween_property(_pan_egg, "position", rest + Vector3(0.0, 0.7, 0.0), 0.35)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_pan_egg, "rotation:x", TAU, 0.7)
	tween.tween_property(pan, "rotation:x", 0.0, 0.2).set_trans(Tween.TRANS_BOUNCE)
	tween.parallel().tween_property(_pan_egg, "position", rest, 0.35)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func() -> void: _pan_egg.rotation.x = 0.0)


func _start_steam(at: Vector3) -> void:
	var particles := GPUParticles3D.new()
	particles.position = at
	particles.amount = 12
	particles.lifetime = 1.6
	particles.randomness = 0.4
	var material := ParticleProcessMaterial.new()
	material.direction = Vector3.UP
	material.spread = 12.0
	material.initial_velocity_min = 0.3
	material.initial_velocity_max = 0.5
	material.gravity = Vector3(0.0, 0.15, 0.0)
	material.scale_min = 0.6
	material.scale_max = 1.0
	material.color = Color(1.0, 1.0, 1.0, 0.35)
	particles.process_material = material
	var mesh := SphereMesh.new()
	mesh.radius = 0.06
	mesh.height = 0.12
	var puff := StandardMaterial3D.new()
	puff.albedo_color = Color(1.0, 1.0, 1.0, 0.35)
	puff.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = puff
	particles.draw_pass_1 = mesh
	add_child(particles)


func _start_camera() -> void:
	_camera.current = true
	_process(0.0)


# --- Primitive helpers ----------------------------------------------------------

func _material(color: Color, emissive: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.5
	return material


func _box(at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _material(color)
	return _place(mesh, at)


func _cylinder(at: Vector3, radius: float, height: float, color: Color, emissive: bool = false) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.material = _material(color, emissive)
	return _place(mesh, at)


func _sphere(at: Vector3, radius: float, color: Color) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = _material(color)
	return _place(mesh, at)


func _capsule(at: Vector3, radius: float, height: float, color: Color) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.material = _material(color)
	return _place(mesh, at)


func _place(mesh: Mesh, at: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = at
	add_child(instance)
	return instance
```

Notes for the executor:
- `reparent(node, false)` keeps the local transform (we set positions as chef-local). For the pan handle and carried props we reparent then set `position` explicitly.
- If `tween_method` with a lambda that captures `chef` complains about the bound argument, replace the hop with a second `tween_property(chef, "position:y", ...)` pair per leg. Keep it simple.
- If GPUParticles3D errors headless (no rendering device), guard `_start_steam` with `if DisplayServer.get_name() == "headless": return`.

**Step 4: Menu scene background**

In `scenes/menu.tscn`: remove the `scene.gltf` ext_resource line and the `Sketchfab_Scene`, `SubViewportContainer`, `SubViewport` and `Camera3D` nodes under `Background`. Add an ext_resource `[ext_resource type="PackedScene" path="res://scenes/ui/menu_diorama.tscn" id="3_diorama"]` and one child:

```
[node name="MenuDiorama" parent="Background" instance=ExtResource("3_diorama")]
```

Fix the `load_steps` count if the file declares one (it doesn't today).

**Step 5: Verify**

1. Menu test → `SUMMARY: 16 passed, 0 failed`.
2. Smoke and net unchanged.
3. **Screenshot.** Write a scratch script (not in the repo) that extends `SceneTree`, loads `scenes/menu.tscn` as current scene, waits 90 frames, then `root.get_viewport().get_texture().get_image().save_png("<scratchpad>/menu_shot.png")` and quits. Run it with `$GODOT_WIN --path . --script <path>` (windowed; a window flashes). Report the PNG path so the coordinator can look at it. Take a second shot at frame 200 to show motion.

**Step 6: Docs**

`README.md`: Project layout adds `scenes/ui/menu_diorama.tscn` and `scripts/ui/menu_diorama.gd`; note that `scene.gltf`, `scene.bin` and `textures/` are no longer used by any scene and can be deleted. Known limitations: nothing new.

**Step 7: Commit**

`git commit -m "Menu: procedural animated kitchen diorama replaces the Sketchfab background"`
