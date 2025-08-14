<!-- File: docs/PERFORMANCE_ARCH_REFACTOR_TODO.md -->

## Performance & Architecture Refactor — TODO

### Goals
- Achieve near–real-time simulation updates on mid-size maps by eliminating avoidable GPU passes, cutting CPU↔GPU roundtrips, and amortizing work spatially and temporally.
- Preserve visual fidelity and physical plausibility; no loss of detail or features.
- Standardize GPU pipelines around persistent SSBOs, convergence-aware loops, ROI processing, and time budgets.

### Priority hotspots (observed)
1) Lake pooling (depression fill) and lake labeling — fixed high iteration counts, no convergence early-outs; always full-domain.
2) Rivers — full-map retrace after each ROI flow update.
3) Frequent GPU→CPU readbacks and ASCII string rebuilds.
4) Multi-pass post (biome smooth/reapply, mountain radiance) with small kernels; could be fused or reduced.

### Core strategies
- Convergence-aware GPU loops:
  - Introduce a device-side flag/bit that any workgroup sets when it updates a value. After each iteration, read one byte (or a small counter) to determine if another pass is required. Exit early when converged.
  - Apply to: `depression_fill.glsl` (E relaxation), `lake_label_from_mask.glsl` (propagation), `river_meander.glsl` (optional capped iterations), any iterative smoothing.

- ROI and tiling everywhere:
  - Extend shaders to accept `[x0,y0,w,h]` ROI where safe and iterate only within bounds.
  - Flow/accumulation already supports ROI; add ROI to rivers (trace only changed basins and a coastal/pour-point band) and to lake label/mark passes.

- Persistent SSBOs & reduced readbacks:
  - Allocate long-lived buffers (`height`, `is_land`, `dist`, `temperature`, `moisture`, `precip`, `wind_u/v`, `cloud_cov`, `biome_id`, `lava`, `river`, `lake`, `lake_id`, `light`) once per map and reuse.
  - Keep results on GPU; read back only when needed for ASCII redraws and point-inspect UI.
  - Consider half-precision for temp/moist/precip/cloud/light on GPU; convert to f32 on CPU readback if necessary.

- Pass fusion / cadence reduction:
  - Biomes: smooth + reapply can be fused or executed every N redraws, not every climate update.
  - Mountain radiance: fewer passes with slightly broader kernel or bake into climate adjust as a single optional neighborhood.

- Scheduler and budgets:
  - Time-based budget (ms/tick) is already implemented; extend with GPU timings per pass and queue only what fits the frame budget.
  - Increase ASCII redraw cadence for larger maps; adaptively lower redraw rate when frame time exceeds threshold.

### Detailed tasks (by subsystem)

#### Hydrology (Pooling, Flow, Rivers)
- Depression fill (`depression_fill.glsl`):
  - [ ] Add convergence flag buffer; stop early when no updates.
  - [ ] Lower default max iterations (e.g., 32–48) and scale with map height (H).
  - [ ] Expose ROI path to fill only affected tiles after local sea-level or height edits.
- Lake labeling (`lake_label_from_mask.glsl`):
  - [ ] Same convergence flag; break at steady state.
  - [ ] Add ROI bound; process tiles intersecting changed lake mask.
- Pour point reduction (`lake_mark_boundary_candidates.glsl`):
  - [ ] ROI inputs; optional compaction to a candidate list on GPU to reduce CPU scan volume.
- Flow/accum (`flow_dir/accum/push`):
  - [ ] Preserve ROI (exists);
  - [ ] Early-exit push when `frontier` becomes empty by tracking global frontier count (u32 sum) per pass.
- Rivers:
  - [ ] Trace only ROIs influenced by changed flow_dir/accum or near updated lakes. Maintain a queue of seed IDs in changed basins.
  - [ ] Amortize full retrace across ticks (tiling) when ROI list exceeds a threshold.
  - [ ] Merge delta widening with trace or run at a lower cadence.

