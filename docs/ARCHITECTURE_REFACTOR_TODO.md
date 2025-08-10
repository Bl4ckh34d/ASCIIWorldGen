<!-- File: docs/ARCHITECTURE_REFACTOR_TODO.md -->
# WorldGen 2.x – Architecture Refactor Plan & TODO

## Objectives

- Modularize world generation into composable, testable systems with single responsibility
- Preserve current visuals/feature fidelity while making behavior easier to reason about and extend
- Move to rule-driven biomes (temperature in °C, moisture, elevation, land/ocean) with clear separation of concerns
- Improve performance, determinism, and stability (no per-cell noise allocations; shared caches)
- Isolate rendering/color logic from generation/classification

## Inventory (current state in code)

- Pipeline (implemented in `scripts/WorldGenerator.gd`)
  - Terrain: `scripts/generation/TerrainNoise.gd` (FBM + continental mask + domain warp; optional horizontal wrap)
  - Rivers: steepest-descent D8 flow, accumulation; stochastic droplets with light erosion; adaptive threshold; polar cutoff; fast recompute path for sea-level changes
  - Shoreline/coast: turquoise shallow water near shores, beach marking, distance-to-coast via BFS, continuous turquoise strength for water rendering
  - Climate: `scripts/generation/ClimateNoise.gd` with latitude profile, continentality vs distance-to-coast, moisture advection via vector-field noise, simple orographic proxy; exposes `temperature`, `moisture`, `precip`, `distance_to_coast`
  - Mountain radiance: cool/wet radiance around `MOUNTAINS`/`ALPINE` to break banding
  - Biomes: `scripts/generation/BiomeClassifier.gd` uses soft thresholds (temp, moisture, elevation) + humidity minima + high-elevation forest clamps + smoothing; ICE_SHEET applied to ocean via wiggle threshold; post hot/cold overrides still applied in generator
  - Lava: river cells become lava where local temperature in °C exceeds `lava_temp_threshold_c`
- Rendering: `scripts/style/AsciiStyler.gd`
  - Water depth shading, coastal turquoise overlay, continental shelf pattern blending, ocean ICE_SHEET whitening
  - Land biome palette + glyphs; land whitening for very cold (≤ −10 °C)
- UI & UX: `scripts/Main.gd`, `scripts/SettingsDialog.gd`
  - Top bar: Play/Pause/Reset, Seed input with deterministic hash, Randomize toggle (jitter terrain/climate/sea level), Sea-level slider with debounced quick update
  - Settings tabs: General (size), Continents (octaves/frequency/lacunarity/gain/warp), Ocean (sea level, shallow threshold, shore band, shore noise mult), Rivers (enable + parameters), Climate (polar cap value present in UI)
  - Hover inspector: coordinates, height in meters, biome name, humidity, °C, flags (Beach/River/Lava)
- Data/state available from generator
  - `last_height`, `last_is_land`, `last_turquoise_water`, `last_turquoise_strength`, `last_beach`, `last_water_distance`, `last_temperature`, `last_moisture`, `last_distance_to_coast`, `last_biomes`, `last_flow_dir`, `last_flow_accum`, `last_lava`, `last_ocean_fraction`
- Current biome enum (implemented)
  - OCEAN, ICE_SHEET, BEACH
  - DESERT_SAND, DESERT_ROCK, DESERT_ICE
  - STEPPE, GRASSLAND, MEADOW, PRAIRIE, SWAMP
  - TROPICAL_FOREST, BOREAL_FOREST, CONIFER_FOREST, TEMPERATE_FOREST, RAINFOREST
  - HILLS, FOOTHILLS, MOUNTAINS, ALPINE
  - LAVA_FIELD, VOLCANIC_BADLANDS, SCORCHED_FOREST
- Legacy/unused scaffolding
  - `scripts/WorldModel.gd` and `scripts/WorldConfig.gd` exist but are not wired into the current pipeline
  - Duplicate project subtree under `worldgentest/` with older generator/UI

## Preserve (must not regress)

