# Perf Docs

This folder holds reproducible performance baselines and profiling notes tied to `docs/REFACTOR_PLAN.md`.

What goes here:
- `baseline-YYYYMMDD.md`: a captured baseline run (settings + timings + notes).
- `profile-YYYYMMDD-<topic>.md`: deeper dives (GPU stalls, allocations, readbacks, etc.).

Baseline template:
- Copy `baseline-TEMPLATE.md` to `baseline-YYYYMMDD.md` and fill it out using a single reproducible run:
  - new world (default seed or noted seed)
  - 275x62 resolution
  - one full cycle (terrain, climate, biomes, rivers)
  - note time scale, any toggles, and whether RD is available

