<!-- File: docs/SIMULATION_TIME_SYSTEM_REFACTOR.md -->

## Time Simulation Framework: Architecture & Refactor Plan (GPU‑first, Deterministic)

This plan upgrades the world generator into a continuous, deterministic simulation driven by a robust time system. It standardizes how systems tick (Play/Pause/Reset/Step, speed control), ensures GPU‑first execution, and adapts existing modules to incremental updates. Heavy processes (e.g., rivers) are scheduled sparingly or tiled, so we no longer do “all steps in one frame.”

### High‑level goals
- Deterministic simulation for any seed, settings, and time schedule.
- Robust Play/Pause/Reset, Step (forward/back via checkpoints), and speed control.
- GPU‑first compute with CPU parity for fallback/testing.
- Incremental, amortized updates with fixed cadence and frame budgets.
- Clean orchestration and dependency management between systems.

---

## 1) Time & Control Model

### State (in `WorldState.gd`)
- `simulation_time_days: float` — authoritative sim time in days.
- `time_scale: float` — days of sim per real‑second (UI slider, e.g., 0.1×..10×).
- `tick_days: float` — fixed step size in days (e.g., 1/120 ≈ 0.00833 days ≈ 12 minutes); small enough for smooth day/night.
- Derived per frame:
  - `year_float = simulation_time_days / 365.0`
  - `day_of_year = fract(simulation_time_days / 365.0)` (0..1)
  - `time_of_day = fract(simulation_time_days)` (0..1)

### Time advance (in `TimeSystem.gd`)
- Accumulator pattern with fixed sim step to ensure determinism regardless of frame rate:
  - `acc += real_delta_seconds * time_scale`
  - While `acc >= tick_days`: emit `tick(tick_days)` and do `acc -= tick_days`
- Paused → no accumulation; Step → single `tick(tick_days)` (or custom step width).
- Backward play: achieved via checkpoint scrub (see §8), not negative `tick_days`.

### UI semantics
- Play: if no seed specified → randomize seed, (re)generate, start time.
- Pause: stop time; systems hold state.
- Reset: stop time; clear state; reapply defaults; regenerate; set `simulation_time_days = 0`.
- Speed: bind slider to `time_scale`.
- Step: single forward tick; Backstep: load previous checkpoint and simulate forward to desired time.

---

## 2) Simulation Orchestrator & Scheduling

### Orchestrator (`Simulation.gd`)
- Subscribes to `TimeSystem.tick(tick_days)`.
- Maintains an ordered list of systems and their cadence.
- On each tick, executes systems whose cadence matches (or tile partition scheduled for this tick).
- Collects “dirty field” flags to trigger dependent recomputes.

### Per‑system interface
- `initialize(world: WorldState, config: Dictionary)`
- `tick(dt_days: float, world: WorldState, gpu_ctx: Dictionary) -> Dictionary` returning `{dirty_fields: PackedStringArray}`
- `cadence_ticks: int` (1 = every tick, 10 = every 10 ticks)
- Optional tiling: `tiles_per_tick: int`, `current_tile_index` for amortized coverage.

### Frame budgets
- Target 20–30 Hz UI while simulation may tick multiple times per frame if `time_scale` is high.
- Maintain per‑frame GPU budget (e.g., ≤ 8–12 ms) by limiting how many heavy passes run; overflow spills to next frame.

---

## 3) GPU Execution Model

- Persistent SSBOs for world fields (`height`, `is_land`, `coast_distance`, `temperature`, `moisture`, `precip`, `river`, `lake`, `biome_id`, `lava`, `cloud_cov`, `wind_u/v`, etc.).
- Double‑buffer fields that are read‑write in the same pass to avoid hazards.
- Avoid CPU readbacks; render ASCII / overlays from GPU outputs where possible, or readback infrequently (e.g., every N frames).
- Uniform push constants always include: `width`, `height`, `tick_days`, `year_float`, `day_of_year`, `time_of_day`, `ocean_frac`, plus system‑specific params.
- Determinism safeguards: no order‑dependent atomics; fixed reduction patterns; stable tile ordering.