- Ocean depth color fade and turquoise shallow water near shores
- Beach detection (note: polar non-beach caps are not currently implemented)
- Distance-to-coast map (for depth fade, continentality)
- Rivers, flow accumulation, light erosion (fast path respected on sea-level changes)
- Lava streams where temperatures exceed lava threshold
- Temperature/biome behavior:
  - Land ≤ −10 °C → white (rendering override)
  - Ocean ICE_SHEET where `t_c ≤ −10 °C ± wiggle`
  - Hot override ≥ 30 °C → deserts/badlands or steppe; no lush grassland at ~55 °C
- Mountain radiance (cooling/wetting around mountains/alpine)
- Randomize toggle behavior (jitter terrain/climate and sea level in −0.35..+0.35 range)
- Info panel data + flags (coords, meters, biome, humidity, °C, River/Lava/Beach, Ice Sheet)

## Pain points and gaps

- Monolithic `WorldGenerator.gd` coordinates many responsibilities; hydro/coast/climate post/biome post live together
- Repeated or per-cell noise allocations inside inner loops (e.g., sea-ice wiggle noise in classifier) hurt performance and determinism
- Biome logic mixes normalized [0..1] thresholds and implicit °C conversions across multiple places (classifier and generator overrides)
- Duplicated distance-to-coast logic (BFS for shoreline features vs copy in climate) → wasted work and potential divergence
- `polar_cap_frac` exists in config/UI but is unused in generation; “non‑beach polar caps” not implemented
- Two hot/cold override mechanisms: within classifier (extremes) and in generator post-pass → harder reasoning and duplication
- `WorldModel.gd`/`WorldConfig.gd` are not integrated; duplicated legacy tree under `worldgentest/`

## Proposed Module Architecture (updated)

```text
scripts/
  core/
    WorldState.gd          # Struct of arrays, strict typing, sizes, metadata
    RNG.gd                 # Seed derivation, streams
    JobSystem.gd           # Thin wrapper over WorkerThreadPool; row/stripe parallel for big loops
    FieldMath.gd           # Hot kernels (distance transform, 3x3 mode, prefix sums) – pure functions
    config/
      TerrainConfig.gd
      ClimateConfig.gd
      HydroConfig.gd
      BiomeConfig.gd
      RenderConfig.gd
  systems/
    TerrainGenerator.gd    # height, is_land (FBM + warp + continental mask)
    ContinentalShelf.gd    # coast_distance via DT, shallow/turquoise/beach, shelf strength (replaces CoastlineSystem)
    FlowErosionSystem.gd   # flow dir/accum, droplets, erosion, rivers (fast & full) (replaces HydroSystem)
    PoolingSystem.gd       # depression fill, inland lakes/pools, outlets, lake_id tagging
    ClimateBase.gd         # seed-stable base fields (latitudinal temp, base humidity, advection noise)
    ClimateAdjust.gd       # fast recompute from `coast_distance`, `ocean_fraction`, user scalars → temperature/moisture/precip
    ClimateGenerator.gd    # orchestrates: base (when seed/config changes) + adjust (on sea-level/near-coast changes)
    ClimatePost.gd         # mountain radiance and future orographic passes
    FeatureNoiseCache.gd   # prebuilt low‑freq fields (desert split, ice wiggle, shore_noise, shelf_noise)
    DistanceTransform.gd   # exact/approx EDT (forward/backward chamfer 3-4-5 or Meijster); wraps FieldMath
    BiomeRules.gd          # pure rules by (t_c, m, elev, land/ocean) → biome id
    BiomeClassifier.gd     # thin wrapper around BiomeRules + smoothing
    BiomePost.gd           # extreme hot/cold/lava stream clamps (opinionated)
    AtmosphericSystem.gd   # cloud coverage & winds overlay; uses ClimateBase winds
    TectonicSystem.gd      # plate seeds/velocities, boundary detection, orogeny/volcanism over time
    ResourceSystem.gd      # strata + resource distribution (post-gen; slow cadence)
    POISystem.gd           # placement of temples/shrines/dungeons/ruins/volcanoes etc.
    CivilizationSystem.gd  # races, settlements growth; interacts with resources/rivers/coast/temperature/etc.
    MobSystem.gd           # monsters/megabeasts spawn & wandering rules
    TimeSystem.gd          # clock, tick scheduling, simulation speed
  style/
    AsciiStyler.gd         # glyph + color; uses WorldState + RenderConfig
    BiomePalette.gd        # biome→color mapping; ocean palette; cold‑white rule only here
  ui/
    SettingsAdapter.gd     # map UI tabs↔configs; validates/sanitizes
    RandomizeService.gd    # controlled jitter on configs when toggled
```

