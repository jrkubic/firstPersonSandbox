# Tests

## Headless smoke test

`tests/smoke_test.gd` is a `SceneTree` entry point that loads
`tests/smoke_test_body.gd`, a `Node` holding the checks, once the autoloads
exist (a `--script` MainLoop is compiled before them, and any `class_name`
script it types that names `NetSession` would fail to compile). The body
loads `scenes/kitchen.tscn` headless, drives the physics items by teleporting
them, and asserts the whole cook loop end to end. No addons, no editor, no
display needed.

Run from the project root (Windows console binary shown; any Godot 4.7
binary works):

```sh
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/smoke_test.gd
```

Output is one line per check — `PASS <name>`, `FAIL <name>: <detail>` or
`XFAIL <name>: <detail>` — followed by a `SUMMARY: N passed, N failed, N
xfailed` line. The process exits with code `0` when no non-expected check
failed and `1` otherwise. A 180 s wall-clock watchdog fails the run if the
coroutine ever stalls (for example after a script error inside a check).

Physics runs at a fixed 60 ticks/s and every wait is counted in physics
frames (`await physics_frame`), so the number of cook ticks an egg receives
between two assertions is deterministic. Wall time is about 25 s because
headless physics still advances in real time.

### What each check covers

| Check group | What it asserts |
|-------------|-----------------|
| `boot.*` | Kitchen loads; `Pass/DeliveryZone`, `KitchenLoop`, `OrderSystem`, both `ItemSpawner`s, the camera and `GrabController` are wired; after the deferred spawns settle there is exactly one egg (`food`), one plate, one pan and one stove; the egg is `RAW` at progress 0; the pan reports `is_on_stove()`; nothing is held. The debug overlay is switched on for the whole run so its watch Callables execute headless (including the "no egg / no plate" branches during respawn). |
| `cook.*` | Egg dropped into the pan on the stove goes `RAW -> COOKING` within 10 frames. `cook.egg_stays_in_pan` watches the egg unassisted for 90 frames: it must still be inside the pan's rim (under 0.2 m off-axis) and must have gained the full 90 ticks of `cook_progress` (see below). Then, while "stirring" (re-centring the egg in the pan every 20 frames if it drifted), the egg reaches `COOKED` and the number of physics frames matches the remaining `cook_duration` exactly (one 1/60 s tick per physics frame, +10/-2 frames tolerance). |
| `pause.*` | Pan (with the egg) teleported onto the counter: `is_on_stove()` becomes false and `cook_progress` does not move for 60 frames. Pan returned to the stove: `is_on_stove()` true again and progress advances. |
| `burn.*` | Cooking continues past `cook_duration + burn_duration`: state becomes `BURNED`, `cook_progress` clamps at exactly 2.0 and stays there. |
| `no_deliver_burned.*` | The burned egg placed on the plate, plate placed inside the delivery zone on the Pass: the plate's `FoodContainer` reports the egg, `OrderSystem.check_delivery` rejects it, `DeliveryZone.delivered` does not fire in 30 frames, and plate and egg are still alive. |
| `deliver.*` | The burned egg is binned (`queue_free`), a fresh egg is spawned with `EggSpawner.spawn()`, cooked to `COOKED` in the pan and placed on the plate already in the zone: `delivered` fires within 30 frames, plate and egg are freed, `KitchenLoop` respawns exactly one new plate and one new `RAW` egg, both parented to the `Kitchen` root (not `Counter` / `PlateRack`), both spawners report their slot as occupied (`is_slot_free()` false), and `deliveries_made == 1`. |
| `held_no_deliver.*` | The respawned plate is put in the `held` group and placed in the zone with a freshly cooked egg: no delivery for 30 frames and the plate survives. Removing it from `held` delivers within 30 frames and `deliveries_made == 2`. (The delivery goal is 3, so the run never reaches the WON state, which would pause the tree.) |
| `grab.*` | The respawned egg is teleported 1 m in front of the player camera. An `InputEventAction("interact")` press/release is fed through `Input.parse_input_event`, which headless still routes to `GrabController._unhandled_input`: `is_holding()` is true, `held_body_name()` matches the egg, and the egg is in `held`. An `InputEventAction("throw")` then releases it with `linear_velocity.length() > 5` and clears `held`. With `grab_assist_enabled = false` an egg 0.15 m off the aim line is missed; with assist on it is grabbed (`grab.assist_*`). `grab.through_wall_blocked`: the egg frozen just outside the north wall, aimed at dead-on, is not grabbed by either the ray or the assist. |
| `carry.*` | The pan (with the egg from `plate_on_pan`) is grabbed through `interact` from 1.5 m: it leaves the stove, `cook_progress` stops once `is_on_stove()` is false. **Expected failure** `carry.pan_keeps_egg`: the egg is thrown out of the pan the frame it is grabbed (see below). |
| `release.*` | Standing pressed against the stove with a level view, an egg released from the hold point drops into the pan's `CookSlot` and cooking resumes. Guards the `HoldTarget` offset. |
| `throw.*` | An egg thrown at the north wall from 2.2 m never crosses the wall plane (egg `continuous_cd`). |
| `grab.break_*` | A held egg teleported past `break_distance` from the hold target is released and leaves `held`. |
| `crouch.blocked_*` | Standing up is refused under a temporary 1.5-1.7 m ceiling slab, allowed once it is freed, and never blocked by a body in the `held` group. |
| `held_egg.*` | A cooked egg in the `held` group on a plate in the zone is not delivered; releasing it delivers (`delivery_goal` is raised to 10 first so the run never reaches WON). |
| `occupied.*` | A separately instantiated egg is cooked and delivered while the respawned egg still sits in the spawner slot: no second egg is spawned, the slot stays occupied, the plate respawns. |
| `crouch.*` | Holding `crouch`: `is_crouched()`, the Head drops toward `crouch_height_offset`, the capsule shrinks to `crouch_capsule_height` with its bottom staying on the floor. Releasing: stands up, Head and capsule restored. |
| `plate_on_pan.*` | A freshly cooked egg is plated and the plate is set down on the pan while the pan is on the stove. The plate's `FoodContainer` reports the egg (`is_contained()`), the pan's `CookSlot` still overlaps it (`has_food()`), yet `cook_progress` does not move for 120 frames and the state stays `COOKED`; the egg is still in both volumes afterwards, so the freeze is due to containment rather than the egg escaping. Moving the plate away and dropping the egg back in the pan clears containment and progress resumes. |

