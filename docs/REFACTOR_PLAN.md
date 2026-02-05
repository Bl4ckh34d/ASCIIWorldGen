# WorldGen Refactor Plan -- Incremental, File‑wise To‑Do

<!-- File: docs/REFACTOR_PLAN.md -->

## Goals and KPIs

- **Stability**: 0 startup crashes from RD init; safe CPU fallbacks everywhere.
- **VRAM**: ≥60–75% reduction in peak GPU memory during gen/updates.
- **GPU perf**: ≥70–80% faster climate shore pass; no long stalls from barriers.
- **CPU perf**: ≥40–50% faster hot paths; remove O(n²) loops in critical systems.
- **Maintainability**: Split `scripts/Main.gd`; centralize shader loading and buffer pooling.

## Milestones and Sequencing (each is its own PR or small PR stack)

1) **M0 -- Baseline & Observability (P0)**
   - Establish logging, metrics, perf baselines before refactors.
2) **M1 -- RD Safety + Shader Loading + Buffer Pooling (P0)**
   - Guard RD acquisition, centralize shader loading, adopt `GPUBufferManager` in top-impact systems.
3) **M2 -- Hot‑Path Algorithms (P0/P1)**
   - Shore temperature simplification via distance‑to‑coast; remove CPU BFS in `ClimateNoise.gd`.
4) **M3 -- Biomes, Plates, Rivers (P0/P1)**
   - Reduce passes; fix O(n²) plate boundary/velocity; early‑out for iterative GPU.
5) **M4 -- Architecture & UI (P1)**
   - Decompose `Main.gd` into controllers and scene‑based UI.
6) **M5 -- Array Memory Pooling & CPU Cleanup (P1)**
   - Pool large PackedArrays; remove placeholder validation; vectorize hotspots.
7) **M6 -- Async/Threading & Simulation Scheduling (P2)**
   - Remove blocking barriers in prod builds; improve `Simulation.gd` budgeting.

## Measurement Baseline (do before M1)

- Add basic timers and counters (frame time percentiles, dispatch counts, readbacks, VRAM estimate) to `Logger.gd` and dev HUD.
- Log: RD acquired?, shader version used, pipelines created, buffer allocations (size, purpose), readbacks.
- Capture a reference run: new world -> full cycle (terrain, climate, biomes, rivers) on 275x62; record peak VRAM and frame timings.

---

## Milestone Details and Acceptance Criteria

### M0 -- Baseline & Observability (P0)

- [ ] Add structured JSON logs in `scripts/systems/Logger.gd` (level, context, device status, buffer stats).
- [ ] Add on‑screen dev HUD toggle (basic stats) via `HUD.gd` (new) and integrate with `Main.gd`.
- [ ] Capture baseline metrics and store in `docs/perf/baseline-YYYYMMDD.md`.

#### Acceptance (M0)

- [ ] Logs include RD availability, shader backend, pipeline creation success/failure, buffer alloc/reuse, readbacks.
- [ ] Baseline doc checked in with reproducible settings.

### M1 -- RD Safety + Shader Loading + Buffer Pooling (P0)

- [ ] Centralize RD acquisition in `scripts/systems/ComputeShaderBase.gd`; early return on null with clear error.
- [ ] Enforce explicit SPIR‑V selection in `scripts/systems/ShaderLoader.gd` (e.g., "vulkan"); validate non‑null spirv.
- [ ] Adopt `GPUBufferManager.gd` across: `BiomeCompute.gd`, `ClimateAdjustCompute.gd`, `RiverCompute.gd`.
- [ ] Defer renderer RD init until after first ASCII draw or a user toggle in `GPUAsciiRenderer.gd` / `Main.gd`.

#### Acceptance (M1)

- [ ] No RD calls if device is null; safe CPU fallbacks activated and logged.
- [ ] No raw `storage_buffer_create` outside `GPUBufferManager` in the targeted systems.
- [ ] Peak VRAM reduced ≥60% in the baseline scenario after pooling.

### M2 -- Hot‑Path Algorithms (P0/P1)

- [ ] Compute and cache `distance_to_coast` using `DistanceTransformCompute.gd` (GPU) when ocean/land changes.
- [ ] Simplify `shaders/climate_adjust.glsl` shore logic: remove 8‑neighbor heavy code; use `distance_to_coast` + simple function.
- [ ] Replace O(n²) BFS in `scripts/generation/ClimateNoise.gd` with GPU distance transform results.

