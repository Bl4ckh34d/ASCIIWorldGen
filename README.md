# World Generator (Godot 4.4) - TODO & Architecture

This document is a step-by-step "engineering playbook" to build a **Dwarf Fortress-style world generator** with plate tectonics, orogenesis, erosion, climate, hydrology, biomes, resources, settlements, and time evolution. It is paired with working scripts and a scene so you can run a small but complete simulation **today** and iterate from there.

> TL;DR: Open the project in Godot 4.4 and run the project. The app starts in `res://scenes/Intro.tscn` and transitions to `res://scenes/Main.tscn`. Use **Play/Pause/Reset**, hover the map to inspect a tile, and use **Settings** + **Apply** to regenerate.

**Godot Runtime**: C:\Users\ROG\Desktop\Code_Experiments\Godot_v4.6-stable_mono_win64

---

## Design goals

- **Realistic-feeling macro geography** on a 2D cylindrical world (wraps horizontally, optional vertical wrap).
- **Physically-inspired systems**: plates drift; mountains rise at convergence; seafloor spreads; volcanoes build islands; rivers carve; sediment moves; climates and biomes respond.
- **Readable state at every pixel**: hover shows tile state: height, plate, climate, biome, river flow, volcanism, resources, etc.
- **Time evolution**: day/night & annual cycle, plate drift, erosion, vegetation spread/deforestation, desertification.
- **Mod-friendly settings**: everything tunable via a Settings panel.
- **Display**: GPU-only renderer. CPU/ASCII fallback paths are legacy and are being removed.

---

## World model (data layout)

We store each field on a 2D grid `W x H`, flattened to 1D for speed (index `i = x + y*W`). Core layers:

- **Topography**: `height` (meters-ish, normalized -- `-1.0` deep ocean to `+1.0` high mountains), `base_rock` (enum), `soil_depth`.
- **Tectonics**: `plate_id`, `plate_vx`, `plate_vy`, `plate_age`, `boundary_type` (derived each step near edges).
- **Climate**: `temperature` (°C approx), `moisture` (0–1), `precip` (mm), `winds_u/v` (zonal/meridional).
- **Hydro**: `flow_dir` (8-neighbor index), `flow_accum`, `river` (bool/intensity), `water` (surface water), `lake_id`.
- **Erosion**: `sediment`, `erodibility`, `diffusivity`.
- **Biomes/landcover**: `biome_id`, `vegetation` (0–1), `burned` timer.
- **Volcanism/heat**: `volcanic`, `hotspot_id` (optional), `heat_flux`.
- **Human layer**: `settlement_id`, `road` (optional later).
- **Resources**: dictionary per tile (`{resource_name: grade}`) and simple **strata** summary: `[ (rock_type, thickness_m), ... ]`.

> Tip: keep **dimensionless** internal units and only scale when needed for UI.

---

## Generation pipeline (one-time, then repeated when you click Apply)

1. **Seed & grids**
   - Create arrays for all fields, fill with zeros.
   - Seed RNG from `config.seed` for determinism.

2. **Base plates (Voronoi + velocity)**
   - Spawn `plate_count` seeds; assign nearest-plate via toroidal distance (wrap horizontally).
   - For each plate: random velocity vector with magnitude in `[plate_speed_min, plate_speed_max]`, plus a small angular swirl if you like.
   - Tag plates as **oceanic** or **continental** via biased random. Give oceanic plates thinner crust & lower isostatic base height.

3. **Initial topography from plates**
   - Height baseline = continental/oceanic isostasy + multi-octave fractal noise (FBM) for roughness.
   - Add **mid-ocean ridges** along divergent boundaries: ridge line noise band raises height; trenches on subduction lower it.
   - Add **cratons** (old continental cores): broaden/flatten noise in selected continental plates.

4. **Orogenesis pass**
   - Detect **convergent boundaries** by dot product of relative plate velocities across the edge.
   - Raise height by a Gaussian falloff from boundary (km-scale half-width), with variance by convergence rate. Add metamorphic/igneous rock tags; increase `erodibility` (young mountains) and `heat_flux` for volcanic arcs ~150–300 km landward of trench.

5. **Volcanism**
   - At **divergent**: basaltic ridges/islands.
   - At **convergent** (subduction): arc volcanoes (clustered peaks), increase `volcanic` and inject igneous strata.
   - **Hotspots**: a few moving mantle plumes independent of boundaries, creating island chains.

6. **Hydrology scaffolding**
   - Compute **flow direction** (D8 steepest descent or MFD) from `height`.
   - Priority-Flood or simple depression fill to route rivers to outlets. Mark `flow_accum`; where above a threshold -> rivers. Carve gentle channels (local height -= k * log(flow)).

