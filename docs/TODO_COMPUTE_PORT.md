# File: docs/TODO_COMPUTE_PORT.md - Compute Shader Port Plan

Status: tracking the staged port of heavy systems to Godot 4 compute.

Recent progress (today):
- All compute shaders converted to proper RDShaderFile format (`#[compute]` + `#version 450`), with SSBO layout order `layout(std430, set = X, binding = Y)`.
- Fixed GLSL import/compile errors in `climate_adjust.glsl`, `terrain_gen.glsl` by removing unsized SSBO array parameters and using buffer-specific sampling helpers.
- Implemented GPU FBM + domain warp kernel (`noise_fbm.glsl`) and climate noise kernel (`climate_noise.glsl`).
- Added lake labeling kernels (`lake_label_propagate.glsl`, `lake_mark_boundary.glsl`) and wrapper, integrated into generator.
- Flow accumulation loop now runs fully on GPU with buffer ping‑pong and GPU clears (no per‑pass readbacks).
  - River trace frontier now also ping‑pongs on GPU and clears via `clear_u32.glsl` (no per‑pass CPU upload).

## Priorities

- [x] ClimateAdjust (temperature/moisture/precip)
- [x] ContinentalShelf distance transform + turquoise/beach strength
- [x] Flow direction + accumulation (seed and accumulation passes)
- [ ] Optional: render-time image path (GPU buffer → ImageTexture)
- [ ] CPU fallback retained for all steps

## Nice-to-have later

- [x] River tracing and pruning (GPU reformulation)
- [ ] PoolingSystem lake labeling (GPU CC labeling)
- [ ] FeatureNoiseCache on GPU (prebaked value noise fields)

## Integration notes

- Single upload of static inputs per generation: `height`, `is_land`
- Chain compute dispatches; read back only needed fields for UI
- Workgroup sizes 8x8 or 16x16; mask out oceans and permanent ice early in kernels
- Keep current caches: `FeatureNoiseCache` stays the source of shelf/desert/ice wiggle
- Global toggle: a single Settings → General → "GPU Compute (All)" gates every compute step (DT, Shelf, Climate, Flow, Rivers)

## Milestone 1: ClimateAdjust on compute

- [x] Define storage buffers: inputs (height, is_land[u32], distance_to_coast, temp_noise, moist_noise_base, flow_u, flow_v), outputs (temperature, moisture, precip)
- [x] Implement compute shader (WG size 16x16)
- [x] Wire into `WorldGenerator.gd` with CPU fallback toggle
- [ ] Verify parity vs CPU within tolerance (per-field RMSE and max abs diff; target RMSE < 0.02)

## Milestone 2: ContinentalShelf on compute

- [x] Compute ocean distance (2-pass DT) on GPU
- [x] Compute turquoise, beach, turquoise_strength
- [x] Wire into generator; parity check and profile

## Milestone 3: Flow on compute

- [x] D8 steepest descent kernel
- [x] Accumulation kernel via iterative frontier propagation (push kernel)
- [x] Seed on GPU (NMS threshold) + GPU trace; CPU prune retained

## Milestone 4: Terrain generation on compute

- [x] Compose terrain on GPU from CPU-prebuilt fields (temporary bridge)
- [x] Full FBM + domain warp + continental mask computed on GPU when `noise_fbm.glsl` is available
- [x] Tileable wrap‑X sampling and Noise X Scale application (in shader)
- [x] Outputs: `height`, `is_land` (and optional continental mask for debugging)
- [ ] Wire into generator; parity check and profile (GPU vs CPU)

Status: Terrain compute now generates FBM fields on GPU (with fallback to CPU when shader isn’t available), then composes on GPU.

## Milestone 5: Pooling/Lake labeling on compute

- [x] Connected components labeling for lakes (propagation + boundary mark)
- [x] Compute `lake`, `lake_id`; integrated in generator (CPU compaction retained)

## Milestone 6: Biomes on compute

- [x] Biome classification kernel (temperature, moisture, height rules)
- [x] Optional 3x3 mode filter (histogram per‑tile) for smoothing
- [x] Re‑apply ocean ice/glacier masks after smoothing (GPU post)

## Milestone 7: River post on compute

- [x] River delta widening (morphological kernel near outlets)
- [ ] Optional: erosion touch‑ups in compute (very light)