#### Acceptance (M2)

- [ ] Climate pass time improves ≥70% on shore‑heavy maps vs baseline.
- [ ] No CPU BFS code remains in `ClimateNoise.gd`.

### M3 -- Biomes, Plates, Rivers (P0/P1)

- [ ] `BiomeClassifier.gd`: split monolith; cache noise generators; reduce to single main pass (+ optional separable smoothing).
- [ ] `PlateSystem.gd`: GPU label/boundary detection; remove O(n²) neighbor searches; parameterize velocity model.
- [ ] `LakeLabelCompute.gd`: device‑side convergence flag to early‑out.
- [ ] `RiverCompute.gd`: adopt pooling, reduce ping‑pong allocs, avoid CPU sorts where possible, early‑out.

#### Acceptance (M3)

- [ ] Biome classification avoids re‑apply duplication and recreating noise generators per call.
- [ ] No nested O(n²) loops in plate boundary detection hot path.
- [ ] Average iterations reduced for lake/river iterative steps without correctness loss.

### M4 -- Architecture & UI (P1)

- [ ] Decompose `scripts/Main.gd` into controllers; move programmatic UI into scenes.
- [ ] Harden `SettingsDialog.gd` with validation/sanitization and safe node access.

#### Acceptance (M4)

- [ ] `scripts/Main.gd` shrinks substantially; UI is scene‑based; no leaks on exit.

### M5 -- Array Memory Pooling & CPU Cleanup (P1)

- [ ] Introduce `scripts/core/ArrayPool.gd` (new) to manage large `Packed*Array` lifecycles.
- [ ] Refactor `WorldGenerator.gd` to use array pool; remove placeholder validations; vectorize array ops.

#### Acceptance (M5)

- [ ] RAM footprint stable across regenerations; no unbounded growth.

### M6 -- Async/Threading & Simulation Scheduling (P2)

- [ ] Gate `measure_gpu_time()` behind debug; avoid blocking barriers in prod.
- [ ] Improve `Simulation.gd` budgeting: priorities, emergency overrides, less aggressive auto‑tuning.
- [ ] Explore worker threads in `JobSystem.gd` for CPU fallbacks.

#### Acceptance (M6)

- [ ] No long stalls from timing/barriers in release.
- [ ] Stable sim cadence with critical systems protected.

---

## File‑wise To‑Do (with priorities and milestone tags)

### Core & Orchestration

- `scripts/Main.gd` (P0, M4)
  - [x] Add null check before `has_signal` to prevent startup crash (done per report)
  - [ ] Defer GPU renderer initialization until post‑ASCII draw/user toggle
  - [ ] Extract simulation and rendering orchestration into controllers
  - [ ] Replace programmatic UI with `HUD.tscn` scene; connect via signals
  - [ ] Ensure cleanup of GPU/UI resources on stop/exit

- `scripts/core/Simulation.gd` (P2, M6)
  - [ ] Rework performance prediction to avoid skipping critical systems
  - [ ] Introduce priorities and emergency overrides
  - [ ] Tune EMA smoothing per system type

- `scripts/core/TimeSystem.gd` (P2, M6)
  - [ ] Make tick interval configurable
  - [ ] Add pause/resume state validation

- `scripts/core/ErrorHandler.gd` (P2, M0)
  - [ ] Swap `Performance.get_monitor()` memory query with more reliable metric or document limits
  - [ ] Integrate structured JSON logging via `Logger.gd`

- `scripts/core/WorldState.gd` (P0, M1/M2)
  - [ ] Add cached values: height min/max, ocean fraction, last_is_land summary
  - [ ] Invalidate caches on terrain/hydro updates

- `scripts/WorldGenerator.gd` (P0, M5)
  - [ ] Move large `Packed*Array` ownership to `ArrayPool.gd`
  - [ ] Add GPU fallback/cleanup on errors consistently
  - [ ] Replace O(n) counts in hot paths with cached values from `WorldState.gd`
  - [ ] Vectorize lava mask and similar conversions
  - [ ] Remove placeholder validation functions

### GPU Infrastructure

- `scripts/systems/ComputeShaderBase.gd` (P0, M1)
  - [ ] Guard RD acquisition and early‑return with logs if null
  - [ ] Validate push constants size vs shader expectations
  - [ ] Centralize pipeline creation; optional async dispatch API (follow‑up)

