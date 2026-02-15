# NPCs + Politics + Economy Plan

Goal: emergent world lore from interacting simulation systems (economy, politics, NPC needs/behavior) that keep running globally in the background (downscaled), while becoming more detailed in the player’s current regional/local area.

This doc is a forward-looking plan. We will implement it step by step (system by system) and tune for performance.

## Non-Negotiables (Project-Level)
- Deterministic simulation for procedural content from `world_seed_hash` + coordinates + time.
- Avoid per-frame GPU->CPU readbacks in hot paths (snapshots only at explicit transitions; cached).
- GPU-first visuals remain canonical (regional/local maps keep the pixel-light GPU style).

## Core Concepts

Epochs (world flavor + tech):
- Prehistoric: tribes, tiny settlements, basic production, heavy wilderness/monsters.
- Medieval/fantasy: feudal states, trade, magic systems, guilds, wars, diplomacy.
- Futuristic: high-tech production, robots/cyborgs, post-war ruins, planetary constraints (desert/ice/etc).

The simulation should support drifting between epochs if world time is advanced far enough (worldgen mode).

## Economy (Abundance/Scarcity)

### Commodity Model (minimal)
Commodities are abstracted into a small set that still captures bottlenecks:
- Water
- Food
- Fuel/energy (or “warmth” for cold worlds)
- Medicine
- Materials (wood/stone/metal as coarse buckets)
- Tools/arms

Each settlement has:
- `production[commodity]` (per day)
- `consumption[commodity]` (per day)
- `stockpile[commodity]` (buffer)
- `scarcity[commodity]` derived from stockpile trend

Prices are local and drift based on scarcity (not a perfectly efficient market).

### Planet/Region Constraints
World type influences baseline productivity/needs:
- Desert: water scarcity dominates; food depends on trade/irrigation.
- Ice: warmth/fuel dominates; food/water can be local but energy-constrained.
- Temperate: higher baseline self-sufficiency; trade is driven by specialization.

### Trade
Trade is modeled as flows along a graph:
- Nodes: settlements (towns, cities, forts, ports).
- Edges: routes (roads, rivers, sea lanes, later: air/space lanes).
- Edge capacity is limited by distance, terrain, security, tech level.
- Diplomatic rule (locked 2026-02-12):
  - Trade is blocked between states that are at war.
  - Trade is allowed with non-war states, with preference for treaty/alliance partners.

Algorithm direction:
- Start simple: greedy matching of surpluses to deficits with distance penalty.
- Add shocks: route disruption from war, bandits, storms, embargoes.

## Politics (States in Flux)

### Entities
- State/kingdom/empire: name, capital, ideology/government type, tech/epoch affinity.
- Province: belongs to a state; has population, economy, unrest, garrisons.
- Border: adjacency between provinces, with conflict pressure.

### State Dynamics
Drivers:
- Economy health (scarcity, wealth, inequality proxies)
- Military capacity (manpower + supply)
- Legitimacy/stability (unrest, succession, faction splits)
- External pressure (neighbors, treaties, alliances)

Outcomes:
- Treaties, alliances, wars, armistices
- Border changes (province transfer, conquest)
- State failure (fragmentation into smaller states)
- Consolidation (empires swallowing neighbors)

Implementation direction:
- Global tick produces discrete events (declare war, sign treaty, province rebels).
- Borders update via a constrained “front” model (not per-tile conquest at first).

## NPCs (Needs + Personality + LLM Dialogue)

### NPC Data Model (minimal)
Each NPC gets:
- Identity: `npc_id`, culture, language(s)
- Role: job, faction, home settlement, social class
- Needs: hunger, thirst, safety, shelter, wealth (coarse)
- Personality parameters: a small vector (e.g., agreeableness, aggression, curiosity, loyalty, greed)
- Disposition toward player: derived from:
  - personal history with player (quests, crimes, gifts)
  - state relations (war/peace with player-aligned state)
  - social standing mismatch (class dynamics)
  - epoch norms (standing matters more in feudal eras, less in egalitarian eras)

