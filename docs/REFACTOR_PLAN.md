# WorldGen Refactor Plan -- Incremental, File‑wise To‑Do

<!-- File: docs/REFACTOR_PLAN.md -->

## Goals and KPIs

- Runtime direction: GPU-only simulation and rendering pipeline (no CPU/GPU runtime toggles).

- **Stability**: 0 startup crashes from RD init in GPU-only runtime.
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

- [~] Add structured JSON logs in `scripts/systems/Logger.gd` (level, context, device status, buffer stats). (scaffold implemented; call sites pending)
- [~] Add on‑screen dev HUD toggle (basic stats) via `DevHudOverlay` (implemented in `scripts/gameplay/ui/DevHudOverlay.gd`, toggled with `F3`).
- [~] Capture baseline metrics and store in `docs/perf/baseline-YYYYMMDD.md`. (initial capture scaffold in `docs/perf/baseline-20260210.md`; full perf numbers pending)

#### Acceptance (M0)

- [~] Logs include RD availability, shader backend, pipeline creation success/failure, buffer alloc/reuse, readbacks. (major shader/compute call sites wired; remaining systems pending)
- [~] Baseline doc checked in with reproducible settings. (initial capture doc added; iterative updates pending)

### M1 -- RD Safety + Shader Loading + Buffer Pooling (P0)

- [~] Centralize RD acquisition in `scripts/systems/ComputeShaderBase.gd`; early return on null with clear error. (helper added and adopted by society compute wrappers)
- [~] Enforce explicit SPIR‑V selection in `scripts/systems/ShaderLoader.gd` (e.g., "vulkan"); validate non‑null spirv. (vulkan preference + non-null SPIR-V validation implemented)
- [~] Adopt `GPUBufferManager.gd` across: `BiomeCompute.gd`, `ClimateAdjustCompute.gd`, `RiverCompute.gd`. (scaffold pooled buffers + RD guard plumbing implemented)
- [~] Initialize renderer RD only after capability checks and robust startup guards in `GPUAsciiRenderer.gd` / `Main.gd`. (deferred init + capability checks in `RenderController`; broader startup sequencing pending)

#### Acceptance (M1)

- [~] No RD calls if device is null; fail clearly and log diagnostics (GPU-only mode). (covered in adopted wrappers; broader coverage pending)
- [x] No raw `storage_buffer_create` outside `GPUBufferManager` in the targeted systems.
- [ ] Peak VRAM reduced ≥60% in the baseline scenario after pooling.

### M2 -- Hot‑Path Algorithms (P0/P1)

- [~] Compute and cache `distance_to_coast` using `DistanceTransformCompute.gd` (GPU) when ocean/land changes. (buffer APIs wired; broader change-trigger caching still pending)
- [~] Simplify `shaders/climate_adjust.glsl` shore logic: remove 8‑neighbor heavy code; use `distance_to_coast` + simple function. (distance-based attenuation scaffolded)
- [~] Replace O(n²) BFS in `scripts/generation/ClimateNoise.gd` with GPU distance transform results. (legacy BFS removed; linear fallback retained if shared GPU field missing)

#### Acceptance (M2)

- [ ] Climate pass time improves ≥70% on shore‑heavy maps vs baseline.
- [x] No CPU BFS code remains in `ClimateNoise.gd`.

### M3 -- Biomes, Plates, Rivers (P0/P1)

- [~] `BiomeClassifier.gd`: split monolith; cache noise generators; reduce to single main pass (+ optional separable smoothing). (split helpers + per-instance noise cache + optional smoothing toggle scaffolded)
- [~] `PlateSystem.gd`: GPU label/boundary detection; remove O(n²) neighbor searches; parameterize velocity model. (velocity model params/validation scaffolded; coarse GPU boundary readback cadence added)
- [~] `LakeLabelCompute.gd`: device‑side convergence flag to early‑out. (convergence flag buffer + periodic early break scaffolded)
- [~] `RiverCompute.gd`: adopt pooling, reduce ping‑pong allocs, avoid CPU sorts where possible, early‑out. (pooling done; active-frontier early-out scaffolded; GPU pre-filter/sort follow-up pending)

#### Acceptance (M3)

- [~] Biome classification avoids re‑apply duplication and recreating noise generators per call. (noise/rules reuse scaffolded; follow-up pass reduction pending)
- [~] No nested O(n²) loops in plate boundary detection hot path. (core boundary detection stays GPU-side; render mask follow-up remains)
- [~] Average iterations reduced for lake/river iterative steps without correctness loss. (early-out + per-dispatch iteration telemetry now exposed; benchmark confirmation pending)

### M4 -- Architecture & UI (P1)

