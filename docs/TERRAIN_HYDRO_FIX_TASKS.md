# Terrain + Hydro Coupled Fix Tasks

This backlog breaks the current terrain/tectonics/hydrology issues into discrete tasks.

## 1) Heightfield Stability
- Add post-tectonic slope-limited relaxation pass (GPU).
- Goal: remove isolated abyss/pinnacle artifacts at 25 km tile scale.
- Status: implemented (`TerrainRelaxCompute`, `terrain_relax.glsl`) and wired into `PlateSystem`.

## 2) Continental Rift Guard
- Prevent inland divergence from directly carving ocean-depth trenches unless marine context exists.
- Goal: rift valleys first, marine basins only where water context supports it.
- Status: implemented in `shaders/plate_update.glsl` using local ocean-neighborhood context.

## 3) Tectonic Trench/Uplift Rebalance
- Reduce global trench bias so long runs do not trend toward runaway flooding.
- Goal: mountains and trenches remain in plausible balance.
- Status: initial pass implemented (reduced trench default + softened divergent deep-axis).

## 4) Ocean Connectivity Gate
- Separate "below sea level" from "ocean water" by basin connectivity.
- Goal: inland depressions become lakes/salt basins unless connected to ocean.
- Status: implemented (`LakeLabelCompute` + `OceanLandGateCompute`) and applied in generation/runtime sea-level/tectonic/erosion updates.

## 5) Water Mass Accounting
- Track total water mass across reservoirs: ocean, lakes/rivers, atmosphere/cloud moisture, ice.
- Goal: no implicit infinite water creation/destruction.
- Status: implemented as runtime reservoir accounting in `WorldGenerator.update_water_budget_and_sea_solver()` (ocean/lake/atmo/ice proxy totals).

## 6) Closed Water Cycle
- Tie evap/precip/runoff/ice melt to reservoir transfers.
- Goal: physically consistent hydrology in dry vs wet worlds.
- Status: implemented as closed-loop controller using fixed-ocean-fraction + periodic sea-level solver feedback (no unbounded ocean growth).

## 7) Sea-Level / Basin Volume Solver
- Provide fixed-volume mode (or fixed-sea-level mode) with explicit behavior.
- Goal: stable coastlines and predictable flooding dynamics.
- Status: implemented (fixed-water-budget mode with target ocean fraction and bounded sea-level controller).

## 8) Instrumentation + Regression Tests
- Add metrics: slope outlier count, inland ocean count, ocean fraction drift, net tectonic height bias.
- Goal: prevent regressions while tuning rates.
- Status: implemented. Metrics now run in a dedicated GPU pass (`TerrainHydroMetricsCompute` + `terrain_hydro_metrics.glsl`) and feed both `water_budget_stats` and `tectonic_stats` (`net_height_bias`, per-tick/per-day drift). Regression runner added: `tools_terrain_hydro_regression_gpu.gd` (multi-seed tectonic+hydro sweep, GPU-only metric assertions).
- Run: `godot --path . --script res://tools_terrain_hydro_regression_gpu.gd` (requires a Vulkan-capable GPU runtime).
