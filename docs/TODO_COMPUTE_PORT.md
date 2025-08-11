# File: docs/TODO_COMPUTE_PORT.md - Compute Shader Port Plan

Status: tracking the staged port of heavy systems to Godot 4 compute.

## Priorities

- [ ] ClimateAdjust (temperature/moisture/precip)
- [ ] ContinentalShelf distance transform + turquoise/beach strength
- [ ] Flow direction + accumulation (seed and accumulation passes)
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

## Milestone 1: ClimateAdjust on compute

- [x] Define storage buffers: inputs (height, is_land, distance_to_coast, params), outputs (temperature, moisture, precip)
- [x] Implement compute shader (WG size 16x16)
- [x] Wire into `WorldGenerator.gd` with CPU fallback toggle
- [ ] Verify parity vs CPU within tolerance

## Milestone 2: ContinentalShelf on compute

- [x] Compute ocean distance (2-pass DT) on GPU
- [x] Compute turquoise, beach, turquoise_strength
- [x] Wire into generator; parity check and profile

## Milestone 3: Flow on compute

- [x] D8 steepest descent kernel
- [x] Accumulation kernel in height order (or iterative relaxation)
- [ ] Seed + prune kept on CPU initially

## Performance goals

- ClimateAdjust: 10–20x speedup at 640x120 target
- Shelf: 5–10x speedup
- Flow: 5–15x speedup for accumulation

## Current blockers

- RDShaderFile SPIR-V retrieval can fail depending on import; ensure `.glsl` is imported as `RDShaderFile` and that `get_spirv()` uses correct variant. Add robust CPU fallback.
