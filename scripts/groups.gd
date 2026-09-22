class_name Groups
extends RefCounted
## Central registry of node group names used across the kitchen.
##
## Systems find each other through groups (grab raycast, cook ticking,
## delivery checks, debug watches). Use these constants instead of raw
## strings so a typo fails at parse time rather than silently at runtime.
## Scene files still list the same names as data (e.g. groups=["stove"]).

const GRABBABLE: StringName = &"grabbable"
const FOOD: StringName = &"food"
const PLATE: StringName = &"plate"
const PAN: StringName = &"pan"
const STOVE: StringName = &"stove"
const HELD: StringName = &"held"
const DEBUG_OVERLAY: StringName = &"debug_overlay"
const SPAWNER: StringName = &"spawner"
const KITCHEN_NET: StringName = &"kitchen_net"
