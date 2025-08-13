# File: docs/REALISTIC_POOLING_REFACTOR.md

## Realistic Depression Pooling & Outflow Refactor (CPU + GPU Parity)

### Why

- Current lake detection labels any inland water not connected to the map edge as a lake (connectivity only). It does not compute depression fill to spill levels, so lakes look like uniform buffers around rivers rather than basin-conforming pools.
- We want physically plausible pooling: water fills a closed depression to its pour (spill) elevation, then overflows at one or more outflow points. Rivers continue from those outflows, allowing chained lake->river->lake successions and multi-outlet deltas near the ocean.
- CPU and GPU must produce the same result deterministically (given RNG seed) and share identical logic.

### Goals

- Fill each closed basin to its spill elevation (no partial fill) to generate a lake mask that conforms to topography.
- Spawn downstream rivers at the basin’s pour point(s). Always include the primary (lowest) pour point; allow up to 6 total outflows with probability that increases closer to the ocean and deeper in the downstream chain.
- Maintain CPU/GPU parity: same lake mask, same pour points, same river network, given identical inputs and RNG seed.
- Keep wrap-X behavior consistent.

### Glossary

- `H` (float32): terrain height field (noise-based in our pipeline)
- `L` (u8): land mask (1=land, 0=water/ocean, derived via sea level)
- `E` (float32): filled drainage level per cell (minimax or "priority-flood" level)
- `LakeMask` (u8): 1 where `E > H` on land; the portion of basins submerged at spill level
- `LakeId` (i32): connected-component labels for `LakeMask`
- `SpillElevation` (float): pour level of a basin (lowest saddle to outside)
- `PourPoint` (int index): a cell (or boundary pair) that represents an outflow location at `SpillElevation`
- `FlowDir` (i32): D8 steepest descent index per land cell
- `FlowAccum` (float32): count of upstream contributors per land cell

### High-level algorithm

1) Flow prep
- Compute D8 `FlowDir` on `H` for all land cells.
- Compute `FlowAccum` (CPU: topo-sorted add; GPU: iterative push with atomics).

2) Depression fill (strict spill level)
- Compute `E` such that for any cell, `E[i]` is the minimum elevation needed to reach the boundary without descending below `H` (minimax path). Practically:
  - Initialize boundary cells `E[b] = H[b]`.
  - Relax repeatedly with `E[n] = min(E[n], max(H[n], E[i]))` over neighbors until convergence.
- `LakeMask = (L == 1) AND (E > H)`.
- Label `LakeMask` components into `LakeId`.

3) Pour points and spill elevation
- For each lake component, enumerate boundary saddles by scanning each inside cell `i` and its non-lake neighbor `o`:
  - Saddle cost `c = max(H[i], H[o])`.
  - Candidate pour edges are `(i, o, c)` where `o` drains to outside of the lake.
- Sort candidates ascending by `c`; the first is the primary pour point. Define `SpillElevation = c_min` for the lake.

4) Outflow selection and seeding
- Always include the primary pour point. Allow up to 5 additional outflows (max total 6) from the next-lowest candidates using a probability that increases:
  - Closer to the ocean (using distance-to-ocean field)
  - Deeper in the downstream chain (number of prior lake→outflow steps)
- Construct `ForcedSeeds` as the set of chosen pour-point indices.
- Keep existing percentile+NMS seeds for tributaries and OR them with `ForcedSeeds`.

5) River tracing and pruning
- Trace downstream from seeds along `FlowDir`, stopping at ocean or lake; avoid crossing lakes.
- Prune segments shorter than `min_river_length`.

### CPU implementation plan

- File: `scripts/systems/FlowErosionSystem.gd`
  - DONE: Step 1 keep D8 `FlowDir` and `FlowAccum` as-is.
  - DONE: Step 2b basin assignment via following `flow_dir` to sinks.
  - DONE: Step 2c strict fill to `SpillElevation` for each basin; compute `LakeMask = (H < SpillElevation) ∧ L` per basin; collect and sort pour candidates `(i, o, c)`.
  - DONE: Seeding — select 0–3 outflows per lake with weighted bias towards 0–1; OR with percentile+NMS seeds.
  - DONE: Tracing — keep “stop at ocean or lakes”; prune by min length.
  - DONE: Outputs extended:
    - `flow_dir`, `flow_accum`, `river`, `lake`, `lake_id`, `lake_level`, `outflow_seeds`, `pour_points`.
  - TODO: Honor `wrap_x` in neighbor checks during pooling/labeling for perfect parity with GPU.

