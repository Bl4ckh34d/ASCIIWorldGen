# Agent Instructions (worldgentest)

## Non-Negotiables
- **GPU-first / GPU-only visuals**: do not introduce `RichTextLabel`-based map rendering (CPU BBCode/text). The canonical look is the world map: `GPUAsciiRenderer` + `AsciiQuadRenderer` + shader passes (clouds, lighting).
- **No CPU fallback render path**: if a GPU path fails, treat it as a bug to fix, not something to “fallback” around.
- **Avoid GPU->CPU readback in hot paths**: snapshots are allowed only at explicit transition points (e.g. worldmap -> regional) and must be cached. Never read back per-frame.

## Rendering Style Targets
- Regional + local (interiors) maps should **match the worldmap’s pixel-light style**:
  - Biome base colors borrow from the worldmap biome palette (slight variation is fine).
  - Terrain shading follows sun position / time-of-day (hillshade style).
  - Cloud cover produces moving cloud shadows over terrain.
- Prefer reusing the existing worldmap rendering assets and shaders instead of inventing a new renderer.

## Map Marker Convention
- We reserve **biome IDs >= 200** for gameplay-only render markers (POIs, doors, chests, bosses, etc.).
- These IDs must be handled in `scripts/style/BiomePalette.gd` so the GPU palette texture can render them.
- Current marker ids in use (gameplay layer):
  - `200` house POI, `201` dungeon POI, `202` cleared dungeon POI
  - `210..217` interior tiles/objects (wall/floor/door/chest/boss/bed/table/hearth)
  - `218` NPC man, `219` NPC woman, `221` NPC child, `222` NPC shopkeeper
  - `220` player marker (optional)

## Determinism / Persistence
- All procedural content must be deterministic from:
  - `world_seed_hash`
  - macro tile coordinates (`world_x/world_y`)
  - local/global coordinates as appropriate
- Revisits must reproduce the same regional/local maps unless the underlying macro world tile changed.

## Where Things Live
- Worldgen GPU compute + packing: `scripts/systems/` and `shaders/`
- Gameplay scenes/state: `scripts/gameplay/`, `scenes/`
- GPU ASCII renderer stack: `scripts/rendering/` + `shaders/rendering/`
- Plans/docs: `GAMEPLAN.md`, `docs/*.md`

## Quick Sanity Checks Before You Ship Changes
- World map still renders via GPU path.
- Regional and local maps do not use text rendering for the map.
- No new per-frame buffer readbacks were added.
- Any new compute shaders are wired through `RenderingDevice` and don’t allocate/free buffers every tick.

## Local Tooling
- Godot installation directory (Windows): `C:\Users\ROG\Desktop\Code_Experiments\Godot_v4.6-stable_mono_win64`
- Preferred editor executable: `C:\Users\ROG\Desktop\Code_Experiments\Godot_v4.6-stable_mono_win64\Godot_v4.6-stable_mono_win64.exe`
- Preferred console executable for CLI/test runs: `C:\Users\ROG\Desktop\Code_Experiments\Godot_v4.6-stable_mono_win64\Godot_v4.6-stable_mono_win64_console.exe`
