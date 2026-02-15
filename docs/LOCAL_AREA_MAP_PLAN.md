# Local Area Map (POI Interiors) Plan

## Summary
Implement the “even more zoomed-in” maps for houses, dungeons, and other POIs:
- Deterministic generation from world seed + POI id/seed key.
- Walkable interior layouts with objects, items, and enemies.
- Entry/exit loop back to the regional map.
- Persistence for “cleared” and “looted” states as needed.
- **Render in the same GPU pixel-light style as the worldmap** (GPU-only/GPU-first): palette-driven colors + GPU lighting where appropriate.

This evolves the current placeholder room renderer in `scripts/gameplay/LocalAreaScene.gd` while keeping map visuals off the CPU (no RichTextLabel/BBCode map rendering).

## Current Scaffold (What Exists Today)
- Scene: `scenes/LocalAreaScene.tscn`
- Script: `scripts/gameplay/LocalAreaScene.gd`
  - Consumes POI payload from `GameState.consume_pending_poi()` or `StartupState.consume_poi()`.
  - Renders a fixed-size boxed room with a door (`+`) and decorative `*`.
  - Player can move; `Q/Esc` returns to regional map.
  - Exits can mark POIs cleared using `PoiCatalog` `clears_on_exit`.
- POI determinism:
  - POI presence is currently computed on the regional map via `PoiRegistry.get_poi_at(...)`.
- Persistent progress:
  - `GameState` tracks POI discovery and cleared POIs via `WorldFlagsStateModel`.

## Goals
- Deterministic interior generation per POI:
  - House layout and contents are stable.
  - Dungeon layout, rooms, enemies, chests are stable.
- Persistence:
  - Re-entering the same POI should reproduce the same base layout from seed.
  - Later, “changes” (opened chests, defeated groups) persist on top of that base via saved POI instance flags.
- Interaction-ready:
  - Player can interact with doors, chests, NPC placeholders.
  - Items can be collected into inventory.
  - Enemies can trigger battles (optional milestone).
- Seamless return to regional:
  - Exit returns to the exact world tile + local coordinate.
  - Dungeon cleared state can affect the regional POI marker (already supported as `C`).
  - Doorways should be **step-to-enter/exit** (no mandatory `E` press for the main door tile).
  - Returning from a battle started inside an interior should restore the **interior player position** (do not snap back to the entrance).
- Minimal time system:
  - Local movement can advance the in-game clock slightly, but no local speed-up controls.
  - Later: allow “Rest until morning” in appropriate POIs (inns, temples/guildhalls with rank, wilderness tents).

## Non-Goals (For This Phase)
- Full sprite art and animations. Keep ASCII map first.
- Complex AI/pathfinding.
- Multi-floor dungeon persistence (we can plan it, but do not overbuild initially).

## NPCs + Shops (Scaffolded)
Implemented in the current scaffold (initial pass):
- Houses spawn 0..4 NPCs in common “family constellations”.
- Shops are houses flagged as `is_shop` and spawn exactly 1 shopkeeper + 0..N customers.
- NPCs pick a random destination and use **A*** pathfinding to walk there in realtime (shopkeepers are stationary).
- `E` interacts with adjacent NPCs and opens dialogue (time pauses while the dialogue popup is open).
- Shopkeeper interaction opens a dedicated local **Shop overlay scaffold** (buy/sell baseline, deterministic stock, gold/inventory hooks).

Target behavior:
- Houses can have NPCs (residents). Later: they can wander locally (simple random walk) and react to time-of-day/weather.
- Talking/interacting:
  - Use `E` as the universal interact key for NPC dialogue/interactions.
  - Start with placeholder dialogue (static lines) and expand toward quest hooks later.
- Shops:
  - Some interiors are shops with a shopkeeper NPC.
  - Shop UI is a dedicated overlay (buy/sell, gold, item details) in v0 scaffold form.
  - Inventory rules should stay consistent with the slot-bag system (equipment occupies slots, consumables stack).

## Data Contracts

### Input Payload (POI)
Current payload fields already passed from regional:
- `type` (e.g. `"House"`, `"Dungeon"`)
- `id` (stable POI id)
- `seed_key` (stable deterministic key)
- `world_x`, `world_y`, `local_x`, `local_y`
- `biome_id`, `biome_name`

We will treat these as the canonical local-area “instance key”.

### Local Area State (Proposed)
We need a small per-POI state to persist looting and clearing beyond “cleared on exit”.

Option A: Minimal persistence in `WorldFlagsStateModel`
- Track:
  - `cleared_pois[poi_id] = true` (already)
  - `poi_flags[poi_id] = { chest_opened: true, ... }` (new)

Option B: Dedicated `PoiInstanceState` dictionary under `GameState`
- `game_state.poi_instances[poi_id] = { opened_chests: [...], defeated_groups: [...], visited: true, ... }`

Milestone approach:
- Start with Option A (simple) or no persistence beyond `cleared_pois`.
- Add Option B when we introduce multiple interactables per POI.

## Map Representation

### Grid
Use an integer grid like:
- `W x H` for the interior.
- Tile ids: `floor`, `wall`, `door`, `water`, `lava`, `stairs`, etc.
- Object ids: `chest`, `table`, `bed`, `altar`, `enemy_marker`, etc.