Notes:

- Keep `WorldGenerator.gd` as a thin orchestrator that wires modules, holds `WorldState`, and exposes stable accessors for the UI.
- Move all noise object construction into `FeatureNoiseCache` and systems; pass around fields, not noise instances.

## WorldState.gd (core)

- width, height, seed, derived seeds
- Arrays (Godot PackedArrays, lengths = W×H):
  - Topography: height, slope_y_cached (optional), base_rock, soil_depth
  - Land–sea: is_land, coast_distance, shallow/turquoise flags, turquoise_strength, beach
  - Hydro: flow_dir, flow_accum, river, lake, lake_id, lava
  - Climate: temperature, moisture, precip, winds_u, winds_v
  - Atmosphere: cloud_cover, cloud_char, storm_mask
  - Biomes: biome_id
  - Tectonics: plate_id, plate_vx, plate_vy, plate_age, boundary_type
  - Resources: per-tile compact resource fields (e.g., iron_grade, coal_grade, etc.)
  - Human/POI: settlement_id, poi_id, civ_owner_id, road_mask
- Metadata: width, height, seed; height_scale_m, temp_min_c, temp_max_c, lava_temp_threshold_c, ocean_fraction
- Memory notes: prefer PackedFloat32Array/PackedByteArray/PackedInt32Array; use small integer IDs to join to side tables (POIs, civs)

## Config modules (core/config)

- TerrainConfig: frequency, octaves, lacunarity, gain, warp, sea_level, wrap_x
- ClimateConfig: temp_min_c, temp_max_c, lava_threshold_c, continentality_scale, base offsets/scales, freeze/hot thresholds, mountain radiance knobs
- HydroConfig: droplets_factor, threshold_factor, erosion_strength, min_start_height, polar_cutoff, delta_widening
- PoolingConfig: depression fill method, max spill iterations, min lake area
- BiomeConfig: moisture minima, smoothing kernel size, desert sand bias weight, high‑elevation tropical clamps
- RenderConfig: glyph sets, palette, cold/ice/white rules, shelf pattern strength
- AtmosphereConfig: cloud_band_strength, advection_speed, curl_noise_scale, overlay_alpha
- TectonicsConfig: plate_count, speed_range, oceanic_fraction, ridge_gain, convergence_orogeny_gain
- ResourceConfig: strata_layers, resource_ruleset_version
- POIConfig: counts/rarity per type, min spacing, biome/height constraints
- CivilizationConfig: races list, initial settlements, growth parameters
- MobConfig: spawn tables per biome/time, mega spawn rate, wander radius
- TimeConfig: tick_rate, speed_steps, staged_generation_timeline (for creation animation)

## Data Flow (one generation)

1) TerrainGenerator → height, is_land
2) FlowErosionSystem (full when seed/settings change; fast path on sea-level updates) → flow_dir/accum, river, light erosion
3) PoolingSystem → inland lakes/pools (lake, lake_id), spill to outlets
4) ContinentalShelf → coast_distance (DT), shallow/turquoise/beach, turquoise_strength, shelf strength
5) ClimateGenerator → temperature, moisture, precip (ClimateBase once, ClimateAdjust on sea-level change)
6) ClimatePost → mountain radiance (cooling/wetting around mountains/alpine)
7) FeatureNoiseCache (desert split, ice wiggle)
8) BiomeRules (+ cache) → BiomeClassifier (smoothing)
9) BiomePost → hot/cold/lava streams from rivers
10) AtmosphericSystem → cloud_cover overlay and winds glyphs (optional)
11) AsciiStyler → stable render using WorldState + RenderConfig (+ cloud overlay)

## Biome taxonomy

