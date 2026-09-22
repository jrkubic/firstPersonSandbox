# firstPersonSandbox

A PEAK-style first-person cooking sandbox built on Godot 4.7. Currently contains
a solo vertical slice where a player cooks a fried egg and delivers it to the
pass.

## Status

- **Solo slice complete.** The cook loop (grab, cook, plate, deliver, respawn)
  runs end to end in the grey-box kitchen.
- **Backlog sweep done 2026-09-11:** crouch, grab assist, pan and plate rims,
  dedicated physics layers, `Groups` constants, `egg.seconds` overlay watch,
  plate-on-pan no longer re-cooks, per-spawner respawn under the kitchen root,
  `state_changed` listener, dot crosshair, and a 95-check headless smoke test
  (94 pass, 1 documented expected failure).
- **Next candidates:** recipe variety, art pass, co-op.

## How to run

Open the project in Godot 4.7 and press F5. The menu loads; click **Start Game**
to enter the kitchen.

## How to play (the cook loop)

1. Pick up the raw egg from the counter (E).
2. Walk up to the stove, keep the view roughly level, and press E again to
   drop the egg into the pan.
3. Wait ~4 seconds for it to cook. Color shifts white to golden as it progresses.
4. Pick up the pan or the cooked egg and transfer the egg onto a plate.
5. Place the plated meal onto the Pass counter — release the plate inside the
   delivery zone.
6. A fresh plate and egg respawn automatically. Repeat; after the third
   delivery the end screen shows your time and star rating.

## Controls

| Input    | Action                          |
|----------|---------------------------------|
| WASD     | Move                            |
| Mouse    | Look                            |
| Space    | Jump (not while crouched)       |
| Ctrl / C | Crouch (hold)                   |
| E        | Grab / release held item        |
| F        | Throw held item                 |
| Escape   | Pause menu (releases the mouse) |
| F3       | Toggle debug overlay            |

Grabbing is forgiving: if the centre dot narrowly misses a small item, a
short sphere sweep along the aim line (`grab_assist_radius`, default 0.12 m)
still picks it up, provided the item is in line of sight. Toggle it with
`grab_assist_enabled` on the `GrabController`.

## Debug overlay

Press F3 to toggle. Eight watched values:

- `held` — currently held body name, or `<none>`
- `crouched` — `true` while the player is crouched
- `egg.state` — `RAW` / `COOKING` / `COOKED` / `BURNED` (from the first food
  item found in the `food` group)
- `egg.seconds` — real seconds of heat the egg has received (`%.1fs`), from
  `FoodItem.cook_elapsed_seconds()`: `cook_duration` + `burn_duration` at
  BURNED (8.0s by default)
- `egg.progress` — the same value normalized 0..2 (0..1 is the cook phase,
  1..2 is the burn phase); this is what drives state and colour
- `pan.on_stove` — `true` / `false`
- `plate.contents` — comma-separated list of food items resting on the plate
- `order` — current order text from `OrderSystem`

## Automated smoke test

`tests/smoke_test.gd` loads the kitchen headless, drives the items by
teleporting them and asserts the whole loop — no editor, display or addons
needed. Run it with the Godot **console** build (`<Godot console exe>` is e.g.
`Godot_v4.7.2-stable_win64_console.exe`; `<project>` is the folder holding
`project.godot`, so `.` from the repo root):

```sh
"<Godot console exe>" --headless --path <project> --script res://tests/smoke_test.gd
```

It prints one `PASS` / `FAIL` / `XFAIL` line per check and a `SUMMARY` line,
takes about 25 s, and exits non-zero (`1`) if any check fails or the 180 s
watchdog trips. The 95 checks are:

- `boot.*` (5) — kitchen loads and is wired; exactly one egg, plate, pan and
  stove; egg `RAW`; pan on the stove; nothing held
- `cook.*` (5) — `RAW` to `COOKING` to `COOKED` at one 1/60 s tick per physics
  frame; a loose egg stays inside the rimmed pan
- `pause.*` (4) — progress freezes while the pan is off the stove and resumes
  when it returns
- `burn.*` (3) — `BURNED` after `cook_duration + burn_duration`; progress
  clamps at 2.0 and stays there
- `no_deliver_burned.*` (4) — a burned egg on a plate in the zone is rejected
  and nothing is freed
- `deliver.*` (8) — a cooked egg delivers; plate and egg are freed; one new
  plate and egg respawn under the `Kitchen` root and fill their spawner
  slots; `deliveries_made` counts
- `held_no_deliver.*` (6) — a plate in the `held` group never delivers; it
  delivers once released
- `grab.*` (12) — `interact` grabs the egg in front of the camera and `throw`
  releases it fast; with grab assist off an off-axis egg is missed, with it
  on the same aim grabs; an egg hidden behind the Pass counter cannot be
  grabbed through it
