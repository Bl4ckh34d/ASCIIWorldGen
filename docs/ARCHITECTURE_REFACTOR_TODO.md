# WorldGen 2.0 – Architecture Refactor Plan & TODO

## Objectives

- Modularize world generation into clean, testable systems with single responsibility
- Preserve current visual/features fidelity while making it easy to extend
- Make biome selection rule‑driven (temperature in °C, moisture, elevation) instead of scattered overrides
- Keep rendering/color logic isolated from generation and classification
- Improve performance and determinism (avoid per‑cell noise object creation)

## Preserve (must not regress)

- Ocean depth color fade and turquoise shallow water near shores
- Beach detection (and non‑beach polar caps)
- Distance‑to‑coast map (for depth fade and continentality)
- Rivers, flow accumulation, light erosion; no deltas (disabled)
- Lava streams where temperatures exceed lava threshold
- Temperature/biome overrides:
  - Land ≤ −10 °C → white
  - Ocean “Ice Sheet” where t_c ≤ −10 °C ± wiggle
  - Hot override ≥ 30 °C → deserts/badlands or steppe (no grassland at 55 °C)
- Mountain radiance (cooling/wetting around mountains/alpine)
- Randomize toggle behavior (now including climate jitter and sea level 0.2–0.8)
- Info panel data + flags (coords, meters, biome, humidity, °C, River/Lava/Beach, Ice Sheet)

## Current Pain Points

- Monolithic script with interleaved concerns; overrides interspersed with classifier logic
- Repeated noise allocations inside classification loops
- Smoothing pass occasionally wipes critical tags (e.g., sea ice) unless reapplied later
- Biome logic mixes normalized [0..1] thresholds and real world °C expectations → surprising results

## Proposed Module Architecture

```
scripts/
  core/
    WorldState.gd          # All layers, strict typing, sizes, metadata
    RNG.gd                 # Seed derivation, stream creation
    config/
      TerrainConfig.gd
      ClimateConfig.gd
      HydroConfig.gd
      BiomeConfig.gd
      RenderConfig.gd
  generation/
    TerrainGenerator.gd    # height, is_land (FBM + warp + continental mask)
    CoastlineSystem.gd     # coast distance BFS, shallow/turquoise/beach
    HydroSystem.gd         # flow dir/accum, droplets, erosion, rivers
    ClimateGenerator.gd    # temperature, moisture, precip + continentality
    ClimatePost.gd         # mountain radiance, future orographic passes
    FeatureNoiseCache.gd   # prebuilt low‑freq fields (desert split, ice wiggle)
    BiomeRules.gd          # rule table/DSL by (t_c, m, elev, land/ocean)
    BiomeClassifier.gd     # pure mapping via BiomeRules (no overrides)
    BiomePost.gd           # final clamps: cold, hot, lava streams
  style/
    AsciiStyler.gd         # glyph + color; reads WorldState + RenderConfig
    BiomePalette.gd        # biome→color; water palette; cold overrides only here
  ui/
    SettingsAdapter.gd     # map tabs→config; sync to WorldState size
    RandomizeService.gd    # controlled jitter on configs when toggled
```

### WorldState.gd

- width, height
- Arrays (PackedFloat32Array / PackedByteArray / PackedInt32Array):
  - height, is_land
  - coast_distance, shallow/turquoise, beach
  - flow_dir, flow_accum, river, lava
  - temperature, moisture, precip
  - biomes
- Metadata: seed, derived seeds, height_scale_m, temp_min_c, temp_max_c

### Config modules

- TerrainConfig: frequency, octaves, lacunarity, gain, warp, sea_level
- ClimateConfig: temp_min_c, temp_max_c, freeze/hot thresholds, continentality_scale, jitter (base offsets/scales), mountain radiance knobs
- HydroConfig: droplets_factor, threshold_factor, erosion_strength, min_start_height, polar_cutoff, deltas_enabled
- BiomeConfig: moisture band edges, temperature band edges (°C), desert sand bias, smoothing kernel size, rule weights
- RenderConfig: glyph sets, palette, cold/ice/white rules, font size, zoom (future)

## Data Flow (one generation)

1) TerrainGenerator → height, is_land
2) CoastlineSystem → coast_distance, shallow/turquoise, beach
3) HydroSystem → flow_dir/accum, river (erosion optional)
4) ClimateGenerator → temperature, moisture, precip (with continentality + jitter)
5) ClimatePost → mountain radiance (cool/wet around mountains/alpine)
6) BiomeRules + FeatureNoiseCache (desert split noise, ice wiggle) → BiomeClassifier
7) BiomePost → cold clamp (≤2 °C), hot clamp (≥30 °C), lava streams
8) AsciiStyler → stable render using WorldState + RenderConfig

## Biome Taxonomy (normal + extremes)

- Ocean: OCEAN, ICE_SHEET (cold)
- Deserts: DESERT_SAND, DESERT_ROCK, DESERT_ICE (cold), LAVA_FIELD (extreme hot)
- Grassland family: PRAIRIE, MEADOW, GRASSLAND, STEPPE
  - Cold: FROZEN_STEPPE (maps to DESERT_ICE or TUNDRA), SNOW_MEADOW (tundra‑like)
  - Hot: SCORCHED_GRASSLAND (maps to STEPPE/ROCK in min set)
- Forest family: RAINFOREST, TROPICAL_FOREST, TEMPERATE_FOREST, CONIFER_FOREST, BOREAL_FOREST
  - Cold: FROZEN_FOREST (taiga/snow cover)
  - Hot: SCORCHED_FOREST (fire‑scarred)
- Savanna (new, warm semi‑arid transitional)
  - Cold: — (rare; would fold to steppe)
  - Hot: DRY_SAVANNA (maps to steppe/rock in min set)