- Implemented: OCEAN, ICE_SHEET, BEACH; DESERT_SAND, DESERT_ROCK, DESERT_ICE; STEPPE, GRASSLAND, MEADOW, PRAIRIE, SWAMP; TROPICAL_FOREST, BOREAL_FOREST, CONIFER_FOREST, TEMPERATE_FOREST, RAINFOREST; HILLS, FOOTHILLS, MOUNTAINS, ALPINE; LAVA_FIELD, VOLCANIC_BADLANDS, SCORCHED_FOREST.
- Planned additions (optional, map initially to nearest existing palette/glyph):
  - SAVANNA (warm semi‑arid; sits between GRASSLAND and STEPPE for 18–30 °C, m ≈ 0.35–0.45)
  - TUNDRA (cold plains; below ~2–8 °C with m ≥ 0.30)
  - FROZEN_FOREST (cold forest; can map to DESERT_ICE palette at first)
  - FROZEN_MARSH (cold swamp)

## Rules table (banding by °C, moisture, elevation)

Evaluate elevation first (elevation bands in normalized height; use lapse to compute effective °C):

- elev > 0.8 → ALPINE; elev > 0.6 → MOUNTAINS; elev > 0.4 → FOOTHILLS; elev > 0.3 with base GRASSLAND → HILLS

Then temperature/moisture bands by effective Celsius `t_c_adj`:

- ≤ −10 °C: land → DESERT_ICE; ocean → ICE_SHEET
- (−10 .. 2] °C: land → TUNDRA if m ≥ 0.30 else DESERT_ROCK (until TUNDRA added, map to DESERT_ROCK/ICE)
- (2 .. 8] °C: m ≥ 0.5 → BOREAL_FOREST else STEPPE
- (8 .. 18] °C (temperate):
  - m ≥ 0.60 → TEMPERATE_FOREST
  - m ≥ 0.45 → CONIFER_FOREST
  - m ≥ 0.35 → MEADOW
  - m ≥ 0.25 → PRAIRIE
  - m ≥ 0.20 → STEPPE
  - else → DESERT_ROCK
- (18 .. 30] °C (warm):
  - m ≥ 0.70 → RAINFOREST
  - m ≥ 0.55 → TROPICAL_FOREST
  - m ≥ 0.40 → SAVANNA (fallback to GRASSLAND until added)
  - m ≥ 0.30 → GRASSLAND
  - else → DESERT_ROCK
- ≥ 30 °C (hot):
  - m < 0.40 → DESERT_SAND vs DESERT_ROCK via low‑freq desert_noise + heat bias
  - else → mountains/hills → VOLCANIC_BADLANDS; forests/wetlands → SCORCHED_FOREST; otherwise STEPPE

Smoothing: 3×3 mode filter; reapply ICE_SHEET tag afterwards.

## Performance plan

- Coast distance: replace queue BFS with a 2‑pass 8‑neighbor distance transform
  - Forward/backward chamfer (weights 1/√2) is O(W×H), branch‑light, cache‑friendly
  - Optionally provide exact EDT (Meijster/Felzenszwalb) in `DistanceTransform.gd` for pixel‑accurate distances
  - Output `coast_distance` for all cells; water uses it for turquoise/shelf, land for continentality

- Climate split for fast sea‑level updates
  - `ClimateBase.gd` computes seed‑stable fields once: latitudinal profile, elevation lapse factor, zonal bands, noise/advection fields
  - `ClimateAdjust.gd` recombines base with `coast_distance`, `ocean_fraction`, user offsets/scales to produce temperature/moisture/precip
  - On sea‑level slider: recompute only `is_land`, `coast_distance` (2‑pass DT), `ocean_fraction`, then run `ClimateAdjust` (single pass)

- Precompute low‑frequency noise fields in `FeatureNoiseCache`
  - `desert_noise_field`, `ice_wiggle_field`, `shore_noise_field`, `shelf_value_noise_field`
  - Consume as arrays; never instantiate `FastNoiseLite` inside inner loops

- Incremental/dirty updates
  - Track masks for cells whose `is_land` toggled on sea‑level change; derive a tight bounding box band around the coastline
  - Limit turquoise/beach marking, shelf pattern mix, and biome reclassify to this band when possible
  - Fall back to full‑field passes only beyond a change ratio threshold (e.g., >20% cells toggled)