- `scripts/systems/ShaderLoader.gd` (P0, M1)
  - [ ] Explicitly select `"vulkan"` SPIR‑V; validate `get_spirv` result
  - [ ] Log shader version/variant used; fail fast with context

- `scripts/systems/GPUBufferManager.gd` (P0, M1)
  - [ ] Complete staging buffer logic (currently commented)
  - [ ] Add `ensure_buffer(key, size, usage)` API used by all compute systems
  - [ ] Track and log total pooled bytes; expose for HUD
  - [ ] Provide GPU clear shader path to avoid CPU fills
  - [ ] Optional async large buffer updates

- `scripts/systems/GPUBufferHelper.gd` (P0, M6)
  - [ ] Replace inefficient byte↔u32 loops with typed views or batched operations
  - [ ] Gate `measure_gpu_time()` behind a debug flag; avoid blocking barriers in prod
  - [ ] Validate buffer sizes before ops

- `scripts/systems/Logger.gd` (P1, M0)
  - [ ] Ensure JSON structured fields: `module`, `op`, `status`, `bytes`, `ms`, `rd_available`

- `scripts/rendering/GPUAsciiRenderer.gd` (P1, M1/M4)
  - [ ] Defer RD init; wrap failures and fallback to CPU ASCII path
  - [ ] Add early logs around device/pipeline creation

### Compute Systems (High Impact First)

- `scripts/systems/BiomeCompute.gd` (P0, M1/M3)
  - [ ] Replace direct RD buffer creation with `GPUBufferManager`
  - [ ] Cache min/max and ocean fraction from `WorldState.gd`
  - [ ] Reduce to a single classification pass when possible
  - [ ] Cleanup buffers immediately after last use; minimize readbacks

- `scripts/systems/ClimateAdjustCompute.gd` (P0, M2)
  - [ ] Consume `distance_to_coast` field; remove heavy 8‑neighbor work from shader
  - [ ] Use pooled buffers and avoid repeated alloc/dealloc

- `scripts/systems/FlowCompute.gd` (P1, M1)
  - [ ] Adopt pooled buffers; limit readbacks; batch dispatches

- `scripts/systems/RiverCompute.gd` (P0, M3)
  - [ ] Pool all persistent and ping‑pong buffers
  - [ ] Avoid CPU sorts where possible; pre‑filter on GPU
  - [ ] Early‑out when convergence reached; cut redundant passes

- `scripts/systems/LakeLabelCompute.gd` (P1, M3)
  - [ ] Add device‑side convergence flag/buffer and break loop early

- `scripts/systems/TerrainCompute.gd` (P1, M1)
  - [ ] Unify GPU/CPU resource cleanup; ensure consistent results validation
  - [ ] Move GPU pipeline creation out of hot path

- `scripts/systems/DistanceTransformCompute.gd` (P1, M2)
  - [ ] Ensure RD guards; expose reusable `distance_to_coast(ocean_mask)` API

- `scripts/systems/CloudOverlayCompute.gd` (P2, M1)
  - [ ] Adopt pooling; minor cleanup

- `scripts/systems/PlateUpdateCompute.gd` (P2, M1)
  - [ ] Adopt pooling; ensure buffer size validation

### CPU Generation/Logic

- `scripts/generation/BiomeClassifier.gd` (P1, M3)
  - [ ] Split `classify()` into smaller helpers; cache noise per instance
  - [ ] Reduce to single pass (+ optional separable smoothing)
  - [ ] Fix boreal forest recursion condition

- `scripts/generation/ClimateNoise.gd` (P0, M2)
  - [ ] Remove O(n²) BFS; use GPU distance transform results
  - [ ] Remove redundant ocean counting; accept as parameter or from `WorldState`
  - [ ] Parameterize magic numbers; add bounds checks

- `scripts/generation/TerrainNoise.gd` (P3, M6)
  - [ ] Optional: parameterize gamma/scaling; ensure consistent falloff behavior

### Simulation Systems

- `scripts/systems/PlateSystem.gd` (P0, M3)
  - [ ] Replace neighbor O(n²) searches with GPU label/boundary maps
  - [ ] Parameterize and validate plate velocities (zonal + perturbations)
  - [ ] Add bounds checks for uplift ops; simplify divergence score

