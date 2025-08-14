<!-- File: docs/SEASONS_DIURNAL_REFACTOR_TODO.md -->

## Seasons & Diurnal Cycles — Refactor Plan (Visuals + Temperature)

### Synopsis
Bring Earth-like seasons and a visible day–night cycle into both the simulation and rendering. Seasonal temperature must flip phase between hemispheres; the day–night terminator should sweep across the cylindrical map, modulating tile brightness. Keep GPU-first execution and avoid full climate recomputes every tick by separating baseline climate from lightweight cyclical terms.

### Objectives (Success Criteria)
- Hemispheric seasons: at any time, one hemisphere experiences summer while the other has winter (phase inversion around the equator).
- Diurnal temperature swing: small daily oscillation, latitude- and ocean-damped.
- Day–night brightness: visible terminator moving west→east with time-of-day; adjustable visual contrast.
- GPU-first computation; no full climate recompute each tick for cycles-only updates.
- Deterministic behavior under fixed seed and cadence.

### Core math (reference)
- Latitude φ (radians) per row y: φ = π·(y/(H−1) − 0.5). Equivalently, lat_norm = (y/(H−1) − 0.5) in [−0.5..+0.5].
- Solar declination δ (Earth tilt 23.44°): δ = −23.44° · cos(2π·day_of_year).
- Hour angle at x: H = 2π · (time_of_day + x/W). Wrap horizontally.
- Sun elevation proxy s = sinφ·sinδ + cosφ·cosδ·cosH.
- Brightness b = clamp(0, 1, 0.25 + 0.75·max(0, s)). Parameterize the 0.25 base and 0.75 scale.
- Seasonal temperature term (normalized units):
  - A_lat = mix(A_eq, A_pole, |lat_norm|^γ), γ≈1.2.
  - A_land = mix(ocean_damp, 1.0, continentality), continentality≈scaled coast distance.
  - Hemisphere inversion: phase_h = (lat_norm < 0 ? season_phase + 0.5 : season_phase).
  - ΔT_season = A_lat · A_land · cos(2π·phase_h).
- Diurnal temperature term:
  - A_d_lat = mix(A_eq_d, A_pole_d, |lat_norm|^γ), damp over ocean.
  - ΔT_diurnal = A_d_lat · A_d_ocean · cos(2π·time_of_day).

### Public configuration (WorldGenerator.Config)
- Add or confirm keys (with suggested defaults):
  - season_amp_equator: 0.10
  - season_amp_pole: 0.25
  - season_ocean_damp: 0.60
  - diurnal_amp_equator: 0.06
  - diurnal_amp_pole: 0.03
  - diurnal_ocean_damp: 0.40
  - day_night_contrast: 0.75 (visual; 0..1)
  - day_night_base: 0.25 (visual; 0..1)

### UI mapping
- General/Climate tab:
  - Season Strength slider maps to season_amp_equator/pole (equator lower than pole). Keep existing control.
  - Ocean Damp (seasonal) slider maps to season_ocean_damp. Already present.
  - New: Diurnal Strength slider → diurnal_amp_equator/pole.
  - New: Day–Night Contrast slider → day_night_contrast; optional Base slider → day_night_base.

### System responsibilities
- Rename SeasonalClimateSystem → CelestialCycleSystem (optional), responsibilities:
  - Each tick: compute `season_phase = fract(t/365)` and `time_of_day = fract(t)`.
  - Push config amps/damp + current phases into generator.
  - Fast path: if only phases changed and baseline climate is up-to-date, run a lightweight GPU pass to apply ΔT_season + ΔT_diurnal without recomputing full climate.
  - Produce/refresh a `light_field` buffer (GPU preferred) for day–night brightness.

### GPU work (new/updated shaders)
1) Update `shaders/climate_adjust.glsl`:
   - Implement hemispheric inversion: shift `season_phase` by +0.5 for southern hemisphere.
   - Keep existing latitude/continentality scaling and diurnal term.
   - Ensure `time_of_day` and `season_phase` are in push constants (already present).

2) New shader `shaders/cycle_apply.glsl` (lightweight temperature update):
   - Inputs: OutTemp (current), IsLand, Dist (coast distance), push constants: season_amp_*, diurnal_amp_*, season_phase, time_of_day.
   - Apply ΔT_season + ΔT_diurnal additively and clamp; no noise or base recomputation.
   - Use when only phases changed since last full climate pass.