- Threading
  - Use `JobSystem.gd` to stripe rows among N worker tasks for big O(W×H) loops (DT forward/backward, climate adjust, biome classify, river accumulation)
  - Ensure per‑task writes are disjoint (row ranges) to avoid locks; combine reductions (e.g., ocean cell count) with atomic or post‑sum

- Memory/layout
  - `WorldState` holds `PackedFloat32Array`/`PackedByteArray` SoA; single allocation per field; reuse buffers
  - Typed GDScript everywhere; eliminate Dictionary param passing in hot paths in favor of config structs

- Rendering hot‑path hygiene
  - Keep ASCII builder allocation‑free: reuse `PackedStringArray` buffer, avoid per‑tile string concatenation; optionally diff‑draw only lines in dirty band

- Metrics
  - Time each system; target budgets at 512×256: Terrain 2–4 ms, Coast DT 1–2 ms, ClimateAdjust 1–2 ms, Biome 2–3 ms, Render ASCII 2–4 ms

### Sea‑level quick path (design)

1) Update `sea_level` and recompute `is_land` (single pass)
2) Recompute `ocean_fraction` (single pass, can be parallel reduced)
3) CoastlineSystem:
   - Zero `coast_distance` for ocean and immediate coastline; inf elsewhere
   - Run 2‑pass DT to fill `coast_distance`
   - Recompute turquoise/beach only for cells with `coast_distance ≤ shore_band + shallow_threshold`
   - Recompute `turquoise_strength` with cached `shore_noise_field`
4) ClimateAdjust: one pass combining base + new `coast_distance` + `ocean_fraction`
5) Biomes: reclassify in coastline band; if band fraction > threshold, reclassify all; run mode‑smoothing once; reapply ICE_SHEET and glacier masks from cache
6) Lava mask: single pass threshold on temperature

### Time simulation and creation animation (high level)

- TimeSystem ticks systems at different cadences; slider controls `dt` multiplier
- TectonicSystem runs at low cadence; applies gradual orogeny/ridge growth and advection of lithosphere fields
- FlowErosionSystem and PoolingSystem run at medium cadence; can be throttled (e.g., every N ticks)
- ClimateAdjust and AtmosphericSystem run each tick; ClimateBase occasionally (seasonal change toggle)
- CivilizationSystem, ResourceSystem, POISystem, MobSystem run at low to medium cadence with hysteresis; decouple rendering refresh from heavy recomputes
- Creation animation: follow scripted timeline in `TimeConfig.staged_generation_timeline` (flooded → volcanic → rainy → life in water → land life → forests/deserts → tectonics → civs)

## UI plan

- SettingsDialog → SettingsAdapter
  - Surface climate thresholds: `freeze_temp_threshold`, `lava_temp_threshold_c`, `hot_threshold_c`, `continentality_scale`, and mountain radiance (`cool_amp`, `wet_amp`, `passes`)
  - Clearly mark ranges and units (°C) in tooltips
  - Hide `polar_cap_frac` or implement feature (non‑beach polar caps)
- RandomizeService
  - Centralize jitter for terrain, ocean range (−0.35..+0.35), climate offsets/scales, continentality
- Rendering
  - Extract BiomePalette; keep temperature‑white override here only; water palette and shelf pattern strength tunable via `RenderConfig`
  - Atmospheric overlay toggle; second ASCII layer composed with base (cloud chars aligned with winds)
  - Time slider (speed), tick/pause/step controls; layer toggles (coast distance, rivers, lakes, winds, clouds, resources, POIs, civs, mobs)

## Testing & diagnostics

- Debug layers: toggle temperature bands, moisture bands, elevation bands, biomes, rivers, lava, distance_to_coast
- Golden seeds for regression: verify ice sheets, deserts, lava streams, beaches
- Performance budgets (ms per step) for each system and quick path timing on sea-level slider

## Migration strategy (incremental, non‑breaking)

Phase 0 – Scaffolding

