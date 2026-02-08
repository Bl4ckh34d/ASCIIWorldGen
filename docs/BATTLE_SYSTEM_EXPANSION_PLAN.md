# Battle System Expansion Plan (FF1/FF2 Style)

## Summary
Expand the current battle scaffold into a classic turn-based RPG battle:
- Party on one side, enemies on the other.
- Menu commands: Attack, Magic, Item, Flee (FF-style command window).
- Target selection where appropriate.
- Multiple party members and (eventually) multiple enemies.
- Post-battle rewards screen: EXP, items, gold, level-ups.
- Deterministic outcomes from seed + encounter context.
- **Battle backgrounds per biome** that reflect day/night + weather, rendered GPU-only (shader-driven scaffold for now).

## Current Scaffold (What Exists Today)
- `scenes/BattleScene.tscn` + `scripts/gameplay/BattleScene.gd`
  - FF-like command menu:
    - vertical command window with pointer and keyboard Up/Down navigation
    - uppercased labels based on focus
  - Battle log output.
  - Result panel (victory shows reward logs: EXP, items, level-ups).
  - Applies rewards to `GameState` on Continue.
  - Item and Magic submenus with target selection.
    - Item targets are driven by item definition (`party` vs `enemy` vs `any`).
  - GPU-only procedural battle background shader:
    - biome palette base color
    - day/night from `GameState.world_time`
    - deterministic cloud coverage / rain and up to 3 moons (seeded)
- `scripts/gameplay/BattleStateMachine.gd`
  - Per-actor party and enemies (multi-enemy count-based).
  - FF9-like flow: select commands for alive party members, then resolve in initiative order (openers: preemptive/back attack).
  - Deterministic RNG via `DeterministicRng` using `encounter_seed_key` + `turn_index`.
- Catalog/registry stubs:
  - `scripts/gameplay/EncounterRegistry.gd` chooses enemy group/power/hp and rewards.
  - `scripts/gameplay/catalog/EnemyCatalog.gd` defines biome->enemy groups.
  - `scripts/gameplay/catalog/ItemCatalog.gd` defines a few items/equipment kinds.
- `GameState.apply_battle_result()` grants rewards and completes a starter quest on first victory.

## Goals
- Replace “blob HP” with per-actor:
  - Party: up to 4 members.
  - Enemies: 1..N.
- Command model:
  - Commands map to effects; some require target selection.
- Deterministic:
  - Given the encounter seed + chosen commands, battle results are repeatable.
- UX:
  - Battle flow feels like FF1/FF2: choose command, resolve, show logs, repeat.
  - Win screen clearly shows rewards and level-ups.
  - Expand toward FF9-style encounter variety: multiple enemies, mixed groups, and “preemptive/back attack” style openers.

## Non-Goals (For This Phase)
- ATB / real-time systems.
- Complex AI tactics.
- Full sprite animation / VFX. We keep a clean “text-first” UI, but do allow GPU shader backgrounds for biome/time/weather mood.

## Key Design Decisions (Need to Lock In)
Decisions per your direction:
1. Battle inspiration: aim for FF9-like feel (within a turn-based scaffold first).
2. Enemy model: encounters can be 1 enemy, multiple of the same, or mixed groups.
3. Encounter openers: chance-based:
   - party preemptive (party acts first)
   - enemy back-attack (enemies act first)
   - normal (face-to-face)
4. Defeat behavior: **game over** (load save or restart).
5. Flee: implement “FF9-like” flee behavior (chance-based; exact formula can be approximated first).

## Data Model Plan

### 1) `BattleActor`
Represent any combatant (party member or enemy).
Fields (minimum):
- `actor_id: String` (stable)
- `side: String` (`"party"` or `"enemy"`)
- `display_name: String`
- `hp, hp_max, mp, mp_max: int`
- `stats: Dictionary` (str/def/agi/int)
- `alive: bool`
- `status: Dictionary` (later)

Party actors come from `PartyStateModel.members`.
Enemy actors come from `EnemyCatalog`/`EncounterRegistry`.

### 2) `BattleCommand`
Fields:
- `cmd_id: String` (`attack`, `magic`, `item`, `flee`, later `defend`)
- `user_id: String`
- `target_id: String` (single target initially)
- `spell_id: String` optional
- `item_name: String` optional

### 3) Revised `BattleStateMachine`
Add phases:
- `INIT`
- `PLAYER_INPUT` (choose user + command + target)
- `RESOLVE_TURN`
- `RESULT` (victory/escape/defeat)