### `carry.pan_keeps_egg` (expected failure)

`GrabController` sets the held body's linear and angular velocity in one
step (up to 20 m/s / 20 rad/s) on the frame it is grabbed, so a pan grabbed
off the stove hits the egg resting in it like a bat and throws it out; the
rim cannot help because the impulse comes from the disc itself. A 2026-09-11
probe with real physics tried `continuous_cd` on the pan (worse: the swept
rim launches the egg 5 m), acceleration ramps of 20-80 m/s^2 and speed caps
down to 5 m/s / 4 rad/s; every variant still lost the egg at one or more
grab distances (1.2 / 1.5 / 2.0 m). The fix is a feel pass on the grab
controller (impulse-limited pull, or briefly parenting/freezing contents to
the pan while it accelerates), then flip this `_xfail` back to `_check`.

### `cook.egg_stays_in_pan` and stirring

The pan's handle collision cylinder does not reach down to the stove top
(pan disc bottom is at local y = -0.04, the handle's underside at -0.025),
so with the pan resting on its disc the handle end hangs in the air and the
body used to settle at a slight pitch (the collision is now lowered so its underside is flush with the disc bottom). A free egg on that surface rolls toward the
handle. Before the pan had a rim this carried the egg out of the `CookSlot`
volume after about 80 frames and stalled `cook_progress` (the check used to
be an expected failure). The 12 rim wall segments on the pan now stop the
egg at about 0.17-0.18 m off-axis, inside both the disc and the `CookSlot`
box, so it keeps cooking; the check asserts exactly that. The later checks
still "stir" (re-centre the egg every 20 frames) so the plate-on-pan and
delivery flows do not depend on where the egg comes to rest.

### Adding a check

Write an `async` function that awaits `_step(n)` / `_wait_until(pred, n)` /
`_cook_until(...)`, call `_check(name, condition, detail)` for each
assertion, and call it from `_run()`. Never rely on wall time — count physics
frames. Use `_xfail` only for a documented gameplay bug that a later task is
expected to fix.
