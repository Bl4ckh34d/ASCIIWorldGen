# ProceduralGame – GAMEPLAN

## Context
We are pivoting from the `/ProceduralGame` Python/terminal idea to the existing Godot worldgen project located at:
`C:\Users\ROG\Desktop\Code_Experiments\GodotExperiment\worldgentest`

Goal: turn the existing world generator into the foundation of a full game. Keep the world map generation and visuals (especially ocean depth coloring + climate zones) while staying on the GPU-first runtime path.

## Key Decisions (Locked In)
- Engine: Godot 4.6 (project config shows `config/features=4.6`).
- Base project: use existing worldgen project directly.
- Rendering: **GPU-only (or GPU-first)** for map visuals (world/regional/local). No RichTextLabel/CPU BBCode map rendering; reuse `GPUAsciiRenderer` + compute-driven lighting/clouds.
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
- Add multi-scene game loop:
  - `Main` world map scene (macro map, tile selection).
  - Regional map scene (1m²-like local terrain per selected world tile).
  - Local POI/interior scene (houses/dungeons at higher zoom).
  - Random battle scene (FF1/FF2 style command menu + win screen).
  - In-game menu overlay (inventory, party loadout/equipment, stats, settings, quit).
- Ensure regional map can cross to adjacent world tiles and remain seamless based on neighboring world-tile biome data.
- Keep deterministic generation for POIs and encounter outcomes from world seed + tile coordinates.
- Time system (minimal):
  - World map: speed-up buttons accelerate world evolution/simulation.
  - Gameplay (regional/local/battle): normal time only.
  - Fast travel (only to previously visited world-map tiles): temporarily accelerates time while traveling.
  - Calendar: use a 365-day year for player familiarity (no leap years for now).
  - Later: time-of-day affects encounter tables; daylight length varies by season + latitude (midnight sun).

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
- `scripts/systems/ContinentalShelfCompute.gd` – shallow water + beach masks

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
- Keep the GPU-first simulation path (plates/hydro/erosion/etc) as the default runtime, but tune via cadence/budget controls.
- Keep ocean depth coloring and shelf/turquoise blend.
- Ensure the map renders reliably at the existing resolution on the GPU runtime path.

### Phase 2 – Scene Flow + Regional Map
- From `Main` world map: click tile to enter regional map for that tile.
- Capture world biome snapshot and selected tile context in shared startup/gameplay state.
- Regional map:
  - Render deterministic local terrain from selected/neighbor world tile biomes.
  - Move player with edge crossing into adjacent world tiles (X wraps, Y clamps).
  - Seeded POI spawn points (house/dungeon) and seeded random encounter rolls.
  - Toggleable menu overlay.

### Phase 3 – Battles + POI Interiors
- Battle scene with command menu (`Attack`, `Magic`, `Item`, `Flee`) and result panel.
- Return player cleanly to regional map after battle with persisted position.
- Defeat: Game Over (load save or restart).
- POI interior scene for house/dungeon entry/exit loop.
- Expand toward full RPG systems:
  - Party up to 4 members.
  - Hiring system at inns/temples/POIs.
  - Basic inventory and equipment.

### Phase 4 – Time + Seasons
- Minimal time model:
  - World time can tick on movement/encounters for display/logs.
  - No gameplay speed-up controls outside the world map.
  - Fast travel advances time faster during travel only.
- Day/night and seasonal modifiers: later.

## Detailed Plans (Docs)
- Regional seamless generator + cache: `docs/REGIONAL_SEAMLESS_GENERATION_PLAN.md`
- Local POI interiors: `docs/LOCAL_AREA_MAP_PLAN.md`
- Battle system: `docs/BATTLE_SYSTEM_EXPANSION_PLAN.md`
- Menu + inventory + equipment: `docs/MENU_INVENTORY_PLAN.md`
- Civilization (wildlife + humans + epochs): `docs/CIVILIZATION_PLAN.md`
- NPCs + politics + economy: `docs/NPC_POLITICS_ECONOMY_PLAN.md`

## Open Questions / To Decide
Locked decisions (2026-02-09):
- World resolution: keep current for early alpha.
- Seed prompt: leave as-is for early alpha.
- UI direction: keep current UI for early alpha; revisit later once core loop is stable.
- Worldgen vs world map:
  - "Worldgen" is the accelerated simulation mode where we can speed up time and watch the world evolve.
  - "World map" is the macro navigation view during gameplay; it runs the same simulation systems, but much slower (nearly static over a playthrough).
