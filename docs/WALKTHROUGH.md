# Inspect & debug walkthrough

A 10-minute path from "what state is this repo in?" to "why is the egg not
cooking?". Commands are for Git Bash on Windows; set these two variables
first in every new shell:

```bash
G="/c/Users/Jake/Downloads/Godot_v4.7.2-stable_win64/Godot_v4.7.2-stable_win64_console.exe"
P="C:/Projects/firstPersonSandbox"
```

---

## 1. Where are we? (2 min)

```bash
git -C "$P" status --short | grep -v '\.uid$'   # what is uncommitted
git -C "$P" log --oneline origin/main..HEAD | wc -l   # local commits not pushed
```

As of 2026-09-11:

- The whole post-slice backlog is implemented but **uncommitted**. The
  untracked `*.gd.uid` files belong with their scripts; commit them together.
- 44 older local commits have never been pushed.
- Status summary lives in `README.md` → **Status**. The backlog, with a
  `Done` note per item and the remaining open bug, is at the end of
  `docs/plans/2026-04-13-cooking-game-foundation.md`.

## 2. Is it healthy? (1 min)

Run the three checks. All must be quiet except the smoke test summary.

```bash
"$G" --headless --path "$P" --import 2>&1 | grep -iE "error|parse"          # expect no output
"$G" --headless --path "$P" --quit-after 60 res://scenes/kitchen.tscn 2>&1 | grep -v "^Godot Engine"   # expect no output
"$G" --headless --path "$P" --script res://tests/smoke_test.gd 2>&1 | grep -v "^PASS"; echo "rc=${PIPESTATUS[0]}"
```

Expected smoke output today:

```
XFAIL carry.pan_keeps_egg: ...
SUMMARY: 94 passed, 0 failed, 1 xfailed
rc=0
```

How to read it:

- `FAIL <name>: <detail>` is a regression. The name maps to a check group in
  `tests/README.md`; the detail prints the measured values.
- `FAIL summary.count` means a check group **aborted** (a script error inside
  it). Scroll up for the `SCRIPT ERROR` line; that is the real bug.
- `XFAIL` is a known, documented bug. If it ever prints
  `(expected failure now passes)`, switch that check from `_xfail` to `_check`.
- The run takes about 30 s because headless physics still runs in real time.
  A hang past 180 s trips the watchdog and exits 1.

## 3. Look at it running (3 min)

Open the project in Godot 4.7.2 and press **F5**, then **Start Game**. Turn
on these editor aids before or while it runs:

| Where | What it shows |
|-------|---------------|
| **Debug → Visible Collision Shapes** | Rim segments, handle, CookSlot / FoodContainer / DeliveryZone boxes. The fastest way to see why something does not overlap. |
| **Scene dock → Remote** (while running) | The live tree. Spawned eggs and plates appear directly under `Kitchen`. Click a node to read `cook_progress`, `containers`, `sleeping`, `linear_velocity` in the Inspector. |
| **Debugger → Errors** | Runtime errors and warnings with the GDScript line. |
| **Debugger → Monitors** | Physics active objects and FPS; useful if items jitter or tunnel. |

In game, press **F3** for the overlay. Watch these while you play the loop:

| Step | Watch | Healthy value |
|------|-------|---------------|
| Grab egg (E) | `held` | `Egg` |
| Drop in pan at the stove, view level | `egg.state`, `egg.seconds` | `COOKING`, climbing 1.0s per second |
| Lift pan off stove | `pan.on_stove`, `egg.seconds` | `false`, frozen |
| Egg done | `egg.state` | `COOKED` at 4.0s, `BURNED` at 8.0s |
| Put egg on plate | `plate.contents` | `egg(COOKED)` |
| Set plate on the Pass | `order`, HUD counter | counter +1, new plate and egg spawn |
| Hold Ctrl / C | `crouched` | `true`; stays `true` under the order board until you back out |

Controls: WASD move, mouse look, Space jump, Ctrl/C crouch, E grab/release,
F throw, Escape pause, F3 overlay.

## 4. Symptom → cause → file