7. **Climate (annually averaged first)**
   - Temperature from latitude (sine falloff) + lapse rate with height + noise.
   - Winds from 3-cell model (Hadley/Ferrel/Polar): zonal bands that reverse at ~30° and ~60° lat; add a small coriolis curl.
   - Moisture from evaporation over warm water (function of `temperature` & water fraction) and advective rain with **orographic precipitation**: upwind integral that rains on windward slopes, dries on leeward (rain shadow).

8. **Biomes**
   - Classify into tundra/ice, desert, steppe, grassland, temperate forest, tropical forest, etc. using a Whittaker-like temp–precip grid, plus elevation/latitude tweaks.
   - Initialize `vegetation` density by biome.

9. **Resources & strata**
   - Build 3–6-layer **strata** summary per tile (soil/sedimentary/igneous/metamorphic) informed by plate role, volcanism, and elevation history.
   - Distribute resources stochastically with rules, e.g.: coal in thick sedimentary basins; iron in old shields; copper along arcs; gold in metamorphic belts; rare earths in alkaline igneous; oil/gas in marine sedimentary with traps near folds/faults. Store as `{resource: grade}`.

10. **Settlements**
    - Score sites by: distance to coast/river, biome habitability, slope (flat is better), resource richness.
    - Place N settlements with Poisson-disk-ish spacing; later you can grow them over time and build roads (A* on a cost field).

---

## Time simulation (each tick when running)

1. **Clock & celestial cycle**
   - Maintain `t` in days; compute `time_of_day = fract(t)`, `day_of_year = fract(t/365)`. Solar declination = `-23.44° * cos(2π * day_of_year)`; use for daily temp swing and seasonal temp bias by latitude.

2. **Plate advection (Eulerian field advection)**
   - For each plate, advect its **lithosphere fields** (`height`, `base_rock`, `soil`, `volcanic`, etc.) by its velocity: sample `field(x - v*dt)` into a new buffer (bilinear, toroidal wrap).
   - Recompute local **relative velocities** to re-tag boundary types; apply small incremental **orogeny** and **ridge growth** at boundaries proportional to convergence/divergence rates.
   - Keep long-term isostatic relaxation: gentle diffusion that returns deep ocean basins and cratons toward equilibrium.

3. **Volcanism over time**
   - Divergent accretion & hotspot plume output add height and igneous layers; slow flank growth & occasional explosive events near arcs (noise-triggered spikes).

4. **Hydrology & erosion**
   - Recompute flow, flow accumulation.
   - **Hydraulic erosion**: erode where discharge is high & slope moderate; deposit sediment when slope is low (create deltas/alluvial fans).
   - **Thermal creep**: when local slope exceeds **talus angle**, move material downhill until stable.
   - Optionally, **coastal wave erosion** & **sea-level** changes (if ocean_level varies).

5. **Climate (diurnal/seasonal)**
   - Temperature = annual mean + seasonal term by latitude + diurnal swing by `time_of_day` + lapse rate.
   - Precipitation from moisture budget with orographic effect; occasional **storms** from noise events that spike precip and erosion.

6. **Biomes & vegetation dynamics**
   - Recompute biomes from temp/precip (with hysteresis). Vegetation spreads by seed/neighbor rule where climate supports it; deforestation near settlements/roads; fire events during drought reduce `vegetation` temporarily.

7. **Settlements growth/decline**
   - Population proxy grows with food/water/resources; declines with cold/drought; deforestation footprint expands; emits roads to other settlements if benefit > cost.

8. **Resources**
   - Mostly static geologically; surface **availability** varies with erosion/exposure and human extraction demand (optional).

---

## UI & interactions

- **Play/Pause/Reset**: control simulation tick.
- **Settings**: all exported config variables are surfaced; click **Apply** to re-generate with new seed & parameters.
- **Inspect (mouseover)**: shows everything about the tile under cursor.
- **View**: GPU-rendered map with cursor hover inspection.

---

## Performance tips

- Keep `W x H` modest initially (e.g., `200 x 100`). Increase later.
- Use **double buffers** for fields you advect/update each tick.
- Avoid per-frame allocations; reuse arrays.
- Expensive recomputations (e.g., full rivers) can run every N frames.
- Rendering is GPU-first; simulation and display are tuned for that path.

---

## Extending realism later

- True plate **polygons** and rigid transforms instead of field advection.
- **Priority-Flood** depression filling with lakes/outlet carving.
- **Köppen-Geiger** or **Holdridge** exact classification.
- **Atmospheric circulation** with pressure fields & coriolis advection.
- **Road networks** and trade simulation.
- **Save/Load** world states (serialize arrays to `.res` or `.bin`).

---

## How to run

1. Open Godot 4.4.
2. Open this project folder.
3. Run the project (`F5`) so it starts at `res://scenes/Intro.tscn`.
4. Use the top bar in `res://scenes/Main.tscn` to **Play/Pause**, **Reset**, and **Settings**.
5. Hover the map to inspect a tile. Change settings -> **Apply** to regenerate.

Happy world building!