- [ ] Add `core/WorldState.gd` and `systems/FeatureNoiseCache.gd` (wired but initially unused)
- [ ] Add `systems/BiomeRules.gd` (wrap current rules extracted from classifier)
- [ ] Add `core/FieldMath.gd` with 2‑pass chamfer distance transform and 3×3 mode filter
- [ ] Add `systems/DistanceTransform.gd` that applies FieldMath DT to `WorldState`
- [ ] Add `core/JobSystem.gd` (row striping helper over WorkerThreadPool)
- [ ] Rename plan modules: Coastline → `ContinentalShelf.gd`; Hydro → `FlowErosionSystem.gd`; add `PoolingSystem.gd`

Phase 1 – Extract systems (no behavior change)

- [ ] Move coastline logic to `ContinentalShelf.gd` (turquoise, beaches) and replace BFS with distance transform
- [ ] Move rivers/erosion to `FlowErosionSystem.gd` (full + fast variants)
- [ ] Introduce `PoolingSystem.gd` for depression fill and lake masks
- [ ] Move mountain radiance to `ClimatePost.gd`

Phase 2 – Noise caching & classifier cleanup

- [ ] Prebuild `desert_noise`, `ice_wiggle` in `FeatureNoiseCache` and consume from classifier
- [ ] Add `shore_noise_field` and `shelf_value_noise_field` to `FeatureNoiseCache`; consume in coastline/rendering
- [ ] Refactor `BiomeClassifier.gd` to call `BiomeRules` and remove inlined noise instantiations

Phase 3 – Unified rule table + extreme tags

- [ ] Implement explicit °C/moist/elev bands in `BiomeRules` that match current behavior
- [ ] Keep `BiomePost` for hot/cold/lava overrides; remove redundant overrides from generator/classifier
- [ ] Add `SAVANNA` and `TUNDRA` enums; map palettes/glyphs minimally

Phase 3.5 – Fast sea‑level pipeline

- [ ] Split climate into `ClimateBase` (seed‑stable) and `ClimateAdjust` (fast pass)
- [ ] Implement sea‑level quick path using: is_land pass → DT → ClimateAdjust → Band‑limited Biome + Lava
- [ ] Share `coast_distance` with climate; remove duplicate distance logic from climate

Phase 4 – Water bodies & lakes (optional)

- [ ] Implement `PoolingSystem.gd` lake_id tagging; update biomes/rendering

Phase 5 – UI expansion

- [ ] Add climate thresholds and radiance controls; implement `SettingsAdapter` + `RandomizeService`
- [ ] Hide or implement `polar_cap_frac` (non‑beach polar caps)

Phase 6 – Rendering isolation

- [ ] Extract `BiomePalette.gd` and water palette from `AsciiStyler.gd`
- [ ] Keep temperature‑white override only in rendering layer

Phase 7 – Cleanup

- [ ] Remove/replace legacy `WorldModel.gd` and `WorldConfig.gd` if superseded by `WorldState`
- [ ] Remove duplicated legacy subtree under `worldgentest/`

## Execution checklist

- [ ] WorldState introduced and generator orchestrator slimmed
- [ ] ContinentalShelf, FlowErosionSystem, ClimatePost extracted and tested
- [ ] Distance transform replaces BFS; `coast_distance` shared by climate
- [ ] FeatureNoiseCache wired; no per‑cell noise allocations
- [ ] BiomeClassifier uses centralized BiomeRules; smoothing intact; ICE_SHEET reapply preserved
- [ ] BiomePost contains only hot/cold/lava clamps; generator/classifier overrides removed
- [ ] Settings dialog exposes climate thresholds and radiance controls; polar caps resolved
- [ ] BiomePalette extracted; AsciiStyler simplified; water palette tunable
- [ ] Added SAVANNA and TUNDRA enums + minimal styling
- [ ] Sea‑level quick path under target budget at target resolutions; golden seeds verified; performance budgets met
- [ ] PoolingSystem in place; lakes validated in coast distance and rendering
- [ ] Atmospheric overlay renders and moves with winds
- [ ] Time slider controls cadence; systems scheduled without hitches
- [ ] POIs/resources/civs/mobs basic pipelines stubbed behind toggles

## Notes

- Keep feature parity by default; guard new behavior behind config toggles if needed
- Avoid touching water color gradient and turquoise logic other than moving it into CoastlineSystem
- Consider moving heavy kernels (DT, flow accumulation) to GDExtension if W×H grows large; keep API identical
