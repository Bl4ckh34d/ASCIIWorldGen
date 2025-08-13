# File: docs/REALISTIC_POOLING_REFACTOR.md

## Realistic Depression Pooling & Outflow Refactor (CPU + GPU Parity)

### Why

- Current lake detection labels any inland water not connected to the map edge as a lake (connectivity only). It does not compute depression fill to spill levels, so lakes look like uniform buffers around rivers rather than basin-conforming pools.
- We want physically plausible pooling: water fills a closed depression to its pour (spill) elevation, then overflows at one or more outflow points. Rivers continue from those outflows, allowing chained lake→river→lake successions and multi-outlet deltas near the ocean.
- CPU and GPU must produce the same result deterministically (given RNG seed) and share identical logic.

### Goals

- Fill each closed basin to its spill elevation (no partial fill) to generate a lake mask that conforms to topography.
- Spawn downstream rivers at the basin’s pour point(s). Always include the primary (lowest) pour point; allow up to 6 total outflows with probability that increases closer to the ocean and deeper in the downstream chain.
- Maintain CPU/GPU parity: same lake mask, same pour points, same river network, given identical inputs and RNG seed.
- Keep wrap‑X behavior consistent.

### Glossary

- `H` (float32): terrain height field (noise-based in our pipeline)
- `L` (u8): land mask (1=land, 0=water/ocean, derived via sea level)
- `E` (float32): filled drainage level per cell (minimax or “priority-flood” level)
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
- `LakeMask = (L == 1) ∧ (E > H)`.
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
  - Step 1: Keep D8 `FlowDir` and `FlowAccum` as-is.
  - Step 2b (Basin assignment): Keep current logic to assign sinks/basins or switch to `E`-based connected components (either works, but `E`-based is cleaner once we have `E`).
  - Step 2c (Refactor to strict fill):
    - Remove the current random partial fill fraction; set fill level to `SpillElevation`.
    - Compute `LakeMask` by `H < SpillElevation` for each lake’s member set.
    - While enumerating basin boundaries to find `SpillElevation`, also collect the sorted list of candidate pour edges `(i, o, c)` per basin.
    - Record for each lake/basin: `LakeId`, `SpillElevation`, `PourCandidates` (sorted by `c`).
  - Seeding:
    - Build `ForcedSeeds` by selecting up to 6 candidates per lake (see Probability section below).
    - OR `ForcedSeeds` with percentile+NMS seeds.
  - Tracing:
    - Keep “stop at ocean or lakes” condition.
    - Keep pruning of small components.
  - Outputs (extend):
    - `flow_dir: PackedInt32Array`
    - `flow_accum: PackedFloat32Array`
    - `river: PackedByteArray`
    - `lake: PackedByteArray` (LakeMask)
    - `lake_id: PackedInt32Array`
    - `lake_level: PackedFloat32Array` (per cell E or per-lake spill, see Storage section)
    - `outflow_seeds: PackedInt32Array` (flat list of indices used for forced seeds)
    - `pour_points: Dictionary<int, Array>` mapping lake_id → ordered list of `(i, o, c)`

### GPU implementation plan (two phases)

Phase 1 — Parity-first (fastest to ship)

- Compute depression fill, lake labeling, and `ForcedSeeds` on CPU.
- Upload `LakeMask`, `FlowDir`, `FlowAccum`, and `ForcedSeeds` to GPU.
- Modify `scripts/systems/RiverCompute.gd` to accept `forced_seeds: PackedInt32Array`:
  - Initialize the `seeds` SSBO to zeros.
  - Write 1s at indices in `forced_seeds`.
  - Optionally run `river_seed_nms.glsl` to OR in percentile+NMS seeds.
  - Run `river_trace.glsl` as-is (it already stops at ocean or lakes).
- Result: Identical river network on CPU and GPU, with minimal new shaders.

Phase 2 — All-GPU fill (optional optimization)

- Add `shaders/depression_fill.glsl` implementing minimax relaxation for `E`:
  - Inputs: `Height` (R32F), `IsLand` (R32U), `wrap_x` push-constant.
  - Outputs: `DrainElev` (R32F). Compute `LakeMask = (DrainElev > Height) ∧ (IsLand == 1)`.
  - Convergence: iterate a fixed number or until no-change flag remains unset (atomic counter). For first version, bound iterations (e.g., O(map diameter)) and accept slight over-iteration for simplicity.
- Label lakes from `LakeMask`:
  - Reuse the existing label-propagation concept with a small change: treat `LakeMask` as “water” instead of `is_land == 0`.
  - New shader (or parameterize existing) to propagate labels only where `LakeMask == 1`.
- Pour points:
  - Initial version: read back `LakeMask` (and optionally labels) and compute pour candidates on CPU.
  - Later optimization: a GPU pass that marks border edges and reduces by minimum `c = max(H_in, H_out)` per lake.

### Probability for multiple outflows (delta formation)

- Parameters:
  - `max_outflows_total = 6` (1 primary + up to 5 extra)
  - `min_outflows = 1`
  - `alpha = 0.7`, `beta = 0.3`
  - `Dmax = 5` (depth scale for increasing probability)
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
  - A flat `PackedInt32Array` of global indices. On GPU, write 1s into the `seeds` SSBO at those indices before running `river_trace.glsl`.
