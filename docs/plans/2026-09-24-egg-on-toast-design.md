# Egg on Toast — Design

**Date:** 2026-09-24
**Project:** firstPersonSandbox
**Status:** Approved
**Builds on:** co-op (`2026-09-22-coop-multiplayer-design.md`), kitchen QoL (trash can, walk).

## Why

The practice area and level 1 need more to do. The first step is a second
recipe that reuses the existing cook model while forcing the two foundations
every later station needs: recipes as data, and an order system that picks
from a list. Brainstorm outcome: egg on toast first, chopped salad next.

## Decisions

| Question | Decision |
|----------|----------|
| Second recipe | Egg on Toast: one cooked egg + one slice of toast on the plate |
| Orders | One ticket at a time, drawn at random from the recipe list after each delivery; no queue, no expiry (later: expiry + fail state) |
| Recipe data | `Recipe` resource: `id`, `ticket` text, `ingredients` (tags). Every ingredient must be present exactly once and `COOKED`; extras or burned food reject the plate |
| Bread | A second `FoodItem` (`recipe_tag = "bread"`, 3 s cook / 3 s burn, beige → brown → charcoal). Raw reads as bread, cooked as toast |
| Toaster | Static station on a new counter north of the stove: box body, a rim so slices stay on top, and two side-by-side `CookSlot`s that are always hot. Toast starts the moment a slice lands and burns if left |
| Bread supply | A bread spawner on the toaster counter, refilled like eggs (delivery refill, trash replace) |
| Plating | Unchanged: the plate's `FoodContainer` lists what rests on it; no stacking order |
| Networking | Nothing new: bread replicates like eggs, toaster slots tick on the host, `OrderSystem.current_index` replicates `on_change` and rides the late-join full-state RPC |
| Determinism | `OrderSystem.randomize_orders` (default on). Tests turn it off and set the recipe explicitly with `set_current(index)` |

## Changes by system

- **`CookSlot`** loses its hard dependency on a `Pan`: `pan_path` optional,
  new `always_hot` export. Heating = `always_hot or pan.is_on_stove()`.
- **`OrderSystem`** loads the recipe list, exposes `current_recipe()`,
  `current_order_text()` (the ticket), `check_delivery(plate)` (tag multiset
  match, all COOKED), `draw_next()` (random, avoids repeating the previous
  recipe when more than one exists), `set_current(i)`, `reset()`.
- **`KitchenLoop`** draws the next order after each delivery and on reset.
- **`KitchenNet`** full-state RPC carries `current_index` instead of the old
  tag/count pair; `orders_sync.tres` syncs `current_index`.
- **Kitchen scene**: `ToasterCounter` at (0, 0, -2) with the toaster and the
  bread spawner on top; bread added to the item replicator.
- **Food lookups**: anything that took "the first food" now filters by tag
  (`egg`), since bread shares the `food` group. Debug overlay watches stay
  egg-specific.

## Layout

```
        [Order board]            z = -5.8
   [Counter]  [ToasterCounter]   z = -2      toaster (two slots) + bread crate
   [Counter] [Stove] [PlateRack] z =  0      eggs      pan       plates   [Trash] x=4
            [Pass]               z =  3
      o   o   o   o              z =  4..5   spawn points
```

## Tests

- Smoke: bread spawns; toast cooks in ~3 s and burns; egg-on-toast delivers
  when the ticket asks for it; a fried-egg plate is rejected against a toast
  ticket and a toast plate against a fried-egg ticket; binned bread is
  replaced; `randomize_orders = false` keeps existing checks deterministic.
- Net: host sets recipe 1; client sees `current_index` and the board text.

## Out of scope

Cutting board and vegetables (next batch), ticket queue, expiry, fail state,
changes to the run goal or star thresholds, any art beyond primitives.
