# Regional Seamless Generation + Chunk Cache Plan

## Summary
Implement a deterministic, seamless regional map generator (1 tile ~= 1m^2) that:
- Renders coherent terrain/vegetation/props based on the underlying world-map biome(s).
- Scrolls around the player and supports crossing world-map tile boundaries without seams.
- Uses a chunk cache so movement does not regenerate everything each step.
- **Renders in the same GPU pixel-light style as the worldmap** (GPU-only or GPU-first): biome palette colors + sun/time hillshade + moving cloud shadows on GPU.

This plan replaces the current per-cell sampling in `scripts/gameplay/RegionalMap.gd` with a real generator + cache while keeping rendering GPU-only (no RichTextLabel/BBCode map output).

## Current Scaffold (What Exists Today)
- `scripts/gameplay/RegionalMap.gd`:
  - `REGION_SIZE = 96` and view window `VIEW_W = 64`, `VIEW_H = 30`.
  - Player movement crosses world tiles by wrapping `local_x`/`local_y` and updating `world_tile_x/world_tile_y`.
  - Tile appearance is sampled per cell using `key.hash() ^ world_seed_hash` (no spatial coherence).
  - POIs and encounters are deterministic via `PoiRegistry`/`EncounterRegistry`.
- World snapshot is stored in `scripts/gameplay/GameState.gd` (`world_biome_ids`, `world_seed_hash`, etc.).

## Goals
- Seamless traversal:
  - Crossing from world tile (x,y) to (x+1,y) should not “pop” due to re-seeding.
  - Terrain features should be spatially coherent (patches, lines, clusters).
- Biome-driven:
  - A temperate forest world tile produces forest-dense regional terrain (trees, undergrowth, clearings).
  - A mountain world tile produces rocky/slope-heavy terrain with sparse vegetation.
- Deterministic:
  - For a given `world_seed_hash` and (world/local/global) coordinates, results are identical every run.
- Performance:
  - Movement should update only the newly-visible edges/chunks.
  - Chunk cache should be bounded (LRU eviction).
- Integration:
  - Keep POIs deterministic and stable; later allow POI footprints to “claim” space (clear trees around a house).
  - Weather integration: regional visuals and encounter flavor should reflect world-map humidity/cloud density (later: rain/snow).

## Time + Simulation Speed (Minimal, Per Your Direction)
- In actual gameplay (regional/local/battles), we run at normal time. No “speed-up” buttons here.
- The only time acceleration is:
  - World map: speed-up buttons for world evolution (existing worldgen-style controls).
  - Fast travel: if fast traveling to a previously visited world-map location, we temporarily accelerate time while traveling.
- Implication for this regional plan:
  - Regional movement can still advance an in-game clock in small increments (for logs/lighting later), but we do not build a deep scheduling system here.

## Non-Goals (For This Phase)
- Full art layer (TileMap/2D sprites). We keep the GPU ASCII quad renderer (solid tiles, glyphs optional) as the baseline and add a richer art layer later.
- True hydrology/erosion at 1m scale.
- Persisting destructible terrain. (Cache is ephemeral; persistence comes later.)

## GPU Rendering Constraints (Project-Level)
- Do not render regional terrain via `RichTextLabel` (CPU). Use `GPUAsciiRenderer` and compute-packed textures.
- Lighting and clouds should be GPU-driven:
  - Light: local-view compute from height + sun/time (hillshade).
  - Clouds: GPU-generated cloud coverage texture with wind/time drift; shader casts moving cloud shadows.

## Coordinate System (Must Be Consistent)
We must define a single “global meter” coordinate system to guarantee seamlessness.

Definitions:
- World tile coordinates: `WT = (world_x, world_y)` in `[0..world_width-1] x [0..world_height-1]`.
- Regional coordinates inside a world tile: `R = (local_x, local_y)` in `[0..REGION_SIZE-1]^2`.
- Global meter coordinates:
  - `GX = world_x * REGION_SIZE + local_x`
  - `GY = world_y * REGION_SIZE + local_y`

World wrap:
- X wraps: `world_x` wraps in `[0..world_width-1]`.
- Y clamps: `world_y` clamps in `[0..world_height-1]`.

Chunk coordinates (for caching):
- Choose `CHUNK_SIZE` (recommend 32).
- `CX = floor(GX / CHUNK_SIZE)`, `CY = floor(GY / CHUNK_SIZE)`.
- Local coord inside chunk: `ux = GX - CX * CHUNK_SIZE`, `uy = GY - CY * CHUNK_SIZE`.