### GPU implementation plan (two phases)

Phase 1 — Parity-first (fastest to ship)

- DONE: Compute strict pooling and `ForcedSeeds` on CPU.
- DONE: Upload `LakeMask`, `FlowDir`, `FlowAccum`, and pre-stage `ForcedSeeds` in the seeds buffer; then run `river_seed_nms.glsl` to OR in percentile+NMS seeds; trace via `river_trace.glsl`.
- Result: GPU tracer honors forced outflows and stops at lakes/ocean.

Phase 2 — All-GPU fill (optional optimization)

- DONE: Added `shaders/depression_fill.glsl` implementing minimax relaxation for `E` and `scripts/systems/DepressionFillCompute.gd` to orchestrate iterations.
  - Inputs: `Height` (R32F), `IsLand` (R32U), `wrap_x` push-constant.
  - Outputs: `DrainElev` (R32F). Compute `LakeMask = (DrainElev > Height) ∧ (IsLand == 1)`.
  - Convergence: iterate a fixed number or until no-change flag remains unset (atomic counter). For first version, bound iterations (e.g., O(map diameter)) and accept slight over-iteration for simplicity.
- DONE: Label lakes from `LakeMask` via `shaders/lake_label_from_mask.glsl` and `scripts/systems/LakeLabelFromMaskCompute.gd`.
  - Reuse the existing label-propagation concept with a small change: treat `LakeMask` as “water” instead of `is_land == 0`.
  - New shader (or parameterize existing) to propagate labels only where `LakeMask == 1`.
- Pour points:
  - DONE: Read back `LakeMask` + labels and compute pour candidates on CPU (`FlowErosionSystem.compute_pour_from_labels`).
  - Later optimization: a GPU pass that marks border edges and reduces by minimum `c = max(H_in, H_out)` per lake.

### Probability for multiple outflows (delta formation)

- Parameters (current CPU implementation):
  - Deterministic per-lake selection using RNG seeded by `rng_seed ^ lake_id`.
  - Configurable: `max_forced_outflows` (default 3), `prob_outflow_0..3` (defaults 0.50, 0.35, 0.10, 0.05). Picks `n` by sampling the cumulative distribution, then takes the `n` lowest-cost pour candidates.
  - DONE: Ocean/chain-depth biased probabilities: `alpha_outflow_ocean_bias`, `beta_outflow_chain_bias`, `chain_depth_max` (chain depth approximated from distance-to-ocean at the primary pour point).
- Inputs:
  - `dist_to_ocean[i]`: precomputed distance transform to ocean (already available as `last_water_distance`)
  - `chain_depth`: number of prior lake→outflow steps to reach the current lake (compute via DFS/BFS from upstream to ocean once pour points are known; cache depth per lake)
- Per candidate beyond the primary (iterate from next-lowest `c`):
  - `p_ocean = clamp01((shore_band - dist_to_ocean[pour_idx]) / shore_band)`
  - `p_depth = clamp01(chain_depth / Dmax)`
  - `p = clamp01(alpha * p_ocean + beta * p_depth)`
  - Open the candidate if `rng.randf() < p`, until `max_outflows_total` or candidates exhaust.
- Determinism: seed RNG from global seed + `lake_id` to keep runs reproducible.

### Storage & API details

- `lake_level`:
  - Option A: per-cell float array `E` (drainage fill). Accurate and useful for debugging.
  - Option B: per-lake spill elevation (compact), with per-cell lookup via `lake_id`. Start with Option A for simplicity, we already hold float fields.
- `forced_seeds`:
  - A flat `PackedInt32Array` of global indices. On GPU, pre-stage ones into seed buffer, then run NMS to OR additional seeds; trace unchanged.
- API changes:
  - `FlowErosionSystem.compute_full(..., settings)` returns extended outputs described above.
  - `RiverCompute.trace_rivers(w, h, is_land, lake_mask, flow_dir, flow_accum, percentile, min_len, forced_seeds := PackedInt32Array())` — new optional argument.
  - Optionally add `RiverCompute.trace_rivers_forced_only(...)` to skip percentile+NMS when desired.

### Integration points

- File: `scripts/WorldGenerator.gd`
  - DONE: Added `realistic_pooling_enabled` feature flag in `Config` and `apply_config`.
  - DONE: Added `use_gpu_pooling` flag to toggle Phase 2 GPU fill/label path.
  - DONE: When enabled, main generation uses strict CPU pooling to get `LakeMask`, `LakeId`, `LakeLevel`, `ForcedSeeds`, and passes `forced_seeds` to the GPU tracer.
  - DONE: Sea-level quick update path also uses strict pooling and passes `forced_seeds` when enabled.