### Behavior (simulation, not LLM)
NPCs choose actions from a constrained policy:
- work, travel, trade, rest, socialize, patrol, flee, recruit, betray, etc.
Behavior uses deterministic simulation inputs. The LLM does not drive world state.

### Dialogue (LLM as renderer)
LLM input should include:
- NPC persona + role + current needs
- local political/economic context snapshot
- player profile (race, age, gender, standing, known reputation flags)
- recent conversation memory + relevant world events

LLM output is treated as flavor text:
- The game state changes only through explicit, validated player actions (choices), not free-form text alone.

## Scaling: Global vs Regional vs Local

Global (background, downscaled):
- State-level politics + settlement-level economy ticks.
- NPC population is aggregated; only “important NPCs” are instantiated individually.
 - GPU-first: run global ticks on compute shaders; only snapshot to CPU at explicit transitions (save/load, scene transitions) and cache results.

Regional (player tile; higher detail):
- Expand aggregated economy into more granular scarcity signals.
- Spawn more individual NPC agents; update their schedules and interactions more frequently.
- Visualize gradual biome/climate transitions and their impacts.
 - Scope rule: "local/detailed" NPC simulation applies to the player’s current political unit (province/state/kingdom/empire), not just the current tile.

Local (interiors; highest detail):
- Individual NPC movement/interaction.
- Inventory/trade interaction UI.
- Consequences (theft, violence) recorded as local reputation and fed back into regional/global.

## Determinism / Persistence
- World simulation state is deterministic given:
  - `world_seed_hash`
  - absolute world time (day/second)
  - entity IDs and their coordinates
- Save/load must preserve:
  - political map (states/provinces)
  - economy stockpiles/prices (or enough to reproduce them)
  - player reputation/standing
  - “important NPC” state

LLM:
- Not deterministic; we persist conversation logs and any explicit player choices/outcomes.

## Implementation Milestones (Incremental)

M0: Data scaffolding (no gameplay impact yet)
- Add data models: `State`, `Province`, `Settlement`, `Market`, `Commodity`, `NpcProfile`.
- Add save/load schema entries for these models (versioned).
- Add a deterministic event RNG keyed by world time + entity id.
  - Implemented helper: `scripts/gameplay/sim/WorldEventRng.gd` (v0).

M1: Economy v0 (settlement-only)
Status: scaffold implemented (v0 GPU + symbolic shocks):
- Production/consumption/stockpile per settlement.
- Scarcity-driven prices.
- Simple trade flows on a route graph.
- Debug reports: top scarcities, top price spikes, trade disruptions.
- `economy_tick.glsl` now consumes war/devastation hooks and applies immediate symbolic stockpile shocks during batched ticks.
- Epoch multipliers (implemented v0 symbolic):
  - economy tick now applies epoch/variant multipliers for production, consumption, scarcity volatility, and price adaptation speed.

Bootstrap (implemented v0):
- As the player discovers new world tiles, we can seed occasional settlements/provinces/important NPCs deterministically.
  - Helper: `scripts/gameplay/sim/SocietySeeder.gd` (low density v0).

M2: Politics v0 (state/province)
Status: scaffold implemented (v0 symbolic):
- Province ownership map + adjacency.
- Unrest and rebellion events.
- Basic treaties/war state and border change rules.
- City-state behavior (locked 2026-02-12):
  - City-states can exist as enclaves carved out from larger host states (instead of replacing global ownership).

Implemented scaffolding notes:
- `scripts/gameplay/sim/PoliticsEventLayer.gd`: deterministic batched political events (`war_declared`, `treaty_signed`, `armistice_signed`) with persisted event log.
- Event cadence is coarse (weekly symbolic ticks) and designed for worldgen batch progression.
- Epoch multipliers (implemented v0 symbolic):
  - politics event chances (war/treaty/peace + unrest pressure) now scale by epoch/variant.
  - politics GPU unrest drift/decay also scales by epoch/variant.
  - government evolution is now scheduled (not instant): states carry `government_desired`, `government_target`, and delayed `government_shift_due_abs_day`; applied shifts emit `government_shift` events.
  - shift cadence follows user direction: typically years/decades, with rare month-scale rapid transitions.