## Proposed Architecture

### 1) `RegionalGenParams` (Biome -> Param Mapping)
Create a param table mapping `world_biome_id` to local generation parameters, e.g.:
- Ground palette: grass/sand/snow/rock/wetland.
- Vegetation densities (trees, shrubs, grass tufts).
- Rock density / cliff propensity.
- Prop density (stumps, flowers, bones, etc. later).
- Walkability rules (mountains can be partially blocked; ocean tiles should be blocked).

Implementation target:
- New file: `scripts/gameplay/RegionalGenParams.gd` with `static func params_for_biome(biome_id: int) -> Dictionary`.

### 2) `RegionalChunk` Data
For each chunk store compact grids:
- `ground_id: PackedByteArray` (0..255) for base ground type.
- `object_id: PackedByteArray` (0..255) for props (tree, rock, etc).
- `flags: PackedInt32Array` optional (bitmask: blocked, poi, etc).

We can start with just `ground_id` + `object_id` and compute “blocked” from ids.

### 3) `RegionalChunkGenerator`
Generates a `RegionalChunk` for a `(CX,CY)` deterministically.

Inputs:
- `world_seed_hash`
- `world_width/world_height`
- `world_biome_ids` (snapshot)
- `REGION_SIZE`, `CHUNK_SIZE`

Outputs:
- `RegionalChunk` for that chunk.

Core rule: all noise samples must be based on global meter coords (GX,GY), never re-seeded per tile.

Noise options:
- Use `FastNoiseLite` seeded with `world_seed_hash` and sample at global coordinates.
- Or use `DeterministicRng` with coordinate hashing plus a “domain warp” trick.

Recommended approach:
- Keep CPU noise initially (FastNoiseLite) because region grid sizes are modest and deterministic.
- Use 2-3 layered fields:
  - `elev = fbm(GX,GY)` (coherent “height” proxy).
  - `veg = fbm(GX+K1,GY+K2)` (vegetation pattern).
  - `rock = fbm(GX+K3,GY+K4)` (rock patches).

### 4) Biome Seamlessness: Blend Band + Noise-Pattern Border (Decision)
Decision per your direction:
- World tiles are discrete on the macro map, but the regional map should blend adjacent biomes using a **noise-pattern border**.
- Example: forest -> grassland should transition with thinning trees, more shrubs/grass, and irregular boundary shapes (not a straight line).

Implementation approach:
- Use a **blend band** at world-tile edges (default `band_m = 8` meters).
- Compute base blend weights from distance-to-edge, then perturb the blend with a coherent noise field sampled in **global meter coords** `(GX,GY)` so the boundary looks organic and stays seamless.
- Blend:
  - ground palette / ground type
  - vegetation densities (trees thin out; shrubs/grass rise)
  - rock/cliff propensity (mountains fade into hills/grass)

Milestone approach:
- Implement blend band first (cache + coherent fields).
- Add stronger “border noise” shaping once base generator is stable.

### 5) Chunk Cache (`RegionalChunkCache`)
A cache that:
- Stores chunks keyed by `(CX,CY)`.
- Provides:
  - `get_cell(GX,GY) -> {ground_id, object_id, flags}`
  - `prefetch_for_view(center_GX, center_GY, view_w, view_h, margin_chunks)`
- Uses LRU eviction:
  - Keep `MAX_CHUNKS` (start at 256).
  - Track `last_used_tick` per chunk.

Integration point:
- `RegionalMap.gd` owns the cache instance.
- Each `_render_view()` calls `prefetch_for_view()` then samples cells.

### 6) POI Integration (House/Dungeon)
We already have deterministic POIs via `PoiRegistry.get_poi_at(...)`.

Plan:
- During chunk generation, query POIs for cells in that chunk.
- If POI present:
  - Override `object_id` at POI origin cell to a POI marker (house/dungeon glyph).
  - Optionally clear vegetation in a small radius for house (e.g., 4m).
  - Add `flags` bit `FLAG_POI`.
- For cleared dungeons:
  - Query `GameState.is_poi_cleared(poi_id)` at render-time (or store a “cleared” overlay).
  - Avoid storing clear-state inside the chunk (state is gameplay, chunk is deterministic worldgen).

### 7) Movement + Scrolling Behavior
Current behavior: player is always centered in the view window.

Your description: “map scrolls around the player when he walks close to the border”.

