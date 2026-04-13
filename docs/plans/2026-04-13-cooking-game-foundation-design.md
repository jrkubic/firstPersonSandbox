# Cooking Game Foundation — Design

**Date:** 2026-04-13
**Project:** firstPersonSandbox
**Status:** Approved

## Scope & pillars

A solo vertical slice of a first-person cooking game in the style of PEAK.
The player stands in a four-object grey-box kitchen, picks up a raw egg,
drops it in a pan on a stove, waits for it to cook, puts it on a plate, and
delivers the plate to the pass. A fixed "1× Fried Egg" ticket is always
visible on the wall; delivering resets the ticket. No timer, no score, no
customer NPC, no multiplayer. Art is pure primitives.

Every system is built with PEAK-style physics chaos in mind: held items
stay rigidbodies, bump into the world, can be knocked out of the player's
hand, and can be thrown. This is the foundation that makes every later
mode (co-op, VS, more recipes) feel consistent.

**Pillars confirmed:** co-op chaos, stylized/flat look, physics-driven
interaction, time/resource pressure, emergent silliness. For the slice,
only physics-driven interaction is implemented — the rest are design
constraints, not slice features.

## Scene & node architecture

```
Menu (scenes/menu.tscn)           ← already exists, unchanged
 └─ Start Game → Kitchen

Kitchen (scenes/kitchen.tscn)     ← replaces/renames world.tscn
├── WorldEnvironment
├── DirectionalLight3D
├── Room (StaticBody3D)           ← 4 walls + floor + ceiling as box meshes
├── Counter (StaticBody3D)
│    └── EggCrateSpawner (Node3D)
├── Stove (StaticBody3D)
│    └── Pan (RigidBody3D, frozen)
│         ├── CookSlot (Area3D)
│         └── StoveDetector (Area3D)
├── PlateRack (StaticBody3D)
│    └── PlateSpawner (Node3D)
├── Pass (StaticBody3D)
│    └── DeliveryZone (Area3D)
├── OrderBoard (StaticBody3D)     ← Label3D reads OrderSystem.current_order
└── Player (instance of player.tscn)
     └── Head → Camera3D → GrabController + HoldTarget
```

**Interactables (physics items, all RigidBody3D in `grabbable` group):**
- **Egg** — `FoodItem` script. States: `RAW → COOKING → COOKED → BURNED`.
  Albedo lerps white → golden → black as feedback.
- **Pan** — `freeze = true` by default, unfrozen when grabbed. Has
  `CookSlot` (watches for food) and `StoveDetector` (watches for stove
  contact) as Area3D children.
- **Plate** — `FoodContainer` script. Area3D on top surface tracks food
  resting on the plate via physics (no parenting, no welding).

**Static placeholders:** Counter, Stove, PlateRack, Pass, OrderBoard, Room
— all `StaticBody3D` with `BoxMesh` + `BoxShape3D`. Different albedo
colors for readability.

## Core systems

### GrabController (on player's camera)

A `Node3D` child of `Camera3D` that handles pick-up / hold / release /
throw.

- **Pick up:** On `interact`, raycast ~2m forward from camera. If hit body
  is in `grabbable` group and nothing is held, create a
  `Generic6DOFJoint3D` between player and the hit body.
- **Hold:** `HoldTarget` is a child of Camera3D at a fixed offset
  `(0.35, -0.35, -0.6)` in camera-local space — bottom-right of screen,
  like a held object. The joint pulls the body toward `HoldTarget` with
  strong linear springs and moderate angular springs. The body floats in
  front of the player but can still be shoved by collisions.
- **Release:** On `interact` again, or automatically if joint separation
  exceeds `break_distance` (default 1.5m), destroy joint. Item falls.
- **Throw:** On `throw`, destroy joint and apply camera-forward impulse.

**Exports for tuning:**
- `hold_offset: Vector3` default `(0.35, -0.35, -0.6)`
- `hold_hand: enum { RIGHT, LEFT }` — flips X sign
- `hold_linear_stiffness` / `hold_angular_stiffness`
- `break_distance: float`
- `throw_impulse: float`

**New input actions** (added to `project.godot`):
- `interact` — E
- `throw` — F (or left mouse)

**Known limitation (TODO, not slice work):** Large items like the pan
held at the same offset will look huge on screen. Per-item hold offsets
come later.

### FoodItem (on the egg)

Script on the egg RigidBody3D. Owns cook state.

- `state: Enum { RAW, COOKING, COOKED, BURNED }`
- `cook_progress: float` (0.0 → 1.0 cooked → 2.0 burned)
- `recipe_tag: String` (e.g. `"egg"`)
- `tick_cook(delta)` advances `cook_progress` while being called from
  outside. Transitions state at thresholds.
- Lerps a `StandardMaterial3D.albedo_color` for visual feedback.
- Emits `state_changed(new_state)` on transitions.

### CookSlot (Area3D child of the pan)