- API changes:
  - `FlowErosionSystem.compute_full(..., settings)` returns extended outputs described above.
  - `RiverCompute.trace_rivers(w, h, is_land, lake_mask, flow_dir, flow_accum, percentile, min_len, forced_seeds := PackedInt32Array())` — new optional argument.
  - Optionally add `RiverCompute.trace_rivers_forced_only(...)` to skip percentile+NMS when desired.

### Integration points

- File: `scripts/WorldGenerator.gd`
  - After terrain and `is_land` are updated:
    - Run “Realistic Pooling” (CPU for Phase 1) to get `LakeMask`, `LakeId`, `LakeLevel`, `ForcedSeeds`.
    - Assign `last_lake`, `last_lake_id`, `last_lake_level`.
    - Compute/reuse `last_water_distance` for the probability function.
    - For rivers: compute `flow_dir/flow_accum` (GPU or CPU), then call the river tracer with `forced_seeds`.
    - Keep delta widening and freeze gating unchanged.

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

### Testing plan

- Unit tests (CPU): small synthetic grids
  - Single bowl with one rim: lake fills to rim, one outflow.
  - Two adjacent bowls with different spill heights: different lake levels, correct outflows.
  - Nested depression with saddle: lake level equals saddle; outflow at saddle.
  - Open basin draining to ocean: no inland lake; river to ocean.
  - Wrap‑X enabled: depressions spanning left/right edges behave correctly.
- Parity tests (CPU vs GPU):
  - Same `LakeMask`, `LakeId`, `ForcedSeeds`, and final `river` bitmaps (given same RNG seed).
- Fuzz tests:
  - Random heightmaps with fixed seeds; assert invariants (no river crosses a lake; each inland lake has ≥1 outflow; distance-to-ocean probability increases outlets near coast).
- Visual debug overlays:
  - `E - H` heatmap, lake IDs, pour points, forced seeds, chain depth, chosen multi-outflows.

### Edge cases & rules

- Sea level clamp: do not fill below sea level (ocean is already water).
- Steady-state: a lake with multiple outflows should still have `LakeMask` computed at its single spill elevation (lowest `c`). Additional outflows are artificial channels for visuals, not changes to the fill level.
- Sinks with zero area (plateaus): treat tie-breaking carefully in D8; if no downhill neighbor, the cell becomes part of a basin and is handled by fill.
- Performance: O(N) priority-flood CPU; GPU relaxation needs bounded iterations; ensure early-stop flag to avoid unnecessary passes.
- Consistency: always respect `wrap_x` when checking neighbors.

### Parameters (add to config/UI)

- `realistic_pooling_enabled` (bool)
- `max_outflows_total` (int, default 6)
- `min_outflows` (int, default 1)
- `alpha_outflow_ocean_bias` (float, default 0.7)
- `beta_outflow_chain_bias` (float, default 0.3)
- `chain_depth_max` (int, default 5)
- `min_river_length` (int, existing)
- `rng_seed` (existing)

### Implementation checklist

1) CPU depression fill & pour points
- [ ] Implement `E` via priority-flood or reuse existing basin walk with spill computation; set `LakeMask = (E > H) ∧ L`.
- [ ] Label `LakeMask` → `LakeId` (CPU for now).
- [ ] Enumerate pour candidates `(i, o, c)` per lake and sort ascending by `c`.
- [ ] Select `ForcedSeeds` (probabilistic multi-outflows) using `last_water_distance` and chain depth.
- [ ] Return extended outputs (`LakeMask`, `LakeId`, `E`, `ForcedSeeds`, `PourPoints`).

2) GPU river tracer accepts forced seeds
- [ ] Extend `RiverCompute.trace_rivers(...)` to accept `forced_seeds` and set seed SSBO accordingly.
- [ ] Keep `river_seed_nms.glsl` to optionally add tributary seeds (OR into the seed buffer).
- [ ] Keep `river_trace.glsl` unchanged (already stops at ocean/lake).

3) World integration
- [ ] In `WorldGenerator.gd`, gate by `realistic_pooling_enabled`.
- [ ] Call the CPU fill to produce lakes and `ForcedSeeds` before rivers.
- [ ] Pass `ForcedSeeds` to CPU tracing or GPU tracer.
- [ ] Maintain GPU/CPU parity testing toggle.

4) Phase 2 (optional) — GPU depression fill
- [ ] Implement `depression_fill.glsl` to compute `E`.
- [ ] Implement `lake_label_from_mask.glsl` or parameterize existing propagate to use `LakeMask`.
- [ ] For pour points, start with CPU after readback; later, add a GPU min-reduction per `LakeId`.

5) Debug & QA
- [ ] Add overlays and toggles in `SettingsDialog` for `E-H`, `LakeId`, pour points, seeds.
- [ ] Snapshot comparisons: CPU vs GPU bitmaps; assert parity.
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
- Every inland lake has ≥1 outflow; outflow at the lowest spill saddle by construction.
- Multi-outlet deltas appear increasingly near the ocean and in later chain stages.
- Rivers never cross lake surfaces and always end at an ocean or lake.
- Wrap‑X parity maintained.