### Rendering (GPU Pixel-Light Baseline)
- Use `GPUAsciiRenderer` (solid tiles) for the interior map view.
- Represent interior materials/objects via palette IDs (we reserve biome IDs `>= 200` as render markers) so the GPU palette texture can color them.
- Player/important interactables can be highlighted via GPU-friendly overlays (simple Control draw/ColorRect) without reverting to text rendering.
- Marker ids currently used for interiors/NPCs:
  - `210..217` interior tiles/objects
  - `218` NPC man, `219` NPC woman, `221` NPC child, `222` NPC shopkeeper

### Collision
Walkability:
- Walls and some objects block movement.
- Doors can be passable and become “open” after interaction (optional).

## Generation Plan

### 1) House Generator
Features:
- Rectangular or L-shaped layouts.
- One entrance door placed on the boundary.
- Furniture placement by room type:
  - Bed, table, shelf, maybe NPC placeholder.
- 0-2 chests (optional).

Determinism:
- Seed from `world_seed_hash` and `poi_id`/`seed_key`.
- Variation: small set of templates with seed-selected rotation/mirroring.

### 2) Dungeon Generator
Milestone progression:

M0: Single-room dungeon
- Just like the current placeholder, but themed and with a chest and an enemy marker.

M1: Multi-room dungeon (grid-based)
- Use a simple BSP or “rooms + corridors” generator.
- Place:
  - Entrance room near door.
  - 3-8 rooms.
  - 1-3 enemy groups.
  - 1-2 chests.

M2: Keys/locked doors (optional)
- One locked door gating treasure or boss room.

M3: Multi-floor (later)
- Stairs and floor index in instance state.

## Interaction Plan

### Core interactions
- `Interact` key (recommend `E`):
  - Door: open/close or exit when at entrance.
  - Chest: open once, grant item(s), record opened state.
  - NPC placeholder: show dialog stub (later).

### Enemy triggers
Option A: Contact triggers a battle (simple)
- If player steps onto `enemy_marker`, trigger `SceneRouter.goto_battle(...)`.

Option B: Random encounters inside dungeon (implemented)
- Step-based danger meter (FF-style, invisible), separate from overworld meter and persisted per-POI.

## Scene Flow
Entry:
- Regional -> `SceneRouter.goto_local(poi_payload)`
- `LocalAreaScene` generates the map from payload.

Exit:
- `Q` exits to regional.
- `Esc/Tab` opens the menu overlay.
- Exiting through the entrance door via `E` also exits.

Clearing rules:
- Keep `PoiCatalog.clears_on_exit` behavior:
  - Houses: probably do not “clear”.
  - Dungeons: cleared when the main boss is defeated (main treasure is typically gated by this).

## Persistence and Save/Load
- Save should include:
  - `cleared_pois` (already)
  - Any per-POI state you choose (if we implement chests/enemies persistence).

Schema:
- Save schema is versioned; current: `SAVE_SCHEMA_VERSION=4`.

## Implementation Milestones

### M0: Formalize Local Area Generator
- Add `scripts/gameplay/local/LocalAreaGenerator.gd`
- Add `scripts/gameplay/local/LocalAreaTiles.gd` (ids, glyphs, colors)
- Refactor `LocalAreaScene.gd` to render from generated arrays.
Status: scaffold implemented (`LocalAreaGenerator` + `LocalAreaTiles` added; `LocalAreaScene` now consumes generator output).

### M1: Add Interaction + Chests
- Add chests and an `E` interaction.
- Grant items via `GameState.party.add_item(...)`.
- Persist opened state (minimal).
Status: scaffold implemented (v0):
- Universal `E` interaction is wired for NPCs + chest interaction.
- Main chest grants deterministic loot and persists opened state.

### M2: Dungeon Multi-Room + Enemy Triggers
- Implement rooms + corridors.
- Place enemy markers that start battles.
- Persist defeated state (optional).
Status: scaffold implemented (v0):
- Procedural rooms/corridors with guaranteed boss path are active.
- Dungeon random encounters use a step-based danger meter.

### M3: Dungeon Clear Conditions
- Decide and enforce what “cleared” means (boss, loot, visited, etc).
- Ensure regional map uses cleared state (already shows `C`).
Status: scaffold implemented (v0):
- Dungeon clear condition is locked to boss defeated.
- Regional map renders cleared dungeon marker (`202`).

## Testing / Verification
- Determinism:
  - Same POI id yields identical map layout and chest contents.
- Persistence:
  - Open a chest, exit, re-enter: chest stays opened.
- Save/load:
  - Save inside POI, load, exit: returns correctly and state remains.

## Dungeon Generation (Implemented v0)
- Procedural generator with guaranteed solvability:
  - A "golden path" from entrance to boss (boss always reachable).
  - Larger dungeon footprints than houses (currently `160x90` cells; tune as needed).
  - Extra branches/side rooms for complexity.
- Random encounters inside dungeons:
  - Step-based danger meter, FF-style (invisible to player).
- Determinism:
  - Generation keyed by `world_seed_hash` + `poi_id`.
- Still planned (later):
  - Keys/locks/gates, multi-floor dungeons, themed rooms, trap density, etc.

## Open Questions (Need Your Answers)
Locked decisions (2026-02-09):
1. Dungeon “cleared” means: main boss defeated.
2. Houses can have battles, but only in rare quest/event-driven cases (not baseline).
3. POI interiors persist: no re-looting on re-entry.
4. `E` is the universal interact key in local areas.
5. Houses have must-have furniture for lived-in spaces:
   - Bed, hearth, toilet (shitter), stools/chairs, table (plus other location-appropriate props).
