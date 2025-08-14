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

M2 — Seasonal climate
- Extend climate GPU/CPU with seasonal term and time push constants; parity off by zero amplitude.

M3 — Cloud/wind basic
- Wind bands + curl noise; cloud advection (GPU); precip → moisture coupling.

M4 — Hydro cadence
- Tile updates for flow/accum; amortized pooling; verify stability.

M5 — Biome cadence
- Reclassify on cadence/dirty flags; verify visuals.

M6 — Plates prototype
- Voronoi plates + boundary classification; light boundary updates; optional advection.

M7 — Volcanism + meander
- Stochastic lava events + decay; river meander GPU pass; polish.

M8 — Checkpoints & rewind
- Periodic snapshots; scrub UI; deterministic replay.

---

## 12) Debugging & Metrics

- Parity mode: run CPU mirrors periodically, log RMSE for temp/moist/precip, equality on masks.
- GPU timings: per‑pass durations; budget adherence warnings.
- Determinism checks: hash fields per tick under fixed seeds.

---

## 13) Future (Out of Scope, Tracked)

- Detailed trade winds/jet streams; multi‑layer atmosphere.
- Tides (single/multiple moons) as periodic sea‑level modulation.
- Diurnal temperature swing in climate and radiative cooling at night.
- Vegetation cycles and resource feedbacks.