- Tracks `FoodItem` bodies currently inside.
- Each physics frame, if parent pan's `StoveDetector` reports on-stove,
  calls `food.tick_cook(delta)` for each food inside.
- When food leaves, stops ticking. Food keeps whatever state it had.

All cook logic lives in `FoodItem`. CookSlot is just a "please keep
cooking this" signal.

### FoodContainer (on the plate)

- `Area3D` on top surface tracks food resting on plate.
- Exposes `get_contents() -> Array[FoodItem]`.
- No parenting. Food rides the plate via physics — if player turns too
  fast, food slides off. Intentional.

### OrderSystem + DeliveryZone

- **OrderSystem** — node on Kitchen scene. Holds
  `current_order = { recipe: "fried_egg", count: 1 }`. Exposes
  `check_delivery(plate) -> bool` which inspects plate contents.
- **DeliveryZone** — Area3D on the Pass. On `body_entered`, if body has
  the `FoodContainer` (Plate) script and `OrderSystem.check_delivery`
  passes, queue_free the plate + its food, call `PlateSpawner.spawn()`,
  play placeholder SFX. Order never changes for the slice.
- **OrderBoard** — `Label3D` reading `OrderSystem.current_order`.
  Coupling exists for future variety even though text is static now.

### Spawners

- **EggCrateSpawner** — spawns a fresh egg when the previous one is
  picked up, so there's always one available.
- **PlateSpawner** — spawns a clean plate after each successful delivery.

Both are `Node3D`s with a `PackedScene` export and a last-spawned
reference.

## Data flow (one full loop)

1. Player enters kitchen. One RAW egg on counter, one clean plate on
   rack, pan on stove, order board shows "1× Fried Egg".
2. Player looks at egg, presses `interact`. GrabController raycasts, hits
   egg, creates joint. Egg floats at HoldTarget (bottom-right).
3. Player walks to stove. Egg swings slightly behind — physics joint.
4. Player aims at pan and presses `interact` again. Joint destroyed. Egg
   drops. If it lands in pan's CookSlot and pan's StoveDetector reports
   on-stove, CookSlot starts calling `egg.tick_cook(delta)`.
5. After ~1 second, egg goes `RAW → COOKING → COOKED`. Albedo lerps
   white → golden.
6. Player grabs the pan (unfreezes, jointed to player). Cooked egg loose
   inside.
7. Player tips pan over plate. Egg slides out, lands on plate.
   FoodContainer Area3D sees it and adds to contents. Player releases
   pan.
8. Player grabs plate. Egg rides via physics.
9. Player walks plate to pass. DeliveryZone detects plate, calls
   `OrderSystem.check_delivery`, passes.
10. Plate + egg queue_freed. New plate spawned. Order unchanged. Loop
    resets.

**Failure modes handled by this flow with no extra code:**
- Dropped egg on floor — still RAW, pick it up again.
- Burned egg — delivery check fails, plate bounces off zone.
- Pan carried off stove mid-cook — stove detector clears, ticks stop.
- Egg dropped into pan while pan is off stove — nothing ticks.

## Edge cases

1. **Double-grab** — prevented by `held_body` reference; second
   `interact` means release.
2. **Grabbing static bodies** — raycast filters by `grabbable` group.
3. **Joint stretches too far** — break at `break_distance` (default
   1.5m).
4. **Bad egg spawn position** — fixed spawn point above crate with small
   upward velocity. Revisit only if it breaks.
5. **Falling off world** — sealed box room prevents it. Killzone added
   only when world opens up.
6. **DeliveryZone triggered by egg/pan** — type-check: only reacts to
   Plate script.
7. **Food already on plate when plate is grabbed** — handled naturally
   by physics.
8. **Pan grabbed mid-cook** — CookSlot moves with pan, StoveDetector
   clears, ticking stops. Food paused in place.

## Non-goals (slice)

- No save/load.
- No pause menu beyond Escape releasing mouse.
- No settings screen (mouse sensitivity exported on Player).
- No networking / authority.
- No respawn flow.
- No score, no timer, no customer NPC, no dining area.
- No recipe variety.
- No sound design beyond a placeholder ding.

## Testing approach

Godot has no first-party unit test framework. Physics-heavy gameplay
slice makes unit tests either useless (too much mocking) or overkill
(headless physics scenes). For this slice:

1. **Manual smoke test checklist** in README — numbered walk-through of
   the full loop. Run after any meaningful change.
2. **Debug overlay** (F3 toggle) — Label on CanvasLayer showing
   `held_body`, `egg.state`, `egg.cook_progress`, `pan.on_stove`,
   `OrderSystem.current_order`. Fastest way to catch physics bugs.
3. **Isolated test scenes** created reactively when something breaks —
   `test_grab.tscn`, `test_cook.tscn`. Not built preemptively.

Revisit automated testing once the loop has regression-worthy
complexity (multiple recipes, scoring, co-op sync).