State:
- `actors: Array[Dictionary]` (serialize-friendly)
- `turn_index: int`
- `rng_seed_key: String` (from encounter)
- `pending_command: Dictionary`
- `result: Dictionary`

Determinism:
- All random rolls derive from:
  - `seed_hash = hash(encounter_seed_key)`
  - `tag = "hit|turn=...|user=...|target=..."`, etc.
  - Use `DeterministicRng` for all randomness.

## Content/Catalog Plan

### 1) Expand `EnemyCatalog`
Move toward:
- `get_enemy(enemy_id) -> stats, hp, mp, drops`
- `encounter_for_biome(...)` returns an enemy list:
  - `[ { "enemy_id": "wolf", "count": 2 }, ... ]`

Milestone:
- Start with 1 enemy entry to minimize UI churn.

### 2) Expand `ItemCatalog`
Define consumable effects:
- Potion: heal HP.
- Herb: small heal or status cure (later).

Define equipment effects:
- weapon/armor/accessory provide stat bonuses.

### 3) Add `SpellCatalog` (new)
At minimum:
- `Fire` (single-target damage)
- `Cure` (single-target heal)

## UI Plan (`BattleScene.tscn`)

### M0 UI (Minimal, upgrade current)
- Party panel listing 4 members:
  - Name, HP/MP, status.
- Enemy panel listing enemies:
  - Name, HP (optional to hide exact HP later).
- Command menu (FF-like):
  - vertical command window: Attack, Magic, Item, Flee
  - pointer shows focused command; Up/Down cycles focus; Enter activates
- Target selection:
  - When command requires target, move selection cursor over enemy/party list.
- Background:
  - GPU-only procedural battle background keyed by:
    - biome kind (forest/hills/mountains/desert/beach/swamp/snow)
    - day/night
    - cloud coverage + rain (later: snow)

### Result / Win Screen
Split “result panel” into two modes:
- Escape/Defeat: simple message + Continue.
- Victory: show:
  - EXP, gold, items
  - Level-up lines (already produced by `PartyMemberModel.gain_exp`)

## Integration With `GameState`
- On battle start:
  - Read `party` snapshot and build party actors.
  - Read inventory for Item command availability.
- On victory:
  - `GameState.apply_battle_result` remains the single place to grant rewards.
  - Ensure items removed/consumed are committed before leaving battle.
- On escape/defeat:
  - Track flags in `WorldFlagsStateModel` (already exists).
  - Decide penalties (open question).
  - Defeat routes to a Game Over screen (load/restart).

## Implementation Milestones

### M0: Per-Party Actors, Single Enemy
- Refactor `BattleStateMachine`:
  - Replace `party_hp` blob with an actor list for party.
  - Keep a single enemy actor for now.
- Update UI:
  - Display party member list.
  - Commands operate from “current member” (index cycles each turn).

### M1: Items Actually Consume Inventory
- Item command opens a small list of usable items from `GameState.party.inventory`.
- Applying an item:
  - Removes from inventory.
  - Heals the target.
Status: partially implemented (battle `Item` consumes a default consumable like `Potion/Herb` and heals; full item/target selection UI is still pending).

### M2: Magic + MP Costs
- Add `SpellCatalog`.
- Magic menu shows spells known (start with mage only).
- Apply damage/heal and subtract MP.
Status: minimal MP cost is implemented for `Magic` (spell selection still pending).

### M3: Multiple Enemies
- Update `EnemyCatalog` + `EncounterRegistry` to return an enemy list.
- Update UI target selection across multiple enemies.

### M3.5: Encounter Openers (Preemptive / Back Attack)
- Add a deterministic “opener roll” per encounter:
  - `opener = "preemptive"|"back_attack"|"normal"`
- Opener influences:
  - which side resolves first on turn 1
  - optional small damage multiplier (later)

### M4: Status Effects (Optional)
- Poison, sleep, etc.
- Add simple per-turn ticks.

## Testing / Verification
- Determinism script:
  - Given seed + scripted command sequence, final outcome hash matches baseline.
- Inventory integrity:
  - Item use decreases inventory count exactly once.
- Save/load around battles:
  - Save before battle, load, repeat battle -> same results (assuming same inputs).

## Open Questions (Need Your Answers)
Decisions per your answers:
1. Turn structure: FF9-like (select actions for the party, then resolve).
2. Encounters: can be 1 enemy, multiple of the same, or mixed groups; include chance-based openers (preemptive/back attack/normal).
3. Defeat: game over (load save or restart).
4. Flee: biome/encounter dependent with some chance (FF9-like behavior).