- `scripts/systems/SeasonalClimateSystem.gd` (P1, M3)
  - [ ] Deduplicate CPU vs GPU light logic (extract shared helper)
  - [ ] Remove redundant `_light_update_counter` increment
  - [ ] Simplify config fallback chains
  - [ ] Add error handling for GPU failures

- `scripts/systems/VolcanismSystem.gd` (P3, M3)
  - [ ] Simplify null checks; validate compute results

### UI & Style

- `scripts/SettingsDialog.gd` (P1, M4)
  - [ ] Replace hardcoded node paths with exported NodePaths or lookups with validation
  - [ ] Add bounds checking and input sanitization
  - [ ] Emit clear signals; handle apply/cancel safely

- `scripts/style/AsciiStyler.gd` (P2, M6)
  - [ ] Ensure compatibility with async styling; avoid blocking operations

- `scripts/style/AsyncAsciiStyler.gd` (P2, M6)
  - [ ] Complete implementation and integrate behind a feature flag

### Shaders

- `shaders/climate_adjust.glsl` (P0, M2)
  - [ ] Remove 8‑neighbor shore calc; sample `distance_to_coast` and apply simple attenuation model
  - [ ] Reduce bilinear sampling count; document uniforms/bindings

- `shaders/biome_classify.glsl` (P1, M3)
  - [ ] Reduce neighbor sampling; prefer separable smoothing
  - [ ] Remove redundant functions; document layout bindings

- `shaders/river_trace.glsl` (P1, M3)
  - [ ] Mitigate atomicAdd contention (bucketing/tiles or prefix sums)
  - [ ] Improve write patterns to reduce scatter

- `shaders/distance_transform.glsl` (P1, M2)
  - [ ] Verify wrap logic and branching; expose uniform for forward/backward modes

### New Files to Add

- `scripts/controllers/SimulationController.gd` (P1, M4)
  - [ ] Orchestrates simulation systems, priorities, and budgets

- `scripts/controllers/RenderController.gd` (P1, M4)
  - [ ] Manages ASCII renderer lifecycle, toggles, and fallbacks

- `scenes/UI/HUD.tscn` + `scripts/ui/HUD.gd` (P1, M0/M4)
  - [ ] Displays metrics and toggles; decoupled from `Main.gd`

- `scripts/core/ArrayPool.gd` (P1, M5)
  - [ ] Central manager for large arrays with acquire/release API

---

## PR Breakdown (suggested)

1) PR‑M0‑logs: Logger JSON + baseline capture + HUD toggle.
2) PR‑M1‑rd‑safety: RD guards in `ComputeShaderBase` + `ShaderLoader` validation.
3) PR‑M1‑pooling‑core: Adopt `GPUBufferManager` in Biome/Climate/River compute.
4) PR‑M2‑shore‑distance: Add `distance_to_coast` + simplify `climate_adjust.glsl`.
5) PR‑M2‑climate‑bfs‑gpu: Remove BFS in `ClimateNoise.gd`; use GPU distance.
6) PR‑M3‑biome‑simplify: Rework `BiomeClassifier.gd` and shader smoothing.
7) PR‑M3‑plates‑gpu: Plate boundary via GPU; velocity model; bounds checks.
8) PR‑M3‑iter‑earlyout: Early‑out in lake/river iterative compute.
9) PR‑M4‑ui‑decompose: Controllers + HUD scene; slim `Main.gd`; harden `SettingsDialog.gd`.
10) PR‑M5‑array‑pool: Introduce `ArrayPool.gd`; refactor `WorldGenerator.gd`.
11) PR‑M6‑async‑budget: Remove blocking barriers; improve `Simulation.gd` budgeting.

## Definition of Done (per milestone)

- M1: No raw RD buffer creation in targeted systems; RD/shader logs present; no RD‑related crashes.
- M2: Shore computation simplified; climate pass speedup ≥70%; no CPU BFS.
- M3: No O(n²) plate neighbor loops; biome pass reduced; iterative systems early‑out.
- M4: `Main.gd` largely orchestration; UI scene‑based; no leaks on stop/exit.
- M5: Stable RAM across regenerations; big arrays pooled.
- M6: No production blocking barriers; stable sim cadence under budget.

## Notes

- Items explicitly marked ✅ in the review (startup null‑check, scene path fix) are considered done and excluded from scope.
- Prefer small atomic PRs with clear logs and metrics deltas in each description.