Dual‑path requirement: every system must support GPU‑only and CPU‑only execution with equivalent results (within tolerance). The global toggle `use_gpu_all` controls default mode; per‑system toggles (e.g., `use_gpu_clouds`) can override for targeted parity testing.

---

## 4) Determinism, Replay, and Rewind

- RNG: stateless hashed RNG keyed by `(seed, system_id, tick_index[, x, y])` so results don’t depend on cadence or tiles.
- Scheduling: fixed cadence and tile order baked into config.
- Checkpoints (in `CheckpointSystem.gd`): periodic snapshots (every K days) of critical fields. To “rewind,” load snapshot ≤ target time and deterministically simulate forward.
- Save/Load: persist `seed`, `settings`, `simulation_time_days`, `time_scale`, and last checkpoint(s).

---

## 5) System Adaptation Guide

Each system adopts the tick interface, declares cadence, and moves heavy work to GPU. Key changes:

### Terrain / Plates (`PlateSystem.gd`, GPU: `plate_update.glsl`)
- Init: build Voronoi plates with wrap‑X; store `plate_id`, boundary mask, `fault_type` per edge segment; assign velocities; store per‑plate noise phase.
- Tick (cadence ~ 20–50 ticks): small updates along boundaries: convergent uplift/orogen, divergent spreading/ridges, transform shear roughness. Optional gentle plate advection via domain warp of `plate_id` and height.
- Volcanism: along convergent boundaries + hotspots (hashed RNG over time buckets), spawn lava fields with decay (tracked in `lava` field).

### Climate Seasonal (`ClimateAdjust.gd`/`climate_adjust.glsl`)
- Already multiplicative continentality. Add seasonal term: `t = t_base + (t_raw − t_base)*cont_factor + A(lat, land/ocean)*cos(2π*day_of_year)`.
- Tick every tick (cheap): update `temperature`, `moisture`, `precip` with seasonal modulation and small humidity advection (see Clouds/Wind).

### Clouds & Wind (`CloudWindSystem.gd`, GPU: `wind_field.glsl`, `cloud_advection.glsl`)
- Fields: `wind_u`, `wind_v`, `cloud_cov`.
- Wind: base latitudinal bands (Hadley/Ferrel/Polar) + curl noise eddies; slowly evolving phase. Update every K ticks.
- Clouds: semi‑Lagrangian advection each tick using wind; diffusion term for stability.
- Coupling: precipitation from `cloud_cov` (snow if cold); moisture increments land > 0 and ocean > land evap; orographic boost; clamp 0..1.
- Day/night visuals and cloud shadows feed ASCII layer (no sim dependency).

### Hydrology (`HydroDynamics.gd`, reuse `flow_dir/accum`, `depression_fill` shaders)
- Pooling/`E`: recompute in tiles or every M ticks; dependency on `height` and `sea_level`.
- Flow dir/accum: tile updates each tick; whole map completes over several ticks.
- Meandering (GPU `river_meander.glsl`): curvature‑guided lateral shifts with stochastic small moves; ensure connectivity; conservative step sizes.
- Freeze effects (later): if temperature ≤ 0 °C, damp meander/flow.

### Biomes (`BiomeCompute.gd`/`biome_classify.glsl`)
- Reclassify every N ticks or when `temperature/moisture/height` dirty flags set. Keep cadence to avoid thrash.

### Shelf/Coast/Beaches (`ContinentalShelfCompute.gd`)
- Recompute on sea‑level change or periodic low cadence; cache masks.

### Post passes (Lava, Overrides)
- Lava decay per tick; hot/cold overrides on cadence.

---

## 6) Scheduling & Cadence Examples

- Every tick: Climate seasonal, Clouds advection, small hydro tile, lava decay.
- Every 10 ticks: Biome classify, wind update (or wind every 20).
- Every 20–50 ticks: Plates update.
- Pooling/`E`: whole map every 1–3 in‑game days, or amortized tiles each tick.

