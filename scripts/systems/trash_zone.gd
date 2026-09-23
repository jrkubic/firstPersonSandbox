class_name TrashZone
extends Area3D
## Bins any grabbable item resting inside it. Authority only: it frees the
## item (the MultiplayerSpawner despawns it on clients) and asks the spawner
## that produced it (Node metadata "spawner_path") to spawn a replacement.
## Held items, and plates whose food is held, are left alone until released,
## the same rule DeliveryZone uses.

signal trashed(item_name: String)

var _inside: Array[RigidBody3D] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(_delta: float) -> void:
	if not NetSession.is_authority() or _inside.is_empty():
		return
	for body in _inside.duplicate():
		if not is_instance_valid(body) or body.is_queued_for_deletion():
			_inside.erase(body)
			continue
		if body.is_in_group(Groups.HELD) or _has_held_contents(body):
			continue
		_bin(body)


func _has_held_contents(body: RigidBody3D) -> bool:
	if body is Plate:
		for food in (body as Plate).get_contents():
			if is_instance_valid(food) and food.is_in_group(Groups.HELD):
				return true
	return false


func _on_body_entered(body: Node) -> void:
	if body is RigidBody3D and body.is_in_group(Groups.GRABBABLE) and not _inside.has(body):
		_inside.append(body)


func _on_body_exited(body: Node) -> void:
	if body is RigidBody3D:
		_inside.erase(body)


func _bin(body: RigidBody3D) -> void:
	_inside.erase(body)
	var spawner_path: NodePath = body.get_meta(&"spawner_path", NodePath()) as NodePath
	var spawner: ItemSpawner = get_node_or_null(spawner_path) as ItemSpawner if not spawner_path.is_empty() else null
	trashed.emit(body.name)
	body.queue_free()
	if spawner != null:
		spawner.replace(body)
