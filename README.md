# firstPersonSandbox

A PEAK-style first-person cooking sandbox built on Godot 4.6. Currently contains
a solo vertical slice where a player cooks a fried egg and delivers it to the
pass.

## How to run

Open the project in Godot 4.6 and press F5. The menu loads; click **Start Game**
to enter the kitchen.

## How to play (the cook loop)

1. Pick up the raw egg from the counter (E).
2. Drop it onto the pan (E again while aimed at the pan to release).
3. Wait ~4 seconds for it to cook. Color shifts white to golden as it progresses.
4. Pick up the pan or the cooked egg and transfer the egg onto a plate.
5. Place the plated meal onto the Pass counter — release the plate inside the
   delivery zone.
6. A fresh plate and egg respawn automatically. Repeat.

## Controls

| Input  | Action                        |
|--------|-------------------------------|
| WASD   | Move                          |
| Mouse  | Look                          |
| Space  | Jump                          |
| E      | Grab / release held item      |
| F      | Throw held item               |
| Escape | Toggle mouse capture          |
| F3     | Toggle debug overlay          |

## Debug overlay

Press F3 to toggle. Six watched values:

- `held` — currently held body name, or `<none>`
- `egg.state` — `RAW` / `COOKING` / `COOKED` / `BURNED` (from the first food
  item found in the `food` group)
- `egg.progress` — normalized 0..2 cook progress (0..1 is the cook phase, 1..2
  is the burn phase)
- `pan.on_stove` — `true` / `false`
- `plate.contents` — comma-separated list of food items resting on the plate
- `order` — current order text from `OrderSystem`

## Manual smoke test

Run this after any meaningful change to verify the slice end-to-end.

1. Load the kitchen scene. Confirm: egg on the counter, plate on the plate
   rack, pan on the stove, order board reads `1x egg(COOKED)`, F3 toggles the
   debug overlay, crosshair is visible.
2. Grab the egg, drop it in the pan. Watch `egg.state` progress from `RAW` to
   `COOKING` to `COOKED` over ~4 seconds.
3. Keep waiting. Watch it continue to `BURNED` over another ~4 seconds.
4. Lift the pan off the stove mid-cook. Confirm `egg.progress` pauses while
   `pan.on_stove` is `false`, and resumes when the pan is returned.
5. Plate a cooked egg and deliver it by setting the plate down inside the
   delivery zone on the Pass counter.
6. Verify a fresh plate and egg respawn after delivery.
7. Throw (F) an egg into a wall. It should bounce, not tunnel through.
8. Try to deliver a burned or raw egg on a plate. No delivery should fire;
   the plate stays where it is.
9. Carry a held plate through the delivery zone without releasing it. It must
   NOT deliver while held.

## Project layout

- `scenes/` — `menu.tscn`, `kitchen.tscn`, `player.tscn`,
  `ui/debug_overlay.tscn`, `items/{egg,pan,plate}.tscn`
- `scripts/` — `player.gd`, `menu.gd`,
  `items/{food_item,pan,plate}.gd`,
  `systems/{grab_controller,stove_detector,cook_slot,food_container,order_system,delivery_zone,item_spawner,kitchen_loop}.gd`,
  `ui/{debug_overlay,order_board}.gd`
- `docs/plans/` — the design doc and the implementation plan that drove this
  build

## Known limitations (slice scope)

- No score, timer, or run/fail state
- No customer NPCs or dining area
- Only one recipe (fried egg)
- Art is grey-box primitives only
- No automated tests (the manual smoke test above is the regression net)
- Pan and plate have flat disk collision; food rolls off when picked up
- Single player only; no networking

## Backlog

Post-slice tuning, polish, and multiplayer items are tracked in
`docs/plans/2026-04-13-cooking-game-foundation.md` under "Post-slice backlog".

## Requirements

- Godot 4.6, Forward+ renderer
- Jolt Physics (already configured in `project.godot`)
