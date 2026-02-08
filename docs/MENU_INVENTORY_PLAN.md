# Menu + Inventory (Slot Bags) Plan

## Summary
Expand the current `MenuOverlay` scaffold into a real in-game menu system:
- Overlay UI (not a separate scene flow) usable in regional + local area maps (and optionally in battle).
- **Valheim-like slot inventory per party member** (equipment occupies inventory slots).
- Drag & drop between slots (snap-to-slot) and right-click context actions.
- Drag-to-character behavior:
  - drop onto another character: give the item
  - drop onto the same character row: use the consumable on them
- HP/MP bars shown in the menu (for targeting consumables).
- Party stats pages (derived stats, resistances later).
- Settings, save/load, and a clean “return to world map / quit” flow.

This plan is deliberately incremental and keeps the **time system minimal**: no deep scheduling. Time advances normally during gameplay; only world-map evolution speed controls and fast travel temporarily accelerate time.

## Current Scaffold (What Exists Today)
- UI:
  - `scenes/ui/MenuOverlay.tscn` + `scripts/gameplay/MenuOverlay.gd`
  - TabContainer with: Overview, Party, **Characters** (slot-bag inventory + equipment unified), Quests, Settings
    - Legacy `Equipment` and `Stats` tabs still exist in the scene but are hidden (to reduce clutter).
  - Party tab shows HP/MP bars and core stats (STR/DEF/AGI/INT) per member.
  - Settings: encounter rate multiplier, auto-battle, text speed
  - Save/load: 3 slots via `GameState.save_to_path/load_from_path`
  - `Quit` exits to desktop (world map overlay is on `M`).
- Data:
  - `scripts/gameplay/GameState.gd` provides `get_menu_snapshot()` for text views.
  - Inventory source-of-truth is now:
    - `PartyMemberModel.bag` (slot array) + `bag_cols/bag_rows`
    - `PartyMemberModel.equipment` is still `{ weapon, armor, accessory }` (string item names)
  - `PartyStateModel.inventory` remains as a **derived/compat view** for battle + snapshots.
  - `ItemCatalog` has a small set of items with `kind`, `description`, `value`.

## Goals
- Menu overlay feels like a real RPG menu:
  - Readable, navigable, and consistent input behavior.
  - Shows party loadout + inventory clearly (same page).
  - Enables actual actions: use item, equip/unequip, drop, and rearrange slots.
  - HP/MP bars visible for party members and when selecting a target for consumables.
- Deterministic and save-friendly:
  - Inventory/equipment are part of `GameState` and saved/loaded cleanly.
- Scene integration:
  - Regional and Local maps should pause player movement while menu is open.
  - Menu should not cause simulation “speed-ups” outside world map and fast travel.

## Non-Goals (For This Phase)
- Fancy animated UI, controller glyphs, or full sprite layouts.
- Deep crafting, durability, encumbrance, or merchant economy.
- Complex time scheduling (NPC routines, timed quests). We keep time “light”.

## Time + Fast Travel (Minimal Requirements)
Per your direction:
- World map scene:
  - Has speed-up buttons to accelerate world evolution/simulation.
- Actual gameplay (regional/local/battle):
  - Runs at normal time (no speed controls).
- Fast travel:
  - Allowed only to **previously visited** world-map tiles.
  - During fast travel we temporarily advance time faster (travel time), then return to normal.

Implications for the menu:
- The in-game menu may expose a “Fast Travel” option only when you are on the world map (or when you open a “World” tab from gameplay and choose to return to world map first).

## Rest Until Morning (Planned)
Rule (per your direction):
- “Rest until morning” is only possible:
  - At Inns (costs money)
  - At Temples / Guildhalls if you are a member and have sufficient rank (later)
  - In nature only if you have a **Tent** item, which is consumed on use

Where this lives:
- Initially: a Menu action (“Rest”) that is only enabled when the current location/POI supports it.
- Later: actual POI interactions (Innkeeper, Temple services) should drive the same underlying “rest” API.

Notes:
- Rest should advance time to the next morning and can affect encounter chances and weather (later).

## Data Model Plan

### 1) Item Definitions (`ItemCatalog`)
Evolve `ItemCatalog` entries toward a stable schema:
- `id` (string): use the dictionary key (e.g. `"Potion"`) as the id for now.
- `kind`: `consumable`, `weapon`, `armor`, `accessory`, `key_item`.
- `description`: string.
- `stackable`: bool (default true for consumables/key items, false for equipment).
- `max_stack`: int (optional; default 99 for consumables).
- `equip_slot`: `weapon|armor|accessory` for equipment kinds.
- `stat_bonuses`: dictionary (e.g. `{ "strength": +2, "defense": +1 }`) for equipment.
- `use_effect`: dictionary for consumables (e.g. `{ "type": "heal_hp", "amount": 20 }`).

Milestone approach:
- Start by adding `stackable`, `equip_slot`, and a minimal `stat_bonuses` / `use_effect` shape.

### 2) Inventory Representation
**Source of truth (new): per-member slot bags**
- `PartyMemberModel.bag_cols`, `PartyMemberModel.bag_rows`
- `PartyMemberModel.bag: Array[Dictionary]` sized `bag_cols * bag_rows`
  - Empty slot: `{}` (or `{"name": "", "count": 0}`)
  - Stack slot: `{"name": "Potion", "count": 3}`
  - Equipped slot (equipment still occupies slot): `{"name": "Bronze Sword", "count": 1, "equipped_slot": "weapon"}`

**Compatibility view (kept for battle + snapshots):**
- `PartyStateModel.inventory: Dictionary<String,int>` is rebuilt from all bag slots.
  - Battle continues to use a party-wide item pool for now.

### 3) Equipment Representation
Current:
- `PartyMemberModel.equipment` stores item names.