### Shader sketches

```glsl
// File: shaders/depression_fill.glsl (sketch)
// Minimally viable minimax relaxation for DrainElev E
// Inputs: Height (binding=0), IsLand (1); Output: DrainElev (2)
// Push constants: width, height, wrap_x
// Iterate K passes or until an atomic-changed flag stays 0

// E[i] initialized to Height[i] for boundary cells, large for others
// For each i, for each neighbor n:
//   E[n] = min(E[n], max(Height[n], E[i]))
```

```glsl
// File: shaders/lake_label_from_mask.glsl (sketch)
// Same as lake_label_propagate but treat LakeMask==1 as “water”.
```

### Parameters (add to config/UI)

- `realistic_pooling_enabled` (bool)
- `max_forced_outflows` (int, default 3)
- `prob_outflow_0..3` (floats; defaults 0.50, 0.35, 0.10, 0.05)
- `alpha_outflow_ocean_bias` (float, default 0.7) [future]
- `beta_outflow_chain_bias` (float, default 0.3) [future]
- `chain_depth_max` (int, default 5) [future]
- `min_river_length` (int, existing)
- `rng_seed` (existing)

### Implementation checklist

1) CPU depression fill & pour points
- [x] Strict spill-level pooling; mark `LakeMask = (H < SpillElevation) ∧ L`.
- [x] Label lakes and compute `lake_level`.
- [x] Enumerate pour candidates `(i, o, c)` per lake and sort by `c`.
- [x] Select 0–3 forced outflows per lake and return `outflow_seeds`.
- [x] Return extended outputs (`LakeMask`, `LakeId`, `lake_level`, `ForcedSeeds`, `PourPoints`).
- [ ] Honor `wrap_x` in pooling neighbor checks.

2) GPU river tracer accepts forced seeds
- [x] Extend `RiverCompute.trace_rivers(...)` to accept `forced_seeds` and pre-stage them.
- [x] Keep `river_seed_nms.glsl` to OR in additional seeds.
- [x] Keep `river_trace.glsl` unchanged.

3) World integration
- [x] Use strict pooling outputs and pass `forced_seeds` to GPU tracer in main path.
- [x] Apply strict pooling in quick sea-level update as well.
- [ ] Maintain GPU/CPU parity testing toggle for lakes/rivers.

4) Phase 2 (optional) — GPU depression fill
- [x] Implement `depression_fill.glsl` to compute `E`.
- [x] Implement `lake_label_from_mask.glsl` to label `LakeMask`.
- [x] For pour points, read back and compute on CPU via `compute_pour_from_labels`.

5) Debug & QA
- [ ] Add overlays/toggles for `E-H`, `LakeId`, pour points, forced seeds.
- [ ] Snapshot comparisons: CPU vs GPU bitmaps for lakes/rivers; assert parity.
- [ ] Performance checks for target resolutions.

### Rollback plan

- Keep the current connectivity-based `LakeLabelCompute` path behind a feature flag. If issues arise, revert to previous pipeline quickly.

### Notes on existing files to touch

- `scripts/systems/FlowErosionSystem.gd`: strict-fill lakes, pour points, forced seeds, extended outputs.
- `scripts/systems/RiverCompute.gd`: accept and stage `forced_seeds` in the seeds SSBO; optionally OR with NMS.
- `scripts/systems/FlowCompute.gd`: unchanged (only provides `FlowDir` and `FlowAccum`).
- `scripts/systems/LakeLabelCompute.gd`: keep for legacy; later repurpose to work from `LakeMask` instead of `is_land`.
- `shaders/river_seed_nms.glsl`: unchanged.
- `shaders/river_trace.glsl`: unchanged (already terminates at lakes/ocean).
- `shaders/depression_fill.glsl` (new): compute `E` (Phase 2).
- `shaders/lake_label_from_mask.glsl` (new or parameterized existing): label `LakeMask` components (Phase 2).

### Acceptance criteria

- Identical CPU/GPU river masks and lake masks for the same seed and inputs.
- Every inland lake has ≥0 outflow; outflow at the lowest spill saddle by construction.
- Multi-outlet deltas appear increasingly near the ocean and in later chain stages.
- Rivers never cross lake surfaces and always end at an ocean or lake.
- Wrap‑X parity maintained.