- `crouch.*` (8) — holding `crouch` lowers the head and shrinks the capsule
  with its bottom fixed; releasing restores both
- `plate_on_pan.*` (9) — a plated cooked egg set on the stove pan does not
  cook, and resumes once it leaves the plate
- `carry.*` (5) — a grabbed pan leaves the stove and stops cooking its egg;
  `carry.pan_keeps_egg` is an **expected failure** (the grab snap throws the
  egg out, see Known limitations)
- `grab.break_*` (4) — a held item past `break_distance` is dropped
- `release.*` (4) — standing at the stove with a level view, a released egg
  drops into the pan and cooks
- `throw.*` (3) — an egg thrown at a wall bounces instead of tunnelling out
- `crouch.blocked_*` (4) — a low ceiling keeps the player crouched until it
  is clear; a held item never does
- `held_egg.*` (4) — an egg held over a plate in the zone is not delivered
  until released
- `occupied.*` (6) — a delivery while a fresh egg still sits in its slot does
  not spawn a second one

Determinism notes, per-check details and how to add a check: `tests/README.md`.

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
10. Plate a cooked egg, then set the plate down on the pan while the pan is on
    the stove. `egg.seconds` must stay put and the egg must not burn.
11. Hold Ctrl (or C) next to an egg lying on the floor. The view drops from
    1.7 m to 1.1 m, the dot lands on the egg easily and E picks it up. Space
    does nothing while crouched.
12. Stay crouched and push into the north wall directly under the order board
    (the kitchen has no counter overhang; the board's underside at 1.9 m is
    the only low ceiling). Release Ctrl: `crouched` stays `true` until you
    back out from under the board, then you stand up.
13. Aim a hand's width beside the egg, not on it, and press E: it still
    grabs. Set `grab_assist_enabled` to `false` on the `GrabController` and
    repeat: the same aim misses.
14. Put the egg on the floor tight against the far side of the counter, stand
    on the near side and aim through the counter at the spot where you left
    it, then press E: nothing is grabbed, because the assist rejects an item
    the camera cannot see. (A dead-on hit with the precise centre ray can
    still grab through geometry — see Known limitations.)
15. Drop the egg in the pan, grab the pan and carry it around at a brisk walk.
    The egg stays inside the rim instead of rolling off. Hold the pan above
    the plate and look down to tilt it: the egg slides over the rim onto the
    plate.

## Project layout

- `scenes/` — `menu.tscn`, `kitchen.tscn`, `player.tscn`,
  `ui/{debug_overlay,hud,pause_menu,end_screen,score_popup}.tscn`,
  `items/{egg,pan,plate}.tscn`
- `scripts/` — `player.gd`, `menu.gd`, `groups.gd` (node-group name
  constants), `items/{food_item,pan,plate}.gd`,
  `systems/{grab_controller,stove_detector,cook_slot,food_container,order_system,delivery_zone,item_spawner,kitchen_loop}.gd`,
  `ui/{debug_overlay,order_board,hud,pause_menu,end_screen,score_popup}.gd`
- `tests/` — `smoke_test.gd` (the headless smoke test) and its `README.md`
- `docs/plans/` — the design doc and the implementation plan that drove this
  build; the plan ends with the post-slice backlog and its completion notes
- `docs/WALKTHROUGH.md` — quick inspect-and-debug guide: health checks,
  editor debug views, overlay values, symptom-to-cause table, probe template

## Known limitations (slice scope)

- Run state is minimal: a count-up timer, a fixed three-delivery goal and a
  star rating on the end screen; no fail state and no persistent score
- No customer NPCs or dining area
- Only one recipe (fried egg)
- Art is grey-box primitives only
- The automated smoke test is headless physics only — no rendering or visual
  regression coverage, so the manual smoke test above is still the net for
  anything you can see
- The precise grab ray queries only the `Items` layer, so a dead-on aim at an
  item hidden behind thin geometry can still grab it; only the grab-assist
  path checks line of sight
- Grabbing the pan with an egg in it throws the egg out: the grab controller
  snaps the pan's velocity in a single physics step (see `tests/README.md`,
  `carry.pan_keeps_egg`). Carry the egg separately for now.
- Releasing an item only reaches ~1.2 m ahead of the camera: walk up to the
  stove or rack and keep the view roughly level to drop food into the pan or
  onto the plate.
- Single player only; no networking

## Backlog

The post-slice backlog in `docs/plans/2026-04-13-cooking-game-foundation.md`
("Post-slice backlog") was swept on 2026-09-11; each bullet there keeps its
original text behind a **Done** note describing how it was closed. New items
go in the same list.

## Requirements

- Godot 4.7 (4.7.2 stable or later), Forward+ renderer
- Jolt Physics (already configured in `project.godot`)