- Encounters: step-based danger meter (FF-style): each step increases encounter chance; after each step we roll a dice check; on encounter, meter resets/adjusts.

## Design Decisions Log
- 2026-02-05: Pivot from new Python/terminal project to existing Godot worldgen project.
- 2026-02-05: Use full biome system, horizontal wrap, seed prompt.
- 2026-02-08: Locked core scene stack: world map -> regional map -> local POI interiors + battle scene + menu overlay.

## Current Implementation Status
- Implemented:
  - World-map tile click signal and transition from `Main` to `RegionalMap`.
  - Shared gameplay state in `StartupState` for world snapshot + tile context + queued battle/POI transitions.
  - New scenes:
    - `scenes/RegionalMap.tscn`
    - `scenes/BattleScene.tscn`
    - `scenes/LocalAreaScene.tscn`
    - `scenes/ui/MenuOverlay.tscn`
  - Regional map prototype:
    - Deterministic biome-aware ASCII terrain generation.
    - Player movement and seamless cross-tile traversal (X wrap, Y clamp).
    - Incremental redraw path for movement (edge-only cell re-sampling over cached field buffers), with partial GPU edge uploads in `GpuMapView`, live F3 HUD redraw/upload percentiles, and perf harness (`tools_regional_redraw_perf.gd`).
    - Seeded POI placement + entry to interior scene.
    - Seeded random encounter entry to battle scene.
  - Battle prototype:
    - FF-style command buttons and win/escape result panel.
    - Multi-party selection (choose commands for party members, then resolve) with multi-enemy support (count-based).
    - Game Over on defeat.
  - Interior prototype:
    - Walkable local map with return path to regional map.
    - Dungeon boss battle trigger and persistent POI instance state (boss defeated + main chest opened).
  - Map overlay + fast travel scaffold:
    - `M` opens a world-map overlay from gameplay scenes.
    - Fast travel is allowed only to previously visited world tiles and advances time during travel.
  - System scaffolding layer:
    - `GameState` autoload as single source of truth for run state.
    - `GameEvents` autoload as scene-agnostic signal hub.
    - `SceneRouter` autoload for centralized scene transitions.
    - Data models for party members/party state/time state.
    - Additional persistent models for settings, quests, and world flags/progress.
    - New persistent scaffolding models: economy, politics, NPC world state (background daily tick).
    - Civilization epoch scaffolding: delayed epoch shifts (years/decades with rare month-fast jumps) and epoch multipliers wired into economy/politics/NPC symbolic ticks.
    - Epoch gameplay hook (first slice): encounter rate/difficulty/reward scaling and local shop buy/sell multipliers now consume epoch + local scarcity/war pressure.
    - Epoch NPC behavior hook (next slice): local interior NPC density/move cadence/disposition and dialogue stubs now consume epoch + local scarcity/war pressure.
    - Data catalogs for items, enemies, and POI types.
    - Deterministic registries for POIs and encounters.
    - Battle state machine scaffold driving command resolution + rewards payload.
    - Versioned JSON save/load schema (`SAVE_SCHEMA_VERSION=6`).
    - Multi-slot save scaffolding (`slot_0..slot_2`) via scene contracts.
    - Tabbed menu overlay (`Overview`, `Party`, `Characters`, `Stats`, `Quests`, `Settings`) wired to live data + save/load/settings apply.
      - Characters tab: per-member slot inventory (Valheim-like), HP/MP bars, right-click Use/Equip/Drop, drag & drop between slots.
- Pending/Next:
  - Replace prototype ASCII local/regional rendering with full art/render layer.
  - Continue regional continuity/perf tuning (generation seams are scaffolded; tuning remains).
  - Expand civilization epoch effects from metadata into gameplay consequences (economy/politics/NPC behavior modifiers).
  - Deepen time/day-night effects (baseline hooks exist; expand tables and balancing).

## Working Agreement
- Keep this file updated with decisions, scope, and next steps so other agents can continue without re-discovery.
- Treat GPU-only rendering as a project constraint: prefer RD compute + Texture2DRD pipelines and avoid CPU readbacks/fallbacks.
