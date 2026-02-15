# Civilization Plan (Humans, Wildlife, Epochs)

Goal: a deterministic civilization simulation that starts with wildlife and an eventual human emergence, then evolves through settlements, politics, economy, wars, and technology across long timespans in **worldgen mode** (batched weeks/months), while remaining lightweight and stable during normal gameplay.

This doc is for scaffolding and sequencing. It will be fleshed out system-by-system.

## Non-Negotiables
- Deterministic from `world_seed_hash` + coordinates + absolute world time.
- GPU-first: global civ/wildlife updates should run on compute shaders.
- Avoid GPU->CPU readbacks in hot paths; snapshot only at explicit transitions (save/load, scene transitions) and cache.

## Core Loops

### Wildlife (v0)
- Represent wildlife as a **single density scalar per world tile** `wildlife_density[x,y]` in `[0..1]`.
- Wildlife is influenced by biome/climate (v0: biome-only proxy; later: climate fields).
- Humans consume wildlife locally; depleted wildlife forces migration.

### Humans (v0)
- Humans appear only after suitable conditions and sufficient time progression.
- Humans have:
  - finite lifetimes (later: age cohorts)
  - reproduction requiring a male+female pair (later: explicit sex/age structure)
  - premature death chance (later: disease, war, accidents)
  - survival needs (food/water/safety) backed by wildlife + economy systems

v0 simplification:
- Per-tile human population scalar `human_pop[x,y]` and coarse growth/migration.
 - Early survival bonus window after emergence to avoid humanity dying out before it spreads.

### Settlements -> Villages -> Cities (v1+)
- Settlements emerge from population concentration.
- Settlements have a location, population, and production/consumption capacity (feeds into economy system).
- Growth transitions:
  - camp -> village -> town -> city (thresholds + stability)

### Politics (v1+)
- Politics becomes active when there are multiple meaningful population centers/states.
- Province/state layer already exists as coarse political units; civilization will feed it:
  - ownership pressure, unrest, rebellion, war probability

### Technology / Epoch Progression (v2+)
Status: scaffold implemented (v0 symbolic):
- Global tech proxy (`CivilizationStateModel.tech_level`) + devastation proxy (`global_devastation`) feed a deterministic epoch classifier.
- Epochs are emergent outcomes (not a single switch):
  - prehistoric -> ancient -> medieval -> industrial -> modern -> space/AI -> "singularity"
- Regression is possible (collapse, war, climate shocks):
  - high devastation can push the epoch variant into `stressed` / `post_collapse`.
- Epoch auto-shift cadence (implemented v0):
  - Shifts are delayed/scheduled rather than instant.
  - Typical timing is years/decades; rare fast shifts can happen in months.
- Runtime hooks now exist for downstream systems:
  - `scripts/gameplay/sim/EpochSystem.gd`
  - epoch metadata persisted in `CivilizationStateModel`
  - epoch propagated to politics state metadata + important NPC metadata
  - politics governments transition through delayed scheduled shifts instead of instant swaps (`government_desired` -> `government_target` -> applied on due day)
  - trade-route scaffolding consumes epoch/government multipliers for capacity
  - worldgen hover/dev HUD now show tech + epoch context

## Scopes
- Global (always): wildlife + civilization aggregate fields; state/province politics; settlement-level economy.
- Regional (player political unit): higher-detail NPC simulation (see `docs/NPC_POLITICS_ECONOMY_PLAN.md`).
- Local: NPC movement and interactions only.

## GPU Scaffolding (Implemented v0)
- Compute shaders:
  - `shaders/society/wildlife_tick.glsl`
  - `shaders/society/civilization_tick.glsl`
  - `shaders/society/society_overlay_pack.glsl` (packs human/wildlife into a texture for GPU rendering overlay)
- RD wiring:
  - `scripts/gameplay/sim/SocietyGpuBridge.gd` uploads and ticks wildlife + civ alongside economy/politics/NPCs.
  - `scripts/systems/SocietyOverlayTextureCompute.gd` produces a `Texture2DRD` overlay for worldgen visualization.
- Persistence:
  - Snapshot to CPU only on save/load and store in:
    - `scripts/gameplay/models/WildlifeState.gd`
    - `scripts/gameplay/models/CivilizationState.gd`

## Milestones

### M0: Scaffolding (done)
- Data models persisted with save/load.
- GPU buffers + compute ticks wired into the background sim.
- Worldgen batching support: background ticks accept `dt_days` without per-day loops.
 - Worldgen cadence scaffold: civilization/economy/politics extraction is batched in coarse windows (default 7 days; 30/60 days at higher sim speeds).
 - Worldgen visualization overlay (GPU-only): subtle tint + outline around human presence; does not erase biome geography.

Locked decisions (2026-02-10):
- Planet "type" is fully inferred from climate/biome fields; no first-class planet-type knobs in v0.
Locked decisions (2026-02-12):
- Human emergence delay is deterministic random in `[1..5]` years after sim start.
- Human emergence start tile is always selected via suitability search on inferred biome/climate proxies (never hardcoded to a fixed tile).

### M1: Better Emergence + Migration
Status: scaffold implemented (v0):
- Emergence scheduling v0 (implemented): deterministic random delay in `[1..5]` years.
- Emergence suitability v0 (implemented): deterministic best-tile search from biome/latitude proxies.
- Later upgrades:
  - include wildlife + distance-to-coast + full climate fields in the suitability score.
- Migration model:
  - v0: GPU ping-pong smoothing + wildlife-pressure-driven mobility (symbolic).
  - v1+: constrained migration along gradients (wildlife, safety, temperature), with proper conservation/flows (may require atomics or multi-pass).

### M1.1: Worldgen Debug Outputs
Status: scaffold implemented (v0):
- Worldgen hover info should include:
  - wildlife density
  - human population density
  - symbolic settlement label (Band/Camp/Village/City) from thresholds
- Map overlay should show humans without blocking the biome:
  - subtle tint where humans are present
  - outline around human-held area (later: borders for states/empires)

### M2: Settlement Extraction
Status: scaffold implemented (v0):
- Detect population clusters and instantiate settlements deterministically.
- Link settlements to economy v0 nodes/edges.
 - v0 implementation: coarse-cadence extractor (worldgen mode) reads population snapshot from GPU, finds local maxima above thresholds, and upserts `SettlementStateModel` + seeds `EconomyStateModel.settlements` (default cadence: every 60 sim-days).

### M2.1: Politics From Settlements (v0 scaffold)
Status: scaffold implemented (v0):
- Once cities exist, derive coarse states (city-states) with cities as capitals.
- Carve local city-state enclaves from host states (province-grid level) instead of replacing the full map ownership.
- Visualize borders as outlines on the worldgen map without obscuring geography.

### M3: Warfare / Devastation Hooks
- War impacts population + settlement destruction.
- Long-term biome changes hooks (nuclear wasteland, radioactivity) to be added to worldgen systems later.
Status: scaffold implemented (v0 symbolic):
- `SocietyGpuBridge` now computes a coarse `war_pressure` from active wars/states and feeds it into civ meta.
- `civilization_tick.glsl` consumes `war_pressure` + `global_devastation` hooks to modulate growth/starvation.
- `CivilizationStateModel.global_devastation` is persisted for save/load and exposed in worldgen hover debug.

## Notes / TODO
- Worldgen path decision (2026-02-13): keep a unified simulation lane for now; worldgen uses coarse/batched scheduling over the same core systems instead of a separate duplicate sim state.
- Future: make moons/space travel accessible; for now, only placeholders exist.