3) New shader `shaders/day_night_light.glsl`:
   - Push constants: width, height, day_of_year, time_of_day, base, contrast.
   - Output: `light[i] = clamp(base + contrast * max(0, s(φ,δ,H)), 0, 1)`.
   - Optional: pack to 16-bit or 8-bit normalized for bandwidth.

### CPU/GD scripts — required edits
- `scripts/systems/SeasonalClimateSystem.gd`:
  - Rename (optional) and expand to compute both seasonal and diurnal phases every tick.
  - Track whether base climate inputs changed; if not, run `cycle_apply.glsl` instead of `ClimateAdjust` full pass.
  - Trigger/update GPU `day_night_light.glsl` each tick (cheap) and expose buffer via generator (e.g., `last_light`).

- `scripts/systems/ClimateAdjustCompute.gd`:
  - Add a fast path: `apply_cycles_only()` that dispatches `cycle_apply.glsl` using existing temperature as input/output.
  - Expose `evaluate_light_field()` that dispatches `day_night_light.glsl` and returns a buffer.

- `scripts/style/AsciiStyler.gd`:
  - Extend `build_ascii(...)` signature to accept `light_field: PackedFloat32Array`.
  - Apply brightness before cloud shadow:
    - `color = Color(color.r*b, color.g*b, color.b*b, color.a)`.
  - Keep cloud shadow multiplicative after brightness.

- `scripts/Main.gd`:
  - On redraw, pass `generator.last_light` to `AsciiStyler.build_ascii`.
  - If GPU light not available, compute brightness per-tile on CPU using the formulas above (fallback path only; avoid every tick on large maps when possible).
  - Default cadences: CelestialCycleSystem cadence=1; Biomes cadence can remain decoupled.

- `scripts/WorldGenerator.gd`:
  - Add `last_light: PackedFloat32Array` and integrate with compute calls.
  - Ensure config defaults set non-zero seasonal amplitudes.

### Scheduling & budgets
- Run `day_night_light` every tick (cheap single pass).
- Run `cycle_apply` every tick when only phases change (ultra-cheap); run `ClimateAdjust` full pass on:
  - sea level change, continentality change, noise param changes, or when instructed (e.g., cadence N).
- Keep ASCII redraw cadence ≥ 5 ticks by default to meet UI budget at medium sizes; allow user control.

### Acceptance checklist
- [ ] Seasonal temp visibly flips between hemispheres as year label advances.
- [ ] Day–night terminator moves smoothly with `time_of_day` and wraps at x=0.
- [ ] No full climate recompute each tick when only time changes; temperature updates via light cycles are fast.
- [ ] ASCII brightness multiplies base biome/water colors without exceeding UI budget.

### Migration plan (phased)
1. Defaults & parity
   - [ ] Set non-zero `season_amp_equator/pole` defaults.
   - [ ] Implement hemispheric inversion in `climate_adjust.glsl` (+ CPU parity if used).
   - [ ] Wire UI diurnal strength and day–night contrast.

2. Visuals
   - [ ] Implement `day_night_light.glsl`; store `last_light` and render in ASCII.
   - [ ] Add CPU fallback brightness calculation in `Main.gd` only when GPU light missing.

3. Performance
   - [ ] Add `cycle_apply.glsl` and `apply_cycles_only()` path in `ClimateAdjustCompute.gd`.
   - [ ] Modify `SeasonalClimateSystem.gd` to choose fast vs full path based on dirty flags.

4. QA
   - [ ] Validate amplitudes and latitude/ocean damping across a variety of seeds and sizes.
   - [ ] Stress test high `time_scale`; ensure no stutter; confirm determinism.

### Files to touch (non-exhaustive)
- `scripts/systems/SeasonalClimateSystem.gd` (or new `CelestialCycleSystem.gd`)
- `scripts/systems/ClimateAdjustCompute.gd`
- `shaders/climate_adjust.glsl`
- `shaders/cycle_apply.glsl` (new)
- `shaders/day_night_light.glsl` (new)
- `scripts/WorldGenerator.gd`
- `scripts/style/AsciiStyler.gd`
- `scripts/Main.gd`