#### Climate & Biomes
- Climate adjust:
  - [ ] Two-path execution: full recompute vs. cycles-only update (see SEASONS_DIURNAL).
  - [ ] Persist temp/moist buffers; read back only on redraw.
- Biomes:
  - [ ] Run classification at a cadence aligned with redraw, not every climate refresh.
  - [ ] Consider single-pass classifier with embedded small smoothing kernel; remove extra pass for small H.

#### Clouds & Wind
- [ ] Keep wind update cadence moderate (10–20 ticks); compute-only when needed.
- [ ] Cloud advection already GPU; ensure no readback until redraw.
- [ ] Optional: pack cloud coverage to 8-bit on GPU to reduce bandwidth; unpack in ASCII.

#### Plates & Volcanism
- [ ] Plate boundary updates at slow cadence; ensure buffers are persistent and read back only for UI.
- [ ] Volcanism: keep GPU-only; consider packing lava mask as 1 bit per cell for memory/compression.

#### ASCII & UI
- [ ] Limit redraw cadence (e.g., every 6–10 ticks at ≥ 400×100 maps); expose UI control.
- [ ] Use GPU `light_field` and optional `cloud_shadow` to reduce CPU-side computations.
- [ ] Consider non-BBCode render path (bitmap font atlas) for large maps to avoid huge strings.
- [ ] When using BBCode, minimize per-glyph allocations by reusing builders and avoiding intermediate strings.

### Architectural cleanups
- WorldState-first data flow:
  - [ ] Transition systems to read/write `WorldState` buffers directly; keep `WorldGenerator.last_*` as thin views.
- Dirty-field propagation:
  - [ ] Each system returns `dirty_fields` plus an optional `dirty_rects` list; dependent systems process only ROIs.
- Determinism & RNG:
  - [ ] Replace ad-hoc RNG calls with stateless hashed RNG using `(seed, system, tick[, x,y])` to ensure cadence-independence.
- GPU timing & budget:
  - [ ] Instrument compute passes; maintain rolling averages; have `Simulation` skip passes that would exceed `max_tick_time_ms`.

### Acceptance metrics
- 2–4× speedup in lake pooling/labeling on typical sizes due to convergence early-outs.
- 1.5–3× reduction in hydro tick time via ROI river tracing.
- ≤ 1 readback per redraw frame; redraw cadence ≥ 5 ticks at default resolutions.
- No visual fidelity regressions in climate/biomes/rivers.

### Migration plan (phased)
1) Convergence flags: implement in lake fill and label; tune iterations; validate correctness.
2) ROI rivers: add basin/edge queues and amortized retrace; validate connectivity.
3) Persistent SSBOs + reduced readbacks across climate/biomes/clouds.
4) Scheduler timings: integrate GPU timings and enforce time budgets.
5) ASCII path improvements (optional atlas).

### Files to touch (non-exhaustive)
- `shaders/depression_fill.glsl`, `scripts/systems/DepressionFillCompute.gd`
- `shaders/lake_label_from_mask.glsl`, `scripts/systems/LakeLabelFromMaskCompute.gd`
- `shaders/flow_push.glsl`, `scripts/systems/FlowCompute.gd`
- `scripts/systems/RiverCompute.gd`, `scripts/systems/RiverPostCompute.gd`, `scripts/systems/RiverMeanderCompute.gd`
- `scripts/systems/ClimateAdjustCompute.gd`, `shaders/climate_adjust.glsl`, `shaders/cycle_apply.glsl` (new)
- `scripts/systems/BiomeCompute.gd`, `shaders/biome_*.glsl`
- `scripts/systems/CloudWindSystem.gd`, `shaders/cloud_*.glsl`, `shaders/day_night_light.glsl` (new)
- `scripts/core/Simulation.gd` (GPU timing integration)
- `scripts/style/AsciiStyler.gd`, `scripts/Main.gd`