- Wetlands: SWAMP (hot/cold variants: FROZEN_MARSH)
- Relief: HILLS, FOOTHILLS, MOUNTAINS, ALPINE
  - Cold: GLACIATED_MOUNTAINS (alpine + ice sheet)
  - Hot: VOLCANIC_BADLANDS (maps to DESERT_ROCK + lava adjacency)

Note: For v1 of refactor we can map the extreme tags to existing minimum set (e.g., FROZEN_FOREST → DESERT_ICE color/style) and add new IDs incrementally.

## Rule Table (banding by °C, moisture, elevation)

Use Celsius bands:

- ≤ −10 °C: land → DESERT_ICE; ocean → ICE_SHEET
- (−10 .. 2] °C: land → TUNDRA if m ≥ 0.30 else DESERT_ROCK
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
  - m ≥ 0.40 → SAVANNA
  - m ≥ 0.30 → GRASSLAND
  - else → DESERT_ROCK
- ≥ 30 °C (hot):
  - m < 0.40 → DESERT_SAND vs DESERT_ROCK via low‑freq desert_noise + heat bias
  - else → (mountains→DESERT_ROCK) else STEPPE

Elevation modifiers (evaluate first):

- elev > 0.8 → ALPINE; elev > 0.6 → MOUNTAINS
- elev > 0.4 → FOOTHILLS; elev > 0.3 → HILLS (applied post‑choice if base was GRASSLAND)

Smoothing: 3×3 mode filter; reapply ICE_SHEET tag afterwards.

## Performance Plan

- FeatureNoiseCache precomputes:
  - desert_noise (low‑freq) for sand/rock split
  - ice_wiggle noise for sea ice threshold
- No noise objects created inside per‑cell loops
- Arrays pre‑allocated; avoid per‑frame string work in UI

## Settings UI Additions

- Climate tab:
  - freeze_threshold_c, hot_threshold_c
  - temp_min_c, temp_max_c
  - continentality_scale, mountain_cool_amp, mountain_wet_amp, mountain_radiance_passes
  - desert_sand_bias (weight), moisture band sliders (optional advanced)
- Randomize tab (or General): toggles & amplitude sliders for jitter; sea level range (min/max)
- Rendering tab: colors, glyph sets, cold white override toggle

## RandomizeService

- Jitters:
  - terrain: frequency, lacunarity, gain, warp
  - ocean: sea_level ∈ [0.2, 0.8]
  - climate: temp/moist base offsets & scales, continentality_scale
  - seeds: derive per‑system seeds stable per play

## Testing & Diagnostics

- Debug layer toggles: show temperature bands, moisture bands, elevation bands, biomes, rivers/lava
- Golden seeds for regression (ensure ice sheets, lava, deserts appear as expected)
- Performance budgets (ms per step) and hotspots

## Migration Strategy (non‑breaking, incremental)

Phase 0 – Docs & scaffolding
- Add WorldState, FeatureNoiseCache, BiomeRules (empty shell)

Phase 1 – Extract systems (no behavior change)
- Move coastline logic → CoastlineSystem
- Move rivers/erosion → HydroSystem
- Move mountain radiance → ClimatePost

Phase 2 – Noise caching & classifier cleanup
- Prebuild `desert_noise`, `ice_wiggle`
- Refactor BiomeClassifier to a pure rules function using current rules

Phase 3 – Rule table (°C/moist/elev) + extreme tags
- Implement banded rules; ensure existing overrides matched
- Keep hot/cold post still present but it should become a no‑op

Phase 4 – Settings UI expansion
- Add climate thresholds, continentality_scale, mountain radiance settings, desert bias

Phase 5 – Rendering isolation
- Extract BiomePalette, water palette; keep AsciiStyler clean

## New Biomes (to add gradually)

- SAVANNA (warm semi‑arid)
- TUNDRA (cool/cold plains)
- FROZEN_FOREST (cold forest; initial mapping to DESERT_ICE colors)
- SCORCHED_FOREST (hot-dry forest; initial mapping to DESERT_ROCK colors)
- VOLCANIC_BADLANDS (mountain/hill hot‑dry; initial mapping to DESERT_ROCK + lava adjacency)
- LAVA_FIELD (extreme hot desert; currently represented by lava streams)
- FROZEN_MARSH (cold swamp; initial mapping to DESERT_ICE palette)

Each new enum will require:
- Classifier mapping entry
- Palette color
- ASCII glyph selection
- Info panel name

## Execution Checklist

- [ ] Add core/WorldState.gd; migrate arrays from WorldGenerator
- [ ] Add generation/FeatureNoiseCache.gd; wire into generator and classifier
- [ ] Extract CoastlineSystem, HydroSystem, ClimatePost (mountain radiance)
- [ ] Refactor BiomeClassifier to use a centralized rules function (no overrides)
- [ ] Implement ICE_SHEET in the rules (ocean path) – keep reapply after smoothing
- [ ] Implement hot/cold bands in rules; remove/disarm post overrides if redundant
- [ ] Expand SettingsDialog with Climate controls (thresholds, continentality, radiance)
- [ ] Extract BiomePalette and water palette from AsciiStyler; keep temperature‑white override separate & configurable
- [ ] Add SAVANNA and TUNDRA enums + minimal styling
- [ ] Add RandomizeService and SettingsAdapter (move jitter to service)
- [ ] Golden seed tests for deserts, ice sheets, lava streams; profiling pass

## Notes

- All refactors should be feature‑parity by default; keep flags to disable new behavior if needed
- Avoid touching ocean depth color fade and turquoise logic, except for moving to CoastlineSystem


