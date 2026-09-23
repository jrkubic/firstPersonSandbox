extends Node3D
## Title-screen diorama: a flat-shaded kitchen with three capsule chefs who
## loop between stations (stove, counter with egg crate, pass window). Built
## entirely from primitives in _ready so it needs no assets and matches the
## grey-box game. The camera sways gently in front of the set, which sits in
## the right ~60% of the frame so the menu column on the left stays clear.

const FLOOR_COLOR := Color(0.58, 0.50, 0.42)
const WALL_COLOR := Color(0.88, 0.84, 0.76)
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

const STOVE_POS := Vector3(-1.2, 0.0, -1.4)
const COUNTER_POS := Vector3(2.0, 0.0, -1.4)
const PASS_POS := Vector3(0.4, 0.0, -2.6)
const ORBIT_RADIUS := 5.8
const ORBIT_HEIGHT := 2.5
const SWAY_CENTER := 0.25    # radians; camera sits right of centre
const SWAY_AMPLITUDE := 0.35
const SWAY_SPEED := 0.25     # radians per second of the sway phase
# Aimed left of the set's centre: the camera sits on the +x side, so looking
# left of centre keeps the whole set in the right ~60% of the frame.
const LOOK_AT := Vector3(-1.2, 0.8, -0.7)

@onready var _chefs_root: Node3D = $Chefs
@onready var _camera: Camera3D = $Camera3D

var _sway_time: float = 0.0
var _orbit_angle: float = SWAY_CENTER
var _pan_egg: MeshInstance3D


func _ready() -> void:
	_build_environment()
	_build_set()
	_build_chefs()
	_start_camera()


func _process(delta: float) -> void:
	_sway_time += delta
	_orbit_angle = SWAY_CENTER + sin(_sway_time * SWAY_SPEED) * SWAY_AMPLITUDE
	_camera.global_position = Vector3(
		sin(_orbit_angle) * ORBIT_RADIUS, ORBIT_HEIGHT, cos(_orbit_angle) * ORBIT_RADIUS - 0.8)
	_camera.look_at(LOOK_AT, Vector3.UP)


# --- Environment and set ------------------------------------------------------

func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.55, 0.72, 0.95)
	sky_material.sky_horizon_color = Color(0.95, 0.85, 0.75)
	sky_material.ground_bottom_color = FLOOR_COLOR
	sky_material.ground_horizon_color = FLOOR_COLOR
	var sky := Sky.new()
	sky.sky_material = sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.85
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	add_child(sun)


func _build_set() -> void:
	_box(Vector3(0.0, -0.1, -0.8), Vector3(8.0, 0.2, 6.0), FLOOR_COLOR)          # floor
	_box(Vector3(0.0, 1.5, -3.6), Vector3(16.0, 3.0, 0.2), WALL_COLOR)           # back wall
	# Left wall only: the camera sits on +x and never sees a right wall at this
	# sway, and a right wall would throw a dark wedge across the floor.
	var left_wall := _box(Vector3(-3.6, 1.5, -0.8), Vector3(0.2, 3.0, 5.6), WALL_COLOR)
	left_wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	var middle: Vector3 = Vector3(0.6, 0.0, 0.4)

	# Chef 0 works the stove: bobs in place and flips the pan.
	var cook: Node3D = _make_chef(APRON_COLORS[0], stove_side, Vector3(0.0, 0.0, -1.0))
	_loop_bob(cook, 0.9)

	# Chef 1 runs plates from the counter to the pass and back.
	var runner: Node3D = _make_chef(APRON_COLORS[1], counter_side, Vector3(-1.0, 0.0, 0.0))
	var carried_plate: Node3D = _cylinder(Vector3.ZERO, 0.2, 0.03, PLATE_COLOR)
	carried_plate.reparent(runner)
	carried_plate.position = Vector3(0.0, 0.85, -0.35)
	_loop_path(runner, [counter_side, middle, pass_side, middle], [1.1, 0.9, 1.3, 0.9], 0.35)

	# Chef 2 ferries eggs from the crate to the stove.
	var fetcher: Node3D = _make_chef(APRON_COLORS[2], middle + Vector3(1.2, 0.0, 0.6), Vector3(0.0, 0.0, -1.0))
	var carried_egg: Node3D = _sphere(Vector3.ZERO, 0.08, EGG_COLOR)
	carried_egg.reparent(fetcher)
	carried_egg.position = Vector3(0.2, 0.8, -0.35)
	_loop_path(fetcher,
		[counter_side + Vector3(0.0, 0.0, 0.6), stove_side + Vector3(0.0, 0.0, 0.7),
			counter_side + Vector3(0.0, 0.0, 0.6)],
		[1.4, 1.4, 0.0], 0.4)


## A chef: apron-coloured capsule body, skin sphere head, tall white hat with
## a brim, two hand spheres. Faces `facing` (a horizontal direction).
func _make_chef(apron: Color, at: Vector3, facing: Vector3) -> Node3D:
	var chef := Node3D.new()
	chef.position = at
	_chefs_root.add_child(chef)
	var body := _capsule(Vector3(0.0, 0.35, 0.0), 0.19, 0.7, apron)  # bottom on the floor
	body.reparent(chef, false)
	var head := _sphere(Vector3(0.0, 0.9, 0.0), 0.15, SKIN_COLOR)
	head.reparent(chef, false)
	var hat := _cylinder(Vector3(0.0, 1.18, 0.0), 0.12, 0.3, HAT_COLOR)
	hat.reparent(chef, false)
	var brim := _cylinder(Vector3(0.0, 1.04, 0.0), 0.17, 0.05, HAT_COLOR)
	brim.reparent(chef, false)
	for side: float in [-1.0, 1.0]:
		var hand := _sphere(Vector3(0.22 * side, 0.68, -0.12), 0.06, SKIN_COLOR)
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
			chef.position.y = abs(sin(t * PI * 3.0)) * hop, 0.0, 1.0, duration)
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
	puff.vertex_color_use_as_albedo = true  # lets the process material's colour apply
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