- Territory flux scaffold (implemented v0 symbolic):
  - high-unrest provinces can rebel into new symbolic rebel states (`province_rebelled`).
  - active wars can transfer provinces between states (`province_transferred`).
  - states with no owned provinces are marked collapsed (`state_collapsed`) and can reactivate if they later regain land.
  - Locked tuning (2026-02-13):
    - border transfer base chance stays at `~4%` per weekly event tick (scaled by war multiplier).
    - rebellion trigger remains top-unrest province with threshold `~0.55`, chance scaled by unrest.
    - collapsed states remain reactivatable records (no auto-archive/remove).

Trade route capacity hooks (implemented v0 symbolic):
- `TradeRouteSeeder` now applies epoch/variant/government multipliers per endpoint state when computing route capacity.
- Route capacity therefore reflects both diplomacy (war/treaty/alliance) and societal era/governance level.

M3: NPC v0 (important NPCs only)
Status: scaffold implemented (v0 symbolic):
- Instantiate important NPCs (rulers, shopkeepers, quest givers).
- Disposition calculation from politics/economy/player standing.
- Deterministic daily schedules; local movement when in player region.
- Epoch hooks (implemented v0 symbolic):
  - `EpochSystem` now classifies current world epoch from civ tech/devastation.
  - Important NPCs receive epoch metadata (`epoch`, `epoch_variant`, `social_rigidity`) for dialogue/social-rule context.
  - Dialogue context now includes epoch and rigidity hints so class/standing dynamics can later vary by era.
  - NPC GPU tick now receives epoch/variant multipliers for needs/safety drift.

M4: LLM integration (dialogue only)
- Prompt contract for NPC chat.
- Language gating (cannot chat without shared language).
- Safety: sanitize outputs; enforce “state changes only via choices”.
Status: scaffold implemented (provider hook only):
- `scripts/gameplay/dialogue/NpcDialogueService.gd` provides a provider interface (`local_rules`, local-7B placeholder, Gemini placeholder) and deterministic local fallback lines.
- `GameState` now exposes `build_npc_dialogue_context(...)` and `get_npc_dialogue_line(...)` for scene integration.
- `LocalAreaScene` NPC interaction is wired to the dialogue scaffold with local fallback if no provider is active.

## Open Questions (For Later)
Locked decisions (2026-02-10):
- Commodities: keep the minimal set for now until the systems are validated; expand later.
- Settlement density: do not pre-place a fixed density. Civilization is simulated forward in worldgen until humans emerge, then spread over generations (hunter-gatherers -> villages -> cities -> states/empires, etc.). Settlement placement is therefore an outcome, not an input.
- LLM integration approach (testing): try a local quantized ~7B model first (e.g. Starling-7B / Mistral-family); if too slow or poor, use Gemini 2.5 Flash for speed and free quota during iteration.

Locked (2026-02-12):
- Planet-type parameters are **fully inferred** from climate/biome simulation fields (no first-class "planet type" knobs in v0).
GPU plumbing (implemented v0 scaffolding):
- Compute shaders:
  - `shaders/society/economy_tick.glsl`
  - `shaders/society/trade_flow_tick.glsl` (route-aware stock redistribution scaffold)
  - `shaders/society/politics_tick.glsl`
  - `shaders/society/npc_tick.glsl` (uses local-mask for higher-detail regional NPC updates)
- RD wiring:
  - `scripts/gameplay/sim/SocietyGpuBridge.gd` (uploads, ticks, snapshots on save/load)
  - NPC local-scope mask is derived from `GameState.location.political_state_id` (set from province ownership when available).

Politics map seeding (implemented v0 scaffolding):
- Seed a coarse province/state map when the world snapshot is initialized:
  - `scripts/gameplay/sim/PoliticsSeeder.gd`
  - Called from `GameState.initialize_world_snapshot(...)`
