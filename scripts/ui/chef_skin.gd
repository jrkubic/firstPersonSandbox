class_name ChefSkin
extends Node3D
## A chef made of primitives: apron-coloured capsule body and two hands under
## this node, and a head, hat and brim under `head_anchor` (the player's Head
## node, so they follow the synced look; the diorama leaves it null and gets
## an internal pivot). Sizes are in metres for a 1.7 m eye height.
##
## Call build() once; set shadows_only for the local player's own body.

const APRON_COLORS: Array[Color] = [
	Color(0.85, 0.25, 0.2), Color(0.2, 0.45, 0.85), Color(0.25, 0.7, 0.35), Color(0.9, 0.7, 0.2),
]
const SKIN_COLOR := Color(0.96, 0.80, 0.66)
const HAT_COLOR := Color(0.98, 0.98, 0.96)

## Index into APRON_COLORS; wraps.
@export var color_index: int = 0
## Height of the eye line above the node; the head is centred slightly below it.
@export var eye_height: float = 1.7
## When true every mesh casts shadows only (the local player's own body).
var shadows_only: bool = false:
	set(value):
		shadows_only = value
		_apply_shadow_mode()

var body: MeshInstance3D
var head: MeshInstance3D
var hat: MeshInstance3D
var brim: MeshInstance3D
var hands: Array[MeshInstance3D] = []

var _head_anchor: Node3D
var _meshes: Array[MeshInstance3D] = []


## Builds the parts. head_anchor: where the head, hat and brim go (null = an
## internal pivot at eye height under this node).
func build(head_anchor: Node3D = null) -> void:
	for mesh in _meshes:
		mesh.queue_free()
	_meshes.clear()
	hands.clear()
	var apron: Color = APRON_COLORS[posmod(color_index, APRON_COLORS.size())]
	# Body: capsule from the floor to just under the chin (the head's bottom
	# sits at eye_height - 0.25; 0.82 leaves a short neck rather than a gap).
	var body_height: float = eye_height * 0.82
	body = _capsule(self, Vector3(0.0, body_height * 0.5, 0.0), 0.3, body_height, apron)
	for side: float in [-1.0, 1.0]:
		hands.append(_sphere(self, Vector3(0.36 * side, body_height * 0.68, -0.15), 0.08, SKIN_COLOR))
	if head_anchor == null:
		_head_anchor = Node3D.new()
		_head_anchor.name = "HeadPivot"
		_head_anchor.position = Vector3(0.0, eye_height, 0.0)
		add_child(_head_anchor)
	else:
		_head_anchor = head_anchor
	# Head parts are placed relative to the eye line (the anchor's origin).
	head = _sphere(_head_anchor, Vector3(0.0, -0.05, 0.0), 0.2, SKIN_COLOR)
	brim = _cylinder(_head_anchor, Vector3(0.0, 0.14, 0.0), 0.24, 0.05, HAT_COLOR)
	hat = _cylinder(_head_anchor, Vector3(0.0, 0.32, 0.0), 0.17, 0.36, HAT_COLOR)
	_apply_shadow_mode()


## Shows or hides every part. The head parts live under the anchor, not under
## this node, so `visible` alone cannot hide them; this keeps `visible` in
## sync as well.
func set_parts_visible(on: bool) -> void:
	visible = on
	for mesh in _meshes:
		mesh.visible = on


func _apply_shadow_mode() -> void:
	var mode: GeometryInstance3D.ShadowCastingSetting = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if shadows_only
		else GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	for mesh in _meshes:
		mesh.cast_shadow = mode


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	return material


func _capsule(parent: Node3D, at: Vector3, radius: float, height: float, color: Color) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.material = _material(color)
	return _place(parent, mesh, at)


func _sphere(parent: Node3D, at: Vector3, radius: float, color: Color) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = _material(color)
	return _place(parent, mesh, at)


func _cylinder(parent: Node3D, at: Vector3, radius: float, height: float, color: Color) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.material = _material(color)
	return _place(parent, mesh, at)


func _place(parent: Node3D, mesh: Mesh, at: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = at
	parent.add_child(instance)
	_meshes.append(instance)
	return instance
