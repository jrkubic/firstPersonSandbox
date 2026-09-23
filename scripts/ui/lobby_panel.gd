extends CanvasLayer
## Top-right roster: mode and who is in the kitchen. Hidden offline.

@onready var label: Label = $Label

var _net: KitchenNet


func _ready() -> void:
	_net = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	visible = NetSession.is_online()
	NetSession.peers_changed.connect(_refresh)
	if _net:
		_net.mode_changed.connect(func(_m: KitchenNet.Mode) -> void: _refresh())
	_refresh()


func _refresh() -> void:
	visible = NetSession.is_online()
	if not visible or _net == null:
		return
	var lines: Array[String] = []
	lines.append("PRACTICE  (host: Esc > Start Run)" if _net.is_practice() else "RUN")
	var ids: Array = NetSession.peer_names.keys()
	ids.sort()
	for id: int in ids:
		var tag: String = " (host)" if id == 1 else ""
		lines.append("%s%s" % [NetSession.peer_names[id], tag])
	label.text = "\n".join(lines)