We should decide:
- Keep “always centered” (simple, already matches many roguelikes).
- Or implement “camera deadzone”:
  - Player moves within a box; camera only shifts when player exits deadzone.
  - This is closer to classic RPG scrolling.

Milestone:
- Keep centered for now.
- Add deadzone later if you want that specific feel.

Decision:
- Keep **player always centered** (current behavior).

## Water + Coast Rules (Decision)
- Player cannot enter macro **ocean** tiles (biome `OCEAN/ICE_SHEET`).
- Beach tiles are enterable; any land tile bordering water is also enterable.
- In regional/local maps, the player can wade into **shallow** water up to a realistic depth; deeper water is blocked (no swimming).
- Later: harbors + boats enable true water traversal.

## Slope + Cliffs (Decision)
- If terrain gradient is too steep (mountain faces, coastal cliffs), the player cannot pass.
- Implementation: regional generator must produce an elevation proxy and mark cells as blocked when local slope exceeds a threshold.

## Persistence (Decision)
- Regional/local generation must be deterministic and stable on revisit.
- It should remain identical **as long as the underlying world-map tiles used for blending have not changed**.
- Later: add a persistent “modification overlay” (e.g., chopped trees, built structures) on top of deterministic base terrain.

## Weather Hook (Planned)
Desired behavior:
- World-map climate fields drive regional/local weather:
  - cloud density -> overcast / rain
  - humidity -> likelihood/intensity
  - temperature -> rain vs snow (later)

Implementation plan (incremental):
1. M0/M1: regional generator ignores weather; keep ASCII visuals.
2. M2: add a simple weather overlay driven by per-tile values sampled from the world generator at time of entry (store in `GameState`).
3. Later: allow weather to evolve slowly with world time and world-map cloud/hydro ticks.
Status: scaffold implemented (2026-02-12):
- `GameState` now tracks per-tile regional biome transition windows when world biome snapshots change.
- `RegionalChunkGenerator` consumes transition overrides (`from_biome -> to_biome + progress`) and applies non-homogeneous per-cell transition masks.
- `RegionalMap` refreshes transition overrides over time and invalidates chunk cache only when quantized transition progress changes.

## Implementation Milestones

### M0: Generator Skeleton + Cache
- Add:
  - `scripts/gameplay/RegionalChunkCache.gd`
  - `scripts/gameplay/RegionalChunkGenerator.gd`
  - `scripts/gameplay/RegionalGenParams.gd`
- Wire `RegionalMap.gd` to use `cache.get_cell(GX,GY)` instead of `_rand01`.
- Keep current biome glyph mapping as the output layer (just fed by coherent fields).

### M1: Coherent Terrain Fields
- Replace “per-cell hash random” with coherent fields:
  - `elev` controls ground (grass vs dirt vs rock patches).
  - `veg` controls tree/shrub placement for forest biomes.
  - `rock` controls boulders/cliffs for mountain biomes.

### M2: Biome Border Policy
- Implement either:
  - Hard borders (no blending), or
  - Blend band (recommended).

### M3: POI Footprints
- Add POI footprint clearing (remove trees near houses).
- Add POI “entry spot” rules (door placement, approach path stub).

### M4: Upgrade Render Layer (Later)
- Replace ASCII renderer with:
  - `TileMap` or `MultiMeshInstance2D` for performance.
  - Keep chunk cache and generator unchanged.

## Testing / Verification
- Determinism:
  - For seed S, `get_cell(GX,GY)` returns the same ids across runs.
- Seam check:
  - Sample at the border: `(GX, GY)` and `(GX+1, GY)` across world tile boundaries should not re-seed artifacts.
  - Optional: add a headless script `tools_regional_seam_regression.gd` that hashes a strip of cells and compares to a stored baseline.
- Performance:
  - Ensure step movement does not regenerate all chunks each time.
  - Log chunk generation counts per step.

## Open Questions (Need Your Answers)
Locked decisions (2026-02-09):
1. Blend tuning:
   - Initial blend band width: `band_m = 8m` (refine later).
2. Water wading:
   - Wading depth target: ~`1.5m` (human wading).
3. Regional climate/biome evolution:
   - World map remains the authoritative simulation for climate+biome transitions, but the regional view must *animate* the change gradually over days (realtime gameplay), and not homogeneously: different parts of the 96x96 region shift at different times as the transition approaches.
   - Persistence target: revisits reproduce the same regional map for the same world time and seed; as world climate/biomes shift, the regional map converges toward the new target state progressively.