- [~] Decompose `scripts/Main.gd` into controllers; move programmatic UI into scenes. (controller + HUD scaffolds wired; full decomposition pending)
- [~] Harden `SettingsDialog.gd` with validation/sanitization and safe node access. (new dialog scaffold added with exported NodePaths, sanitizers, and apply/cancel signals; scene wiring pending)

#### Acceptance (M4)

- [ ] `scripts/Main.gd` shrinks substantially; UI is scene‑based; no leaks on exit.
- [x] High-speed validation extracted from `scripts/Main.gd` to `scripts/core/HighSpeedValidator.gd`.

### M5 -- Array Memory Pooling & CPU Cleanup (P1)

- [x] Introduce `scripts/core/ArrayPool.gd` (new) to manage large `Packed*Array` lifecycles.
- [~] Refactor `WorldGenerator.gd` to use array pool; remove placeholder validations; vectorize array ops. (temp zero/lava scratch arrays now routed through `ArrayPool`; broader ownership migration pending)

#### Acceptance (M5)

- [ ] RAM footprint stable across regenerations; no unbounded growth.

### M6 -- Async/Threading & Simulation Scheduling (P2)

- [x] Gate `measure_gpu_time()` behind debug; avoid blocking barriers in prod.
- [~] Improve `Simulation.gd` budgeting: priorities, emergency overrides, less aggressive auto‑tuning. (priority/emergency/EMA scaffolds added; deeper auto-tuning pass pending)
- [~] Explore worker threads in `JobSystem.gd` for CPU fallbacks. (threaded stripe execution scaffold added; default stays off and call-site adoption is pending)

#### Acceptance (M6)

- [ ] No long stalls from timing/barriers in release.
- [ ] Stable sim cadence with critical systems protected.

---

## File‑wise To‑Do (with priorities and milestone tags)

### Core & Orchestration

- `scripts/Main.gd` (P0, M4)
  - [x] Add null check before `has_signal` to prevent startup crash (done per report)
  - [~] Defer GPU renderer initialization until post‑ASCII draw/user toggle (deferred call in runtime setup; optional user-toggle policy pending)
  - [~] Extract simulation and rendering orchestration into controllers (scaffold: `SimulationController` + `RenderController` wired; hover info formatting moved to `HoverInfoController`)
  - [~] Replace programmatic UI with `HUD.tscn` scene; connect via signals (scaffold HUD scene added + runtime metrics updates)
  - [~] Ensure cleanup of GPU/UI resources on stop/exit (expanded `_exit_tree` cleanup for renderer + sim signal disconnect + system cleanup hooks + generator GPU cleanup)

- `scripts/core/Simulation.gd` (P2, M6)
  - [~] Rework performance prediction to avoid skipping critical systems (prediction floor + emergency path scaffolded)
  - [~] Introduce priorities and emergency overrides (per-system controls + scheduling order scaffolded)
  - [~] Tune EMA smoothing per system type (per-system EMA alpha controls scaffolded)

- `scripts/core/TimeSystem.gd` (P2, M6)
  - [~] Make tick interval configurable (scaffold: `tick_hz`, `set_tick_hz`, `set_tick_interval_seconds`)
  - [~] Add pause/resume state validation (scaffold: guarded `start/pause` + `resume()` API)

- `scripts/core/ErrorHandler.gd` (P2, M0)
  - [~] Swap `Performance.get_monitor()` memory query with more reliable metric or document limits (limits documented; better metric still pending)
  - [~] Integrate structured JSON logging via `Logger.gd` (scaffold logging hook added)

- `scripts/core/WorldState.gd` (P0, M1/M2)
  - [~] Add cached values: height min/max, ocean fraction, last_is_land summary (scaffold cache fields + recompute APIs added)
  - [~] Invalidate caches on terrain/hydro updates (scaffold invalidation hooks added in configure/allocate/clear)

- `scripts/WorldGenerator.gd` (P0, M5)
  - [x] Remove legacy CPU/GPU toggle branches (`use_gpu_all`, `use_gpu_clouds`, `use_gpu_pooling`) for GPU-only runtime.
  - [~] Move large `Packed*Array` ownership to `ArrayPool.gd` (scaffold: pooled scratch arrays for boundary/lake/metrics/lava staging)
  - [~] Add GPU fallback/cleanup on errors consistently (scaffold helper `_handle_gpu_failure(...)` now centralizes overlay reset/cache invalidation in key generation/update failure paths)
  - [~] Replace O(n) counts in hot paths with cached values from `WorldState.gd` (ocean-fraction count now routes through `WorldState` land cache in generation/sea-level update paths)
  - [~] Vectorize lava mask and similar conversions (byte->u32 mask conversion centralized via batched helper; lava-specific path still pending)
  - [x] Remove placeholder validation functions

