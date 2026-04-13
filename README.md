# firstPersonSandbox

A minimal Godot 4.6 sandbox for first-person games. Derived from
[ThirdPersonFoundation](https://github.com/jrkubic/ThirdPersonFoundation) and
adapted to a first-person camera rig. Starting point for experimenting with
first-person mechanics — FPS, exploration, immersive sim, etc.

## What's included

### Player controller — `scripts/player.gd`
A `CharacterBody3D` with:
- WASD movement relative to look direction
- Mouse-look: yaw on the body, pitch on the `Head` node (clamped ±85°)
- Space to jump, Escape to toggle mouse capture
- Gravity, ground friction, and reduced air control
- Uses the engine's built-in `velocity` and `move_and_slide()`

### Player scene — `scenes/player.tscn`
Instanceable first-person rig:
- `CharacterBody3D` root with capsule `CollisionShape3D`
- `Skin` capsule mesh, hidden from the player's own camera (`visible = false`)
  but still casts shadows (`cast_shadow = shadows only`) so the player sees
  their own shadow on the ground
- `Head` Node3D at eye height (~1.7m) — this is what pitches up/down
- `Camera3D` parented directly to `Head` with 90° FOV

### World scene — `scenes/world.tscn`
A blank level to drop the player into:
- `WorldEnvironment` with procedural sky
- `DirectionalLight3D` with shadows
- 60×60 ground `StaticBody3D`
- Instanced `Player` spawned above the ground

### Menu — `scenes/menu.tscn` + `scripts/menu.gd`
Title screen that's the game's main scene:
- **Start Game** → loads `scenes/world.tscn`
- **Quit** → exits

### Input map (`project.godot`)
- `move_forward` / `move_back` / `move_left` / `move_right` — WASD
- `jump` — Space
- `toggle_mouse_captured` — Escape

## Adjusting the camera

First person has no SpringArm — the camera is a direct child of `Head`, so:
- **Eye height** — change the Y in `Head` transform (`scenes/player.tscn`)
- **FOV** — `Camera3D.fov` (90° is a common FPS starting point)
- **Pitch range** — `min_pitch` / `max_pitch` exports on the Player node
- **Sensitivity** — `mouse_sensitivity` export on the Player node

## Requirements

- Godot 4.6 (Forward+ renderer)
- Uses Jolt Physics (configured in `project.godot`)