## Milestone 8: Atmosphere/overlays on compute

- [x] Cloud band and advection overlay (intensity field)
- [ ] Optional wind glyphs/u‑v sampling fields

## Milestone 9: GPU noise fields

- [x] Implement GLSL FBM (Perlin) with wrap‑X and 3–5 octaves (terrain)
- [x] Replace CPU `_build_noise_fields` in `TerrainCompute.gd` with GPU kernel when available
- [x] Extend to climate noise fields (temp/moist/flow_u/flow_v) to remove CPU prebuild when `climate_noise.glsl` is available
- [x] Expand to `FeatureNoiseCache` (desert split, ice wiggle, shore value noise) via `feature_noise.glsl` with CPU fallback

Note: Bringing this forward will remove large CPU costs and uploads each generation.

## Performance notes (immediate wins)

- Eliminate CPU↔GPU round‑trips inside iterative kernels:
  - Flow push loop: DONE — `frontier_in/out` ping‑pong on GPU and zeroing via `clear_u32.glsl`.
  - River trace loop: DONE — frontier ping‑pong on GPU and zeroing via `clear_u32.glsl`.
- Chain compute lists and minimize `_rd.sync()` calls; submit once per phase where possible.
- Keep singletons for compute wrappers (reuse pipelines and uniform sets across runs). [x] Wrapped in `WorldGenerator.gd` for Terrain/DT/Shelf/Climate/Flow/River
- Defer readbacks until final outputs needed by UI; avoid intermediate downloads.

## Performance goals

- ClimateAdjust: 10–20x speedup at 640x120 target
- Shelf: 5–10x speedup
- Flow: 5–15x speedup for accumulation

## Current blockers

- RDShaderFile SPIR-V retrieval: addressed by ensuring `.glsl` imports as `RDShaderFile` and calling `get_spirv("compute")` (with fallback to `"main"`) on the import. Kept robust CPU fallback in generator.

## Integration decisions

- Use main device `RenderingServer.get_rendering_device()` for all compute wrappers (avoids version mismatch with imported SPIR-V). [x] Implemented across Terrain/DT/Shelf/Climate/Flow/River wrappers.
- Treat masks/flags as u32 in shaders; convert in/out to `PackedByteArray` at API boundaries. [x]
- Keep distance-to-coast fed from GPU DT when available; then run shelf strength + beach on GPU to use finalized field. [x]

## Parity checklist (to run before closing milestone)

- ClimateAdjust GPU vs CPU: compute RMSE for temperature, moisture, precip at 320x60 and 640x120; RMSE < 0.02.
- DistanceTransform GPU vs CPU: max abs diff < 1e-3 after two passes.
- Shelf outputs: beach and turquoise pixel-for-pixel agreement in near-shore band; strength MAE < 0.03.
- Flow: flow_dir equality rate > 99%; flow_accum relative error MAE < 0.02 on land.

## Next steps

1) Milestone 4: Terrain on compute — parity and profiling
- Wire into `WorldGenerator.gd` behind `use_gpu_all` toggle; parity vs CPU at 320x60 and 640x120. [in progress]
- Add simple RMSE/max-diff check for height and is_land.

Note: Added an in-engine parity harness (toggle via `WorldGenerator.debug_parity = true`). It logs:
- Terrain: RMSE and max absolute difference for `height`, equality for `is_land`.
- Distance Transform: max absolute difference vs CPU DT.
- Shelf: equality rates for `turquoise_water`/`beach` within near-coast band; MAE for `turquoise_strength`.
- Climate: RMSE for `temperature`, `moisture`, `precip`.
- Flow: equality rate for `flow_dir` on land; relative MAE for `flow_accum` on land.

2) Milestone 5: Pooling/Lake labeling on compute
- Verify GPU `LakeLabelCompute.gd` parity vs CPU PoolingSystem; compact IDs on CPU as needed.

3) Validation harness
- Add a debug command to dump CPU/GPU arrays and compute metrics; render diff heatmaps.

4) Milestone 6 continuation: GPU biome post
- Implemented GPU pass to re-assert special masks after smoothing:
  - Ocean ice sheets (very cold ocean cells) using per-seed wiggle
  - Land glaciers (high-elevation cold and moist)
- Remains gated by `use_gpu_all`; CPU fallbacks remain for safety.