### GPU Infrastructure

- `scripts/systems/ComputeShaderBase.gd` (P0, M1)
  - [x] Guard RD acquisition and early‑return with logs if null
  - [x] Validate push constants size vs shader expectations
  - [~] Centralize pipeline creation; optional async dispatch API (follow‑up)

- `scripts/systems/ShaderLoader.gd` (P0, M1)
  - [x] Explicitly select `"vulkan"` SPIR‑V; validate `get_spirv` result
  - [x] Log shader version/variant used; fail fast with context

- `scripts/systems/GPUBufferManager.gd` (P0, M1)
  - [~] Complete staging buffer logic (currently commented)
  - [~] Add `ensure_buffer(key, size, usage)` API used by all compute systems
  - [~] Track and log total pooled bytes; expose for HUD
  - [~] Provide GPU clear shader path to avoid CPU fills
  - [~] Optional async large buffer updates (deferred update queue + configurable threshold/flush scaffold added)

- `scripts/systems/GPUBufferHelper.gd` (P0, M6)
  - [~] Replace inefficient byte↔u32 loops with typed views or batched operations (batched byte-mask conversion helper added)
  - [x] Gate `measure_gpu_time()` behind a debug flag; avoid blocking barriers in prod
  - [~] Validate buffer sizes before ops (RD/shader/buffer validation guards added on core helpers)

- `scripts/systems/Logger.gd` (P1, M0)
  - [~] Ensure JSON structured fields: `module`, `op`, `status`, `bytes`, `ms`, `rd_available`

- `scripts/rendering/GPUAsciiRenderer.gd` (P1, M1/M4)
  - [~] Defer RD init; wrap failures and fail clearly (no CPU visual fallback; GPU-only is canonical) (RD guards + strict init validation scaffolded)
  - [~] Add early logs around device/pipeline creation (GPU init success/failure logs scaffolded)

### Compute Systems (High Impact First)

- `scripts/systems/BiomeCompute.gd` (P0, M1/M3)
  - [~] Replace direct RD buffer creation with `GPUBufferManager` (dummy/working buffers pooled; remaining passes can be folded in later)
  - [~] Cache min/max and ocean fraction from `WorldState.gd` (classification params accept `world_state_metrics`; `WorldGenerator`/`BiomeUpdateSystem` now forward cached metrics)
  - [~] Reduce to a single classification pass when possible (main classify pass now explicit; optional lazy smooth pass controlled via params)
  - [~] Cleanup buffers immediately after last use; minimize readbacks (pooled cleanup path added)

- `scripts/systems/ClimateAdjustCompute.gd` (P0, M2)
  - [~] Consume `distance_to_coast` field; remove heavy 8‑neighbor work from shader (shoreline attenuation simplified to distance-based model)
  - [~] Use pooled buffers and avoid repeated alloc/dealloc

- `scripts/systems/FlowCompute.gd` (P1, M1)
  - [~] Adopt pooled buffers; limit readbacks; batch dispatches

- `scripts/systems/RiverCompute.gd` (P0, M3)
  - [~] Pool all persistent and ping‑pong buffers
  - [~] Avoid CPU sorts where possible; pre‑filter on GPU (unused CPU quantile/sort helper removed; active river source threshold now uses GPU-friendly estimate path)
  - [~] Early‑out when convergence reached; cut redundant passes (active-frontier flag + break scaffold, plus per-dispatch iteration stats exposed)

- `scripts/systems/LakeLabelCompute.gd` (P1, M3)
  - [~] Add device‑side convergence flag/buffer and break loop early (device flag + periodic host check scaffold, plus per-dispatch iteration stats exposed)

- `scripts/systems/TerrainCompute.gd` (P1, M1)
  - [~] Unify GPU/CPU resource cleanup; ensure consistent results validation (cleanup + pooled intermediates scaffolded; validation follow-up pending)
  - [~] Move GPU pipeline creation out of hot path (terrain + fbm pipelines cached via `ComputeShaderBase`)

- `scripts/systems/DistanceTransformCompute.gd` (P1, M2)
  - [~] Ensure RD guards; expose reusable `distance_to_coast(ocean_mask)` API (buffer API + land-mask upload scaffold added)

- `scripts/systems/CloudOverlayCompute.gd` (P2, M1)
  - [~] Adopt pooling; minor cleanup

- `scripts/systems/PlateUpdateCompute.gd` (P2, M1)
  - [~] Adopt pooling; ensure buffer size validation

### CPU Generation/Logic