Cadence is configurable and part of determinism. Use a ring‑tile iterator for spatial amortization.

---

## 7) Performance & Budgets

- GPU budgets per frame (e.g., ≤ 12 ms). If multiple ticks accumulate (high `time_scale`), schedule leftover ticks over subsequent frames.
- Avoid readbacks; only readback for ASCII render at a limited rate (e.g., every few frames) or use compute → texture → CPU path sparsely.
- Snapshots: compress with quantization for large fields; ring buffer of last few checkpoints.

Current: coarse budget limiter added — `Simulation.max_systems_per_tick` with UI control “Budget(#/tick)”. Replace with time‑based budget informed by GPU timings in a later milestone.

---

## 8) Backward/Forward, Step Width & Scrubbing

- Step width: default `tick_days`, exposed in UI. Step forward = one tick; Step back = load previous checkpoint and simulate forward to target.
- Play backward at speed: repeatedly load prior checkpoints and simulate forward; hide load latency with double buffering of checkpoints.

---

## 9) UI/Scene Integration Changes

- `Main.gd`:
  - Instantiate `TimeSystem`, `Simulation`, and (optional) `CheckpointSystem`.
  - Wire Play/Pause/Reset/Step, Speed slider.
  - Add `YearLabel` bound to `year_float`.
- `SettingsDialog.gd`: generation‑time controls remain; add “Time Step (min)” and “Speed (days/sec)” if desired.

---

## 10) New/Updated Modules

- `scripts/core/TimeSystem.gd` — accumulator, tick emission, pause/resume, step.
- `scripts/core/Simulation.gd` — system registry, dependency/cadence execution, budgets.
- `scripts/core/CheckpointSystem.gd` — periodic snapshots, load/scrub API.
- `scripts/systems/CloudWindSystem.gd` (+ GPU shaders) — wind + cloud advection + coupling.
- `scripts/systems/PlateSystem.gd` (+ GPU shaders) — plates + faults + uplift/subsidence + volcanism.
- `scripts/systems/HydroDynamics.gd` — incremental pooling/flow/river meander (GPU passes reused/added).
- Extend `ClimateAdjust*.gd/glsl` with seasonal push constants and CPU parity.

---

## 11) Migration Steps (Milestones)

M1 — Core time + controls
- Add `simulation_time_days`, `time_scale`, `tick_days` to `WorldState`.
- Implement `TimeSystem.gd`, `Simulation.gd` skeleton, Year label, UI wiring.

Status: DONE (added `TimeSystem.gd`, `Simulation.gd`, wired Play/Pause/Reset, Year label, Speed & Step controls)

M2 — Seasonal climate
- Extend climate GPU/CPU with seasonal term and time push constants; parity off by zero amplitude.

Status: DONE (shader/CPU accept `season_phase` + amps; default amplitudes = 0). Seasonal system updates phase each tick.

M3 — Cloud/wind basic
- Wind bands + curl noise; cloud advection (GPU); precip → moisture coupling.

Status: IN PROGRESS (wind bands + eddy noise added; GPU cloud advection + diffusion + humidity injection implemented; precip/evap coupling applied; diurnal/seasonal modulation on wind and coupling; UI modulation sliders.)

M4 — Hydro cadence
- Tile updates for flow/accum; amortized pooling; verify stability.

Status: IN PROGRESS (GPU ROI tiling added for flow dir/push; tile scheduler executes K tiles per tick; rivers retraced full-map post-tiles for now.)

M5 — Biome cadence
- Reclassify on cadence/dirty flags; verify visuals.

Status: DONE (added `scripts/systems/BiomeUpdateSystem.gd`, registered with orchestrator; UI cadence control added. Biomes refresh on cadence independent of climate.)

M6 — Plates prototype
- Voronoi plates + boundary classification; light boundary updates; optional advection.

Status: IN PROGRESS (Voronoi plates with wrap‑X, per‑plate velocities, boundary mask, convergent uplift, divergent ridge + subsidence, transform roughness; GPU boundary update with band spreading integrated at slow cadence.)
M7 — Volcanism + meander
- Stochastic lava events + decay (GPU) along plate boundaries + hotspots; river meander GPU pass; polish.
Status: DONE (added `VolcanismCompute.gd`/`volcanism.glsl`, `RiverMeanderCompute.gd`/`river_meander.glsl`; integrated in systems; GPU-only.)

M8 — Checkpoints & rewind
- Periodic snapshots; scrub UI; deterministic replay.

---

## Current Implementation Notes

- Time system ticks at fixed step; UI controls time scale and step width.
- Seasonal climate: `SeasonalClimateSystem.gd` updates config from world time each tick; `WorldGenerator.quick_update_climate()` recomputes climate fields without full regen (GPU-first, falls back to CPU), then reapplies mountain radiance. Afterward, `quick_update_biomes()` reclassifies biomes and applies overrides.
- No visible seasonal swing yet (amplitudes are zero). Next: add Season Strength UI, then enable non-zero amplitudes.
- ASCII redraw currently on generate paths; will throttle and/or tile as systems migrate to tick cadence.

---

## 12) Debugging & Metrics

- CPU parity: removed — project is now GPU‑only. Keep lightweight numerical checks within GPU where needed.
- GPU timings: per‑pass durations; budget adherence warnings.
- Determinism checks: hash fields per tick under fixed seeds.

---

## 13) Future (Out of Scope, Tracked)

- Detailed trade winds/jet streams; multi‑layer atmosphere.
- Tides (single/multiple moons) as periodic sea‑level modulation.
- Diurnal temperature swing in climate and radiative cooling at night.
- Vegetation cycles and resource feedbacks.



---

## 14) Public APIs & Signals

### TimeSystem.gd (authoritative clock)
- Signals:
  - `tick(dt_days: float)` — emitted for each fixed sim step.
- Properties:
  - `running: bool`
  - `simulation_time_days: float`
  - `time_scale: float`
  - `tick_days: float`
- Methods:
  - `start(), pause(), reset()`
  - `step_once()` — emit one `tick` and advance time by `tick_days`.
  - `set_time_scale(v: float)`, `set_tick_days(v: float)`
  - `get_year_float() -> float`, `get_day_of_year() -> float`, `get_time_of_day() -> float`

### Simulation.gd (orchestrator)
- Core:
  - `register_system(instance: Object, cadence: int = 1, tiles_per_tick: int = 0)`
  - `clear()` — remove all systems, reset counters
  - `on_tick(dt_days: float, world: Object, gpu_ctx: Dictionary)` — invoked from `TimeSystem.tick`
  - `update_cadence(instance: Object, cadence: int)` — live tuning from UI
  - `set_max_systems_per_tick(n: int)` — coarse budget limiter (count)
  - `set_max_tick_time_ms(ms: float)` — coarse time budget (CPU‑side)
- Scheduling semantics:
  - Systems run when `tick_counter % cadence == 0`.
  - Execution stops for the tick when either budget trips: max systems or time window.

### System contract (per module)
- `initialize(world_or_gen: Object)` — current MVP passes the `WorldGenerator` instance; will transition to `WorldState` + `gpu_ctx` in a later milestone.
- `tick(dt_days: float, world: WorldState, gpu_ctx: Dictionary) -> Dictionary`
  - Returns `{ dirty_fields: PackedStringArray }` to indicate dependents to refresh.
- Optional tiling (future): systems may expose `tiles_per_tick` and internal tile cursors.


---

## 15) WorldState schema (SoA)

Backed by fixed‑size `Packed*Array` buffers sized `width*height`. Mirrors long‑lived GPU SSBOs and exposes convenient helpers. CPU paths have been removed; systems operate GPU‑first/only.

- Dimensions/seed: `width:int`, `height:int`, `rng_seed:int`
- Rendering/meta: `height_scale_m:float`, `temp_min_c:float`, `temp_max_c:float`, `lava_temp_threshold_c:float`, `ocean_fraction:float`
- Topography: `height_field:PackedFloat32Array`
- Land–sea: `is_land:PackedByteArray`, `coast_distance:PackedFloat32Array`, `turquoise_water:PackedByteArray`, `turquoise_strength:PackedFloat32Array`, `beach:PackedByteArray`
- Hydro: `flow_dir:PackedInt32Array`, `flow_accum:PackedFloat32Array`, `river:PackedByteArray`, `lake:PackedByteArray`, `lake_id:PackedInt32Array`, `lava:PackedByteArray`
- Climate: `temperature:PackedFloat32Array`, `moisture:PackedFloat32Array`, `precip:PackedFloat32Array`
- Biomes: `biome_id:PackedInt32Array`
- Time: `simulation_time_days:float`, `time_scale:float`, `tick_days:float`

Helper API: `configure(w,h,seed)`, `size()`, `clear_fields()`, `index_of(x,y)`

Note: Current MVP routes most reads/writes through `WorldGenerator`’s `last_*` fields; systems progressively migrate to `WorldState` to minimize CPU copies.


---

## 16) Configuration keys & UI mapping

Primary config lives in `WorldGenerator.Config` and is updated by UI controls.

- Seed & size: `rng_seed`, `width`, `height`, `noise_x_scale`
- Terrain noise: `octaves`, `frequency`, `lacunarity`, `gain`, `warp`, `sea_level`
- Shores: `shallow_threshold`, `shore_band`, `shore_noise_mult`
- Climate base/jitter: `temp_base_offset`, `temp_scale`, `moist_base_offset`, `moist_scale`, `continentality_scale`
- Temperature extremes: `temp_min_c`, `temp_max_c`, `lava_temp_threshold_c`
- Seasonal controls: `season_phase`, `season_amp_equator`, `season_amp_pole`, `season_ocean_damp`
- Mountain radiance: `mountain_cool_amp`, `mountain_wet_amp`, `mountain_radiance_passes`
- Feature toggles: `use_gpu_all`, `use_gpu_clouds`, `realistic_pooling_enabled`, `use_gpu_pooling`, `rivers_enabled`, `lakes_enabled`
- Hydro pooling/outflow: `max_forced_outflows`, `prob_outflow_0..3`

UI bindings (current):
- Top bar: Play/Pause/Reset, Randomize (seed jitter & minor param jitter)
- Simulation tab: Year label, Speed slider → `time_scale`; Step minutes → `tick_days`; budgets (count/time)
- General tab: Sea level slider → `sea_level`; temperature and continentality sliders map to climate and extremes; Season strength and Ocean damp map to seasonal amps and damping
- Systems tab: cadence spinners for seasonal, hydro, clouds/wind, biomes, plates → orchestrator cadence


---

## 17) Shader interfaces (push constants & buffers)

Baseline push constants for compute passes:
- Ints: `width`, `height`
- Floats: `tick_days`, `year_float`, `day_of_year`, `time_of_day`, `ocean_fraction`
- Module‑specific floats/ints appended per pass (e.g., `sea_level`, `temp_min_c`, `temp_max_c`, seasonal amplitudes, advection scales)

Examples (live):
- Climate adjust (`climate_adjust.glsl`): needs `sea_level`, `temp_min_c`, `temp_max_c`, `season_phase/amps`, `continentality_scale`, plus time floats.
- Wind field (`wind_field.glsl`): uses `phase` derived from `simulation_time_days` for evolving bands/eddies; outputs `wind_u/v` SSBOs.
- Cloud advection (`cloud_advection.glsl`): inputs: previous clouds, `wind_u/v`, source/injection field; push constants: `adv_scale`, `diff_alpha`, `inj_alpha`.
- Plate labeling (`plate_label.glsl`) and boundary mask (`plate_boundary_mask.glsl`) produce `plate_id` and boundary flags.
- Plate update (`plate_update.glsl`) applies uplift/ridge/transform with band spreading in one pass.
- Volcanism (`volcanism.glsl`) and River meander (`river_meander.glsl`).

Buffer policy:
- Prefer persistent SSBOs with double‑buffering for read‑write hazards.
- Only readback when needed for CPU paths or ASCII overlays; otherwise keep entirely on GPU.


---

## 18) Spatial tiling & amortization

Goal: Spread heavy full‑map passes over multiple ticks without visual discontinuities.

- Tile iterator: ring or raster scan in wrap‑X order; deterministic sequence, stable across runs.
- Definition: `tiles_per_tick` per system with internal `current_tile_index` and `total_tiles`.
- ROI: systems accept an optional Region of Interest `[x0,y0,w,h]` to limit work to the current tile.
- Coupling: dependent fields outside ROI should be either read from latest global buffer or approximated; finalize full consistency every N ticks.

Hydro example (present):
- Flow direction/accum: ROI compute each tick; complete coverage over several ticks; river tracing may run globally at a lower cadence for connectivity.


---

## 19) Checkpoint system (spec)

Purpose: enable rewind/scrub and robust replay.

- Snapshot cadence: every K in‑game days (configurable; e.g., 5 days). Trigger on demand for manual saves.
- Contents (minimum viable):
  - Time & config: `simulation_time_days`, seed, core knobs affecting determinism (seasonal params, sea level)
  - Fields: `height`, `is_land`, `temperature`, `moisture`, `biome_id`, `lake`, `lake_id`, `flow_dir`, `flow_accum`, `river`, `lava`, `cloud_cov`
- Format & size:
  - Quantize large float fields to 16‑bit where acceptable (temp/moist/precip/clouds)
  - RLE/delta for sparse masks (rivers, lakes, lava)
  - Ring buffer of last N checkpoints; optional external export/import
- API:
  - `save_checkpoint(world: WorldState) -> Checkpoint`
  - `load_checkpoint(cp: Checkpoint) -> void`
  - `scrub_to(target_days: float)` — load nearest ≤ target and simulate forward deterministically


---

## 20) Testing, parity, and metrics

- GPU/CPU parity:
  - Periodically run CPU mirrors and compute RMSE/MAE/equality on key fields; log thresholds and regressions.
  - Existing helpers in `WorldGenerator.gd` (`_rmse_f32`, `_mae_*`, `_equality_rate_*`) provide metrics.
- Determinism:
  - Fixed seeds + cadence + tile order produce stable hashes of fields per tick; verify hash does not change across runs.
- Performance budgets:
  - Track per‑pass GPU timings and overall per‑tick CPU window; surface warnings in UI when limits exceeded.
- Visual cadence QA:
  - Ensure ASCII redraw throttling (currently every ~5 ticks) maintains responsiveness at typical speeds.


---

## 21) Risks & mitigations

- Drift between GPU and CPU paths:
  - Mitigate with parity mode, tests, and shared reference implementations.
- Budget overrun & stutter:
  - Coarse count/time budget in orchestrator today; move to timing‑aware scheduler next.
- Save size & I/O latency for checkpoints:
  - Quantization + sparse encodings; snapshot on worker thread (future).
- Feedback loops (clouds ↔ moisture ↔ precip):
  - Keep coupling small; clamp; monitor stability under high `time_scale`.
- Visual/physics mismatch during partial tile updates:
  - Use ROI‑aware consumers; commit globally on cadence boundaries.


---

## 22) Next steps (actionable)

1. Remove remaining CPU fallback branches from generation/update code; enforce GPU‑only.
2. Add per‑pass GPU timing collection; feed scheduler to enforce time budgets precisely.
3. Implement volcanism spawn/decay pass and river meander pass (GPU).
4. Expand checkpointing to persistent save/load and forward replay.
5. Optional: add atomic/staging strategy for broader plate band application in a single dispatch.
