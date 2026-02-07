# ProceduralGame – GAMEPLAN

## Context
We are pivoting from the `/ProceduralGame` Python/terminal idea to the existing Godot worldgen project located at:
`C:\Users\ROG\Desktop\Code_Experiments\GodotExperiment\worldgentest`

Goal: turn the existing world generator into the foundation of a full game. Keep the world map generation and visuals (especially ocean depth coloring + climate zones) while staying on the GPU-first runtime path.

## Key Decisions (Locked In)
- Engine: Godot 4.4 (project config shows `config/features=4.4`).
- Base project: use existing worldgen project directly.
- World map resolution: keep the worldgen resolution from the project (current defaults in code: `width=275`, `height=62`; verify/adjust if needed).
- World topology: wrap horizontally (cylindrical world).
- Seed handling: prompt the player for a seed (default random if blank).
- Biomes: use the full existing biome set (not simplified).
- Climate visualization: climate affects biome colors only (no separate overlay for now).
- Audio: none for now.
- Target platform: Windows only (initially).

## Immediate Scope (Now)
- Keep the world map generator and GPU rendering path.
- Strip out or bypass costly simulation paths only where needed, without reintroducing CPU-render fallback complexity.
- Ensure ocean depth coloring and shelf/turquoise visuals still look good.
- Make the map view stable and interactive.

## Near-Term Scope (Next)
- Add world map gameplay layer:
  - Player marker that moves on the world map.
  - Random encounter trigger on movement.
  - POI generation on world map (cities, villages, fortresses, dungeons, temples, etc.).
  - Deterministic POI seeds tied to the world seed + civilization seed so revisits persist.
- Add turn-based battle framework (Final Fantasy–style) with party members.
- Add time system (day/night + seasons) that influences world and schedules.

## Longer-Term Scope (Later)
- Civilization simulation (lightweight).
- NPC personality + local LLM decision/dialogue (when feasible).
- Economy, faction alignment, salaries, and hiring logic.
- Optional audio (procedural SFX/music).

## Technical References (Current Worldgen)
These are the core scripts we’ll likely keep and adapt:
- `scripts/generation/TerrainNoise.gd` – base height + land mask (FBM + domain warp)
- `scripts/generation/ClimateNoise.gd` – temperature + moisture + coast distance
- `scripts/generation/BiomeClassifier.gd` – biome assignment
- `scripts/style/WaterPalette.gd` – ocean depth coloring
- `scripts/style/AsciiStyler.gd` – ASCII rendering with colors
- `scripts/systems/ContinentalShelf.gd` – shallow water + beach masks

Current runtime direction:
- Keep the GPU compute pipeline as the primary runtime path.
- Remove legacy CPU/GPU switching code paths.
- Optimize heavy systems via cadence/budget controls, not by reintroducing CPU fallbacks.

## Plan
### Phase 1 – Worldgen Core Pass
- Identify the minimal path in `WorldGenerator.gd` to generate:
  - height map
  - land mask
  - coastal shallow water + beaches
  - temperature/moisture
  - biome IDs
- Remove or skip the erosion/plates/water-cycle systems.
- Keep ocean depth coloring and shelf/turquoise blend.
- Ensure the map renders reliably at the existing resolution on the GPU runtime path.

### Phase 2 – World Map Gameplay Layer
- Add a player entity on the world map.
- Movement with wrap-around in X.
- Add random encounter rolls on movement steps.
- Add POI placement (seeded, reproducible).

### Phase 3 – Battle System
- Turn-based battles with party up to 4 members.
- Death is permanent; no resurrection.
- Hiring system at inns/temples/POIs.
- Basic inventory and equipment.

### Phase 4 – Time + Seasons
- World time ticking on movement/encounters.
- Day/night and seasonal modifiers.

## Open Questions / To Decide
- Confirm target world resolution or increase for game map.
- Decide how to prompt for seed (start menu, dialog, command line).
- Decide how much of the existing UI stays vs. replaced.
- Decide if worldgen should be a separate scene or embedded in the main game scene.
- Decide how encounters are triggered (steps, tiles, time-based).

## Design Decisions Log
- 2026-02-05: Pivot from new Python/terminal project to existing Godot worldgen project.
- 2026-02-05: Use full biome system, horizontal wrap, seed prompt.

## Working Agreement
- Keep this file updated with decisions, scope, and next steps so other agents can continue without re-discovery.