Planned/Refined:
- Keep this but validate via `ItemCatalog` and keep in sync with the bag:
  - Weapon slot accepts items with `kind=weapon`.
  - Armor slot accepts items with `kind=armor`.
  - Accessory slot accepts items with `kind=accessory`.
- Equipping does **not** remove the item from the bag; it sets `equipped_slot` on that slot.
- Add derived stat calculation:
  - Base stats from member model + sum of equipment `stat_bonuses`.

Implementation note:
- Add `PartyMemberModel.get_total_stats(item_catalog)` helper or compute in `PartyStateModel`.

## Menu UX + Input Plan

### Opening/Closing
- Use one consistent toggle for gameplay scenes:
  - `Esc` / `Tab` opens/closes the menu overlay.
  - `M` opens the world-map overlay (fast travel), not the menu.
  - When closed, `Esc` does scene-appropriate behavior:
    - Regional: open menu (current behavior is acceptable).
    - Local: open menu (exit is on `Q`).
- When menu is open:
  - Block movement input in gameplay scenes (already done by checking `menu_overlay.visible`).

### Tab Layout (Keep Current Tabs)
1. **Overview**
   - Time (compact), seed, location, discovered/cleared counts.
   - “Return to world map” (and/or “Quit game”) actions.
2. **Party**
   - List members with HP/MP bars + core stats (STR/DEF/AGI/INT).
   - (Later) reorder party, swap active party, derived stats, resistances.
3. **Characters** (Inventory + Equipment unified)
   - Left: party members with HP/MP bars.
   - Right: selected member slot grid (`bag_cols * bag_rows`) where equipment lives alongside items.
   - Slot interaction:
     - Drag & drop to rearrange (swap or stack-merge if same stackable item).
     - Drag & drop onto a character row:
       - other character: give the item (auto-place into their bag)
       - same character: use the item on them (consumables only)
     - Right-click context menu:
       - `Use` (consumables): opens a target picker showing all party members with HP/MP bars.
       - `Equip/Unequip` (equipment): toggles equipment and updates derived stats.
       - `Drop`: removes item from slot (blocked if equipped).
   - Item details panel:
     - Kind, description, effect/bonuses, and last action message.
4. **Quests**
   - Show `QuestStateModel` summary; details later.
5. **Settings**
   - Encounter rate multiplier, auto battle, text speed (existing).
   - Volume sliders already exist in `SettingsStateModel` but are not wired to UI yet.

### Save/Load UX
Keep slot-based saves:
- Slot selection (1..3).
- Save writes the entire `GameState` snapshot (already).
- Load refreshes menu snapshot (already).

Planned enhancements:
- Add “confirm overwrite” prompt (later).
- Add slot metadata (timestamp, location, party level) shown in the OptionButton (later).

### Quit / Return Flow
Clarify two different actions:
- **World map overlay**: opened via `M` from gameplay; supports visited-only fast travel.
- **Quit game**: exit the app to desktop.

Current implementation: `Quit` exits to desktop; `M` opens the world-map overlay.

## Gameplay Integrations

### Using Items (Menu)
Rules:
- Consumables can be used in regional/local.
- Using an item:
  - Removes 1 from the selected slot stack.
  - Applies effect to a chosen party member (target picker with HP/MP bars).
  - Can be used even if it would be wasted (e.g. HP already full).
  - Advances time by a small amount (optional; recommend no time advance for menu use initially).

### Using Items (Battle)
Battle system plan already covers making Item command consume inventory.
Menu plan impact:
- Inventory API should be shared:
  - `PartyStateModel.remove_item(...)` already exists.
  - Add `PartyStateModel.has_item(...)` helper if needed.

### Equipment Effects
At minimum:
- Equipment modifies displayed stats and battle power calculation.
Where to apply:
- Add a `GameState.get_party_power()` adjustment based on equipped bonuses.

## Implementation Milestones

### M0: Document + Clean Up Terminology
- Rename “Quit” label/behavior once decided (return to world map vs quit app).
- Ensure menu snapshot lines show enough detail (member equipment, gold, etc).

### M1: Slot Inventory + Context Menu
- Implement per-member `bag` slot grids and derived `party.inventory` view.
- Implement right-click context actions: Use, Equip/Unequip, Drop.
- Implement drag & drop between slots (swap; merge stacks for same stackable item).

### M2: HP/MP Bars in Menu
- Show HP/MP bars next to party members.
- Show HP/MP bars in “use item” target picker.

### M3: Derived Stats + Battle Hook
- Compute total stats (base + bonuses).
- Update battle power / damage formulas to use totals (even if crude at first).

### M4: Save Slot Metadata (Optional)
- Store a small sidecar file or embed slot metadata in save payload.
- Show it in menu slot picker.

## Testing / Verification
- Inventory integrity:
  - Use item reduces count once; cannot go below 0.
  - Equip/unequip toggles without duplicating items and persists across save/load.
  - Equipped items block dropping and cross-character moves (if/when enabled).
- Determinism (where it matters):
  - Menu itself is deterministic; no random operations on open/close.
- UX:
  - Menu blocks movement in regional/local.
  - All buttons work with both mouse and keyboard.

## Open Questions (Need Your Answers)
Decisions per your answers:
1. In interiors, `Esc` opens the menu (key rebinding later).
2. Equipped items remain in inventory and occupy a slot while equipped (Valheim-like).
3. “Quit” quits the game to desktop (world map is on `M`).
4. Using consumables in the menu is time-neutral.
5. Fast travel UI is world-map-only (on `M`), not in the menu.

## Reminder (Do Not Forget)
- Time of day should affect encounters (more/harder encounters at night). This can be implemented later by extending `EncounterRegistry` to consider `WorldTimeStateModel` and/or a “night” predicate.