- `scripts/generation/BiomeClassifier.gd` (P1, M3)
  - [~] Split `classify()` into smaller helpers; cache noise per instance (helper pass layout + cached noise/rules instances added)
  - [~] Reduce to single pass (+ optional separable smoothing) (optional smoothing toggle added; separable variant pending)
  - [x] Fix boreal forest recursion condition

- `scripts/generation/ClimateNoise.gd` (P0, M2)
  - [~] Remove O(n²) BFS; use GPU distance transform results (BFS removed; linear fallback used when GPU field absent)
  - [~] Remove redundant ocean counting; accept as parameter or from `WorldState` (accepts `ocean_fraction` param; fallback counting retained)
  - [~] Parameterize magic numbers; add bounds checks (core frequencies/advection constants extracted + input size validation added)

- `scripts/generation/TerrainNoise.gd` (P3, M6)
  - [~] Optional: parameterize gamma/scaling; ensure consistent falloff behavior (height gamma/contrast + island falloff knobs scaffolded)

### Simulation Systems

- `scripts/systems/PlateSystem.gd` (P0, M3)
  - [~] Replace neighbor O(n²) searches with GPU label/boundary maps (GPU boundary buffer readback + cached render mask scaffolded)
  - [~] Parameterize and validate plate velocities (zonal + perturbations) (config-driven velocity model + magnitude clamps scaffolded)
  - [~] Add bounds checks for uplift ops; simplify divergence score (rate clamps + per-day boundary delta clamp + divergence response knob scaffolded)

- `scripts/systems/SeasonalClimateSystem.gd` (P1, M3)
  - [~] Deduplicate CPU vs GPU light logic (extract shared helper) (new shared `_extract_time_state(...)` helper now feeds both climate tick and light update paths)
  - [x] Remove redundant `_light_update_counter` increment
  - [~] Simplify config fallback chains (light update now uses resolved config object instead of repeated fallback chain)
  - [~] Add error handling for GPU failures (structured warnings for missing compute/config/buffers and failed GPU update)

- `scripts/systems/VolcanismSystem.gd` (P3, M3)
  - [~] Simplify null checks; validate compute results (ready-state guard + compute/buffer validation scaffolded)

### UI & Style

- `scripts/SettingsDialog.gd` (P1, M4)
  - [~] Replace hardcoded node paths with exported NodePaths or lookups with validation
  - [~] Add bounds checking and input sanitization
  - [~] Emit clear signals; handle apply/cancel safely

- `scripts/style/AsciiStyler.gd` (P2, M6)
  - [~] Ensure compatibility with async styling; avoid blocking operations (`build_ascii_rows(...)` chunk-friendly API added)

- `scripts/style/AsyncAsciiStyler.gd` (P2, M6)
  - [~] Complete implementation and integrate behind a feature flag (feature flag in `WorldConstants`; chunked row-based generation with progress/cancel)

### Shaders

- `shaders/climate_adjust.glsl` (P0, M2)
  - [~] Remove 8‑neighbor shore calc; sample `distance_to_coast` and apply simple attenuation model (distance-based shoreline attenuation scaffolded)
  - [~] Reduce bilinear sampling count; document uniforms/bindings (moisture advection switched to point sampling + binding/push-constant table comments)

- `shaders/biome_classify.glsl` (P1, M3)
  - [~] Reduce neighbor sampling; prefer separable smoothing (orthogonal-only moisture neighbor blend in classify; smoothing delegated to dedicated pass)
  - [~] Remove redundant functions; document layout bindings (layout summary comments added; further cleanup optional)

- `shaders/river_trace.glsl` (P1, M3)
  - [~] Mitigate atomicAdd contention (bucketing/tiles or prefix sums) (atomicCompSwap boolean frontier claims replaced additive atomics)
  - [~] Improve write patterns to reduce scatter (skip already-river cells and only flag active on newly claimed frontier cells)

- `shaders/distance_transform.glsl` (P1, M2)
  - [~] Verify wrap logic and branching; expose uniform for forward/backward modes (mode push constant retained; wrap-X neighbor bounds fixed for both passes)

### New Files to Add

- `scripts/controllers/SimulationController.gd` (P1, M4)
  - [~] Orchestrates simulation systems, priorities, and budgets (scaffold API + Main wiring done)

- `scripts/controllers/RenderController.gd` (P1, M4)
  - [~] Manages ASCII renderer lifecycle, toggles, and fallbacks (GPU-only lifecycle scaffold wired)

- `scenes/ui/HUD.tscn` + `scripts/ui/HUD.gd` (P1, M0/M4)
  - [~] Displays metrics and toggles; decoupled from `Main.gd` (scene scaffold + periodic metrics wired)

- `scripts/core/ArrayPool.gd` (P1, M5)
  - [x] Central manager for large arrays with acquire/release API

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