| Symptom | Check first | Likely cause | Look in |
|---------|-------------|--------------|---------|
| Egg never starts cooking | `pan.on_stove` | Pan not overlapping the stove, or the stove lost its `stove` group | `scripts/systems/stove_detector.gd`, `scenes/kitchen.tscn` (Stove `groups=["stove"]`) |
| `pan.on_stove` true but egg stuck `RAW` | Collision shapes view | Egg landed on the stove top, not in the CookSlot box. Stand right at the stove and keep the view level; the hold point is 1.2 m ahead | `HoldTarget` in `scenes/player.tscn` |
| Plated egg sitting on the pan does not cook | `plate.contents` | By design: food on a plate is served, not cooking | `CookSlot` skips `FoodItem.is_contained()` |
| Plate on the Pass does not deliver | `plate.contents`, `held` | Egg not exactly `COOKED`, wrong count, or plate/egg still in `held` | `scripts/systems/order_system.gd`, `delivery_zone.gd` |
| E does nothing | `held` | Item not on layer 3 (Items), not in `grabbable`, out of `grab_range` (4 m), or a wall blocks line of sight | `scripts/systems/grab_controller.gd` |
| Egg flies out when grabbing the pan | — | **Known open bug** (the grab snaps the pan's velocity). Carry the egg separately | Plan backlog, `tests/README.md` → `carry.pan_keeps_egg` |
| Stuck crouched | `crouched` | Ceiling over the standing capsule (order board underside is 1.9 m) | `Player._has_stand_clearance()` |
| No new egg or plate after delivery | Remote tree | Previous item still within `slot_radius` (0.35 m) of its spawner, so the slot counts as full | `ItemSpawner.is_slot_free()`, `kitchen_loop.gd` |
| Item falls through a counter or floor | Remote → `collision_mask` | Items need mask 7 (World + Player + Items) | `scenes/items/*.tscn` |
| Egg hangs in mid-air | Remote → `sleeping` | Should not happen (`can_sleep = false` on food); if it does, something reset it | `scripts/items/food_item.gd` |

Physics layers for reference:

| Layer | Bit | On it | Masks |
|-------|-----|-------|-------|
| 1 World | 1 | Room, counters, stove, pass, board | — |
| 2 Player | 2 | Player | 5 (World, Items) |
| 3 Items | 4 | Egg, pan, plate | 7 (World, Player, Items) |
| 4 Detection | 8 | nothing (reserved) | StoveDetector 1; CookSlot, FoodContainer, DeliveryZone 4 |

## 5. Reproduce a bug headless (probe template)

When something is hard to see by playing, script it. Save outside the repo
(for example `C:/Users/Jake/AppData/Local/Temp/probe.gd`) and run:

```bash
"$G" --headless --path "$P" --script "C:/Users/Jake/AppData/Local/Temp/probe.gd"
```

```gdscript
extends SceneTree

func _initialize() -> void:
	_run()

func _run() -> void:
	Engine.physics_ticks_per_second = 60
	var k: Node3D = load("res://scenes/kitchen.tscn").instantiate()
	root.add_child(k)
	current_scene = k                       # HUD popups need a current scene
	for i in range(30): await physics_frame  # let deferred spawns settle
	var egg := get_first_node_in_group("food") as FoodItem
	var pan := get_first_node_in_group("pan") as Pan
	# Put the egg in the pan and watch it cook for 1 second of physics.
	egg.global_position = pan.global_position + Vector3(0, 0.15, 0)
	egg.linear_velocity = Vector3.ZERO
	for i in range(60): await physics_frame
	print("on_stove=%s state=%s seconds=%.2f" % [pan.is_on_stove(), egg.state_name(), egg.cook_elapsed_seconds()])
	quit(0)
```

Tips:

- Count time in `physics_frame`s, never wall time; results are then
  repeatable.
- Simulate keys with `Input.parse_input_event(InputEventAction)`: set
  `action = "interact"`, `pressed = true`, send, then send a released copy.
  `tests/smoke_test.gd` has `_press_action()` and `_set_action()` to copy.
- Once a probe proves a bug, turn it into a check in `tests/smoke_test.gd`
  and bump `EXPECTED_CHECKS`. See `tests/README.md` → **Adding a check**.

## 6. Where to go next

- **Open bug:** grab-snap throws the egg out of a lifted pan. Needs a
  hands-on feel pass in `GrabController._physics_process`; candidate fixes
  are listed in the plan backlog.
- **Feel decisions to confirm by playing:** the new hold point
  `(0.15, -0.3, -1.2)`, crouch on Ctrl/C, grab assist radius 0.12 m.
- **Then:** commit the sweep, push, and pick from recipe variety, an art
  pass, or co-op (README → Status).
