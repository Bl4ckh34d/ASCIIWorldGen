extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")
const EconomyTickCompute = preload("res://scripts/systems/EconomyTickCompute.gd")
const TradeFlowTickCompute = preload("res://scripts/systems/TradeFlowTickCompute.gd")
const PoliticsTickCompute = preload("res://scripts/systems/PoliticsTickCompute.gd")
const NpcTickCompute = preload("res://scripts/systems/NpcTickCompute.gd")
const WildlifeTickCompute = preload("res://scripts/systems/WildlifeTickCompute.gd")
const CivilizationTickCompute = preload("res://scripts/systems/CivilizationTickCompute.gd")
const PopulationMigrateCompute = preload("res://scripts/systems/PopulationMigrateCompute.gd")
const SocietyOverlayTextureCompute = preload("res://scripts/systems/SocietyOverlayTextureCompute.gd")
const CommodityCatalog = preload("res://scripts/gameplay/catalog/CommodityCatalog.gd")
const EpochSystem = preload("res://scripts/gameplay/sim/EpochSystem.gd")

const EconomyStateModel = preload("res://scripts/gameplay/models/EconomyState.gd")
const PoliticsStateModel = preload("res://scripts/gameplay/models/PoliticsState.gd")
const NpcWorldStateModel = preload("res://scripts/gameplay/models/NpcWorldState.gd")
const WildlifeStateModel = preload("res://scripts/gameplay/models/WildlifeState.gd")
const CivilizationStateModel = preload("res://scripts/gameplay/models/CivilizationState.gd")

var _buf: GPUBufferManager = null
var _econ: EconomyTickCompute = null
var _trade: TradeFlowTickCompute = null
var _pol: PoliticsTickCompute = null
var _npc: NpcTickCompute = null
var _wild: WildlifeTickCompute = null
var _civ: CivilizationTickCompute = null
var _migrate: PopulationMigrateCompute = null
var _overlay_pack: SocietyOverlayTextureCompute = null
var _overlay_tex: Texture2D = null

var _dirty_upload: bool = true
var _econ_ids: PackedStringArray = PackedStringArray()
var _prov_ids: PackedStringArray = PackedStringArray()
var _npc_ids: PackedStringArray = PackedStringArray()

const _E_CONS: int = 6
const _TRADE_MAX_NEIGHBORS: int = 4
const _ECO_SHOCK_SCALAR: float = 1.0
var _world_w: int = 0
var _world_h: int = 0
var _pop_ping: int = 0 # 0 => pop_a is current, 1 => pop_b is current
var _econ_stock_ping: int = 0 # 0 => stock_a is current, 1 => stock_b is current
var _civ_war_pressure: float = 0.0
var _civ_global_devastation: float = 0.0

func _init() -> void:
	_buf = GPUBufferManager.new()
	_econ = EconomyTickCompute.new()
	_trade = TradeFlowTickCompute.new()
	_pol = PoliticsTickCompute.new()
	_npc = NpcTickCompute.new()
	_wild = WildlifeTickCompute.new()
	_civ = CivilizationTickCompute.new()
	_migrate = PopulationMigrateCompute.new()
	_overlay_pack = SocietyOverlayTextureCompute.new()

func _cleanup_if_supported(obj: Variant) -> void:
	if obj == null:
		return
	if obj is Object:
		var o: Object = obj as Object
		if o.has_method("cleanup"):
			o.call("cleanup")

func cleanup() -> void:
	_cleanup_if_supported(_overlay_pack)
	_cleanup_if_supported(_econ)
	_cleanup_if_supported(_trade)
	_cleanup_if_supported(_pol)
	_cleanup_if_supported(_npc)
	_cleanup_if_supported(_wild)
	_cleanup_if_supported(_civ)
	_cleanup_if_supported(_migrate)
	_cleanup_if_supported(_buf)
	_overlay_pack = null
	_overlay_tex = null
	_econ = null
	_trade = null
	_pol = null
	_npc = null
	_wild = null
	_civ = null
	_migrate = null
	_buf = null
	_dirty_upload = true
	_econ_ids = PackedStringArray()
	_prov_ids = PackedStringArray()
	_npc_ids = PackedStringArray()
	_world_w = 0
	_world_h = 0

func mark_dirty() -> void:
	_dirty_upload = true

func get_gpu_stats() -> Dictionary:
	if _buf == null:
		return {}
	var out: Dictionary = {}
	if "get_buffer_stats" in _buf:
		out["buffers"] = _buf.get_buffer_stats()
	if "get_io_stats" in _buf:
		out["io"] = _buf.get_io_stats()
	out["world_w"] = _world_w
	out["world_h"] = _world_h
	out["econ_nodes"] = _econ_ids.size()
	out["pol_provinces"] = _prov_ids.size()
	out["npc_important"] = _npc_ids.size()
	return out

func ensure_uploaded(world_seed_hash: int, world_w: int, world_h: int, world_biome_ids: PackedInt32Array, econ: EconomyStateModel, pol: PoliticsStateModel, npc: NpcWorldStateModel, wild: WildlifeStateModel, civ: CivilizationStateModel, location: Dictionary) -> bool:
	if econ == null or pol == null or npc == null or wild == null or civ == null:
		return false
	if not _dirty_upload:
		return true
	if RenderingServer.get_rendering_device() == null:
		push_error("SocietyGpuBridge: RenderingDevice unavailable (GPU-only sim).")
		return false

	_world_w = max(0, int(world_w))
	_world_h = max(0, int(world_h))
	_build_id_lists(econ, pol, npc)
	_upload_world_biomes(world_biome_ids)
	_upload_wildlife(world_seed_hash, wild)
	_upload_civilization(world_seed_hash, civ, wild)
	_upload_economy(world_seed_hash, econ)
	_upload_politics(world_seed_hash, pol)
	_upload_politics_tile_states(pol)
	_upload_npcs(world_seed_hash, npc, location)
	_dirty_upload = false
	return true

func _hash_state_id_u8(state_id: String) -> int:
	# Deterministic mapping of arbitrary string ids to [1..255]. 0 reserved for "none".
	state_id = String(state_id)
	if state_id.is_empty():
		return 0
	var v: int = abs(int(state_id.hash()))
	return 1 + (v % 255)

func _upload_politics_tile_states(pol: PoliticsStateModel) -> void:
	# Build a per-world-tile buffer of hashed owner state id (0..255).
	var w: int = _world_w
	var h: int = _world_h
	var size: int = w * h
	if size <= 0:
		return
	var out := PackedInt32Array()
	out.resize(size)
	out.fill(0)
	if pol == null:
		var bytes0: PackedByteArray = out.to_byte_array()
		_buf.ensure_buffer("soc_pol_state_tile", bytes0.size(), bytes0)
		return
	var s: int = max(1, int(pol.province_size_world_tiles))
	for y in range(h):
		var py: int = int(floor(float(y) / float(s)))
		for x in range(w):
			var px: int = int(floor(float(x) / float(s)))
			var prov_id: String = "province|%d|%d" % [px, py]
			var pv: Variant = pol.provinces.get(prov_id, {})
			var owner: String = ""
			if typeof(pv) == TYPE_DICTIONARY:
				owner = String((pv as Dictionary).get("owner_state_id", ""))
			out[x + y * w] = _hash_state_id_u8(owner)
	var bytes: PackedByteArray = out.to_byte_array()
	_buf.ensure_buffer("soc_pol_state_tile", bytes.size(), bytes)

func tick_days(world_seed_hash: int, world_w: int, world_h: int, abs_day: int, dt_days: float, econ: EconomyStateModel, pol: PoliticsStateModel, npc: NpcWorldStateModel, wild: WildlifeStateModel, civ: CivilizationStateModel, world_biome_ids: PackedInt32Array, location: Dictionary) -> bool:
	if not ensure_uploaded(world_seed_hash, world_w, world_h, world_biome_ids, econ, pol, npc, wild, civ, location):
		return false
	var ok := true
	var dt: float = max(0.0, float(dt_days))
	ok = _tick_wildlife(abs_day, dt) and ok
	ok = _tick_civilization(abs_day, dt, civ, pol) and ok
	ok = _tick_migration(abs_day, dt, civ) and ok
	ok = _tick_economy(abs_day, dt, civ) and ok
	ok = _tick_politics(abs_day, dt, civ) and ok
	ok = _tick_npcs(abs_day, dt, civ) and ok
	return ok

func snapshot_to_cpu(econ: EconomyStateModel, pol: PoliticsStateModel, npc: NpcWorldStateModel, wild: WildlifeStateModel, civ: CivilizationStateModel) -> void:
	# Explicit transition point only (save/load). Avoid calling in hot paths.
	if econ != null:
		_snapshot_economy(econ)
	if pol != null:
		_snapshot_politics(pol)
	if npc != null:
		_snapshot_npcs(npc)
	if wild != null:
		_snapshot_wildlife(wild)
	if civ != null:
		_snapshot_civilization(civ)

func update_overlay_texture(pop_ref: float = 120.0) -> Texture2D:
	# GPU-only visualization: pack current buffers into an RGBA32F texture.
	if _overlay_pack == null:
		return null
	var b_wild: RID = _buf.get_buffer("soc_wild_density")
	var b_pop: RID = _pop_buf_current()
	var b_state: RID = _buf.get_buffer("soc_pol_state_tile")
	if not (b_wild.is_valid() and b_pop.is_valid() and b_state.is_valid()):
		return null
	_overlay_tex = _overlay_pack.update_from_buffers(_world_w, _world_h, b_wild, b_pop, b_state, pop_ref)
	return _overlay_tex

func read_debug_tile(world_x: int, world_y: int) -> Dictionary:
	# Small, on-demand readback for worldgen hover UI. Cache at caller.
	if _world_w <= 0 or _world_h <= 0:
		return {}
	var x: int = posmod(int(world_x), _world_w)
	var y: int = clamp(int(world_y), 0, _world_h - 1)
	var idx: int = x + y * _world_w
	var off: int = idx * 4
	var out: Dictionary = {"x": x, "y": y}
	var b_wild: RID = _buf.get_buffer("soc_wild_density")
	var b_pop: RID = _pop_buf_current()
	if b_wild.is_valid():
		var bytes_w: PackedByteArray = _buf.read_buffer_region("soc_wild_density", off, 4)
		var a_w: PackedFloat32Array = bytes_w.to_float32_array()
		if a_w.size() > 0:
			out["wildlife"] = float(a_w[0])
	if b_pop.is_valid():
		var bytes_p: PackedByteArray = _buf.read_buffer_region("soc_civ_pop_a" if _pop_ping == 0 else "soc_civ_pop_b", off, 4)
		var a_p: PackedFloat32Array = bytes_p.to_float32_array()
		if a_p.size() > 0:
			out["human_pop"] = float(a_p[0])
	var b_meta: RID = _buf.get_buffer("soc_civ_meta")
	if b_meta.is_valid():
		var bytes_m: PackedByteArray = _buf.read_buffer_region("soc_civ_meta", 0, 16)
		var a_m: PackedFloat32Array = bytes_m.to_float32_array()
		if a_m.size() >= 2:
			out["humans_emerged"] = a_m[0] >= 0.5
			out["tech_level"] = float(a_m[1])
			out["war_pressure"] = float(a_m[2]) if a_m.size() >= 3 else 0.0
			out["devastation"] = float(a_m[3]) if a_m.size() >= 4 else 0.0
	return out

func read_population_snapshot() -> PackedFloat32Array:
	# Explicit coarse sampling only (worldgen settlement extraction), not a hot path.
	var name: String = "soc_civ_pop_a" if _pop_ping == 0 else "soc_civ_pop_b"
	if not _buf.get_buffer(name).is_valid():
		# Backward compatibility if ping-pong not initialized yet.
		name = "soc_civ_pop"
	var bytes: PackedByteArray = _buf.read_buffer(name)
	return bytes.to_float32_array()

func _build_id_lists(econ: EconomyStateModel, pol: PoliticsStateModel, npc: NpcWorldStateModel) -> void:
	_econ_ids = PackedStringArray()
	for k in econ.settlements.keys():
		_econ_ids.append(String(k))
	_econ_ids.sort()

	_prov_ids = PackedStringArray()
	for k in pol.provinces.keys():
		_prov_ids.append(String(k))
	_prov_ids.sort()

	_npc_ids = PackedStringArray()
	for k in npc.important_npcs.keys():
		_npc_ids.append(String(k))
	_npc_ids.sort()

func _upload_world_biomes(world_biome_ids: PackedInt32Array) -> void:
	var size: int = _world_w * _world_h
	if size <= 0:
		return
	if world_biome_ids.size() != size:
		# Do not try to patch lengths; treat as invalid snapshot.
		push_error("SocietyGpuBridge: world_biome_ids size mismatch for upload.")
		return
	var bytes: PackedByteArray = world_biome_ids.to_byte_array()
	_buf.ensure_buffer("soc_world_biome", bytes.size(), bytes)

func _upload_wildlife(_world_seed_hash: int, wild: WildlifeStateModel) -> void:
	if wild == null:
		return
	wild.ensure_size(_world_w, _world_h, 0.65)
	var bytes: PackedByteArray = wild.density.to_byte_array()
	var b_wild: RID = _buf.ensure_buffer("soc_wild_density", bytes.size(), bytes)
	# Bind later when civilization buffer exists too.

func _upload_civilization(world_seed_hash: int, civ: CivilizationStateModel, wild: WildlifeStateModel) -> void:
	if civ == null:
		return
	civ.ensure_size(_world_w, _world_h)
	# Seed starting point deterministically if unset.
	if int(civ.start_world_x) < 0 or int(civ.start_world_y) < 0:
		civ.start_world_x = abs(int(("civ_start_x|" + str(world_seed_hash)).hash())) % max(1, _world_w)
		civ.start_world_y = abs(int(("civ_start_y|" + str(world_seed_hash)).hash())) % max(1, _world_h)
	var bytes_pop: PackedByteArray = civ.human_pop.to_byte_array()
	# Ping-pong buffers for migration.
	var b_pop_a: RID = _buf.ensure_buffer("soc_civ_pop_a", bytes_pop.size(), bytes_pop)
	var b_pop_b: RID = _buf.ensure_buffer("soc_civ_pop_b", bytes_pop.size())
	_pop_ping = 0

	var meta := PackedFloat32Array()
	meta.resize(4)
	meta[0] = 1.0 if civ.humans_emerged else 0.0
	meta[1] = clamp(float(civ.tech_level), 0.0, 1.0)
	meta[2] = 0.0 # war pressure (runtime-updated hook)
	meta[3] = clamp(float(civ.global_devastation), 0.0, 1.0)
	_civ_war_pressure = meta[2]
	_civ_global_devastation = meta[3]
	var bytes_meta: PackedByteArray = meta.to_byte_array()
	var b_meta: RID = _buf.ensure_buffer("soc_civ_meta", bytes_meta.size(), bytes_meta)

	# Re-bind wildlife now that we have pop buffer too.
	var b_biome: RID = _buf.get_buffer("soc_world_biome")
	var b_wild: RID = _buf.get_buffer("soc_wild_density")
	if b_biome.is_valid() and b_wild.is_valid():
		_wild.bind_buffers(b_biome, b_wild, b_pop_a)
	if b_wild.is_valid() and b_meta.is_valid():
		_civ.bind_buffers(b_pop_a, b_wild, b_meta)
	if b_wild.is_valid() and b_pop_a.is_valid() and b_pop_b.is_valid():
		_migrate.bind_buffers(b_pop_a, b_wild, b_pop_b)

func _upload_economy(world_seed_hash: int, econ: EconomyStateModel) -> void:
	var coms: Array[String] = CommodityCatalog.keys()
	var cc: int = min(_E_CONS, coms.size())
	var n: int = _econ_ids.size()
	var total: int = n * cc
	var alloc_total: int = max(1, total)
	var prod := PackedFloat32Array()
	var cons := PackedFloat32Array()
	var stock := PackedFloat32Array()
	var prices := PackedFloat32Array()
	var scarcity := PackedFloat32Array()
	prod.resize(alloc_total)
	cons.resize(alloc_total)
	stock.resize(alloc_total)
	prices.resize(alloc_total)
	scarcity.resize(alloc_total)
	prod.fill(0.0)
	cons.fill(0.0)
	stock.fill(0.0)
	prices.fill(1.0)
	scarcity.fill(0.0)

	for i in range(n):
		var sid: String = _econ_ids[i]
		var stv: Variant = econ.settlements.get(sid, {})
		if typeof(stv) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = stv as Dictionary
		var p: Dictionary = st.get("production", {})
		var c: Dictionary = st.get("consumption", {})
		var s: Dictionary = st.get("stockpile", {})
		var pr: Dictionary = st.get("prices", {})
		var sc: Dictionary = st.get("scarcity", {})
		for j in range(cc):
			var key: String = String(coms[j])
			var idx: int = i * cc + j
			prod[idx] = float(p.get(key, 0.0))
			cons[idx] = float(c.get(key, 0.0))
			stock[idx] = float(s.get(key, 0.0))
			prices[idx] = float(pr.get(key, CommodityCatalog.base_price(key)))
			scarcity[idx] = float(sc.get(key, 0.0))

	# Persistent buffers.
	var bytes_prod: PackedByteArray = prod.to_byte_array()
	var bytes_cons: PackedByteArray = cons.to_byte_array()
	var bytes_stock: PackedByteArray = stock.to_byte_array()
	var bytes_prices: PackedByteArray = prices.to_byte_array()
	var bytes_scar: PackedByteArray = scarcity.to_byte_array()
	var b_prod: RID = _buf.ensure_buffer("soc_econ_prod", bytes_prod.size(), bytes_prod)
	var b_cons: RID = _buf.ensure_buffer("soc_econ_cons", bytes_cons.size(), bytes_cons)
	var b_stock_a: RID = _buf.ensure_buffer("soc_econ_stock_a", bytes_stock.size(), bytes_stock)
	var b_stock_b: RID = _buf.ensure_buffer("soc_econ_stock_b", bytes_stock.size(), bytes_stock)
	var b_prices: RID = _buf.ensure_buffer("soc_econ_prices", bytes_prices.size(), bytes_prices)
	var b_scar: RID = _buf.ensure_buffer("soc_econ_scarcity", bytes_scar.size(), bytes_scar)
	_econ_stock_ping = 0
	_upload_trade_adjacency(world_seed_hash, econ)
	var b_nei_idx: RID = _buf.get_buffer("soc_trade_neigh_idx")
	var b_nei_cap: RID = _buf.get_buffer("soc_trade_neigh_cap")
	var b_stock_cur: RID = _econ_stock_buf_current()
	var b_stock_next: RID = _econ_stock_buf_next()
	if b_prod.is_valid() and b_cons.is_valid() and b_stock_cur.is_valid() and b_prices.is_valid() and b_scar.is_valid():
		_econ.bind_buffers(b_prod, b_cons, b_stock_cur, b_prices, b_scar)
	if b_nei_idx.is_valid() and b_nei_cap.is_valid() and b_stock_cur.is_valid() and b_stock_next.is_valid():
		_trade.bind_buffers(b_nei_idx, b_nei_cap, b_stock_cur, b_stock_next)

func _econ_stock_buf_current() -> RID:
	return _buf.get_buffer("soc_econ_stock_a" if _econ_stock_ping == 0 else "soc_econ_stock_b")

func _econ_stock_buf_next() -> RID:
	return _buf.get_buffer("soc_econ_stock_b" if _econ_stock_ping == 0 else "soc_econ_stock_a")

func _rebind_economy_and_trade() -> void:
	var b_prod: RID = _buf.get_buffer("soc_econ_prod")
	var b_cons: RID = _buf.get_buffer("soc_econ_cons")
	var b_prices: RID = _buf.get_buffer("soc_econ_prices")
	var b_scar: RID = _buf.get_buffer("soc_econ_scarcity")
	var b_nei_idx: RID = _buf.get_buffer("soc_trade_neigh_idx")
	var b_nei_cap: RID = _buf.get_buffer("soc_trade_neigh_cap")
	var b_stock_cur: RID = _econ_stock_buf_current()
	var b_stock_next: RID = _econ_stock_buf_next()
	if b_prod.is_valid() and b_cons.is_valid() and b_stock_cur.is_valid() and b_prices.is_valid() and b_scar.is_valid():
		_econ.bind_buffers(b_prod, b_cons, b_stock_cur, b_prices, b_scar)
	if b_nei_idx.is_valid() and b_nei_cap.is_valid() and b_stock_cur.is_valid() and b_stock_next.is_valid():
		_trade.bind_buffers(b_nei_idx, b_nei_cap, b_stock_cur, b_stock_next)

func _swap_economy_stock_buffers() -> void:
	_econ_stock_ping = 1 - _econ_stock_ping
	_rebind_economy_and_trade()

func _upload_trade_adjacency(_world_seed_hash: int, econ: EconomyStateModel) -> void:
	var n: int = _econ_ids.size()
	var total: int = max(1, n * _TRADE_MAX_NEIGHBORS)
	var neigh_idx := PackedInt32Array()
	var neigh_cap := PackedFloat32Array()
	neigh_idx.resize(total)
	neigh_cap.resize(total)
	neigh_idx.fill(-1)
	neigh_cap.fill(0.0)
	if n <= 0 or econ == null:
		_buf.ensure_buffer("soc_trade_neigh_idx", neigh_idx.to_byte_array().size(), neigh_idx.to_byte_array())
		_buf.ensure_buffer("soc_trade_neigh_cap", neigh_cap.to_byte_array().size(), neigh_cap.to_byte_array())
		return

	var id_to_idx: Dictionary = {}
	for i in range(n):
		id_to_idx[String(_econ_ids[i])] = i
	var degree := PackedInt32Array()
	degree.resize(n)
	degree.fill(0)

	for rv in econ.routes:
		if typeof(rv) != TYPE_DICTIONARY:
			continue
		var r: Dictionary = rv as Dictionary
		var a_id: String = String(r.get("a", ""))
		var b_id: String = String(r.get("b", ""))
		if not id_to_idx.has(a_id) or not id_to_idx.has(b_id):
			continue
		var ia: int = int(id_to_idx[a_id])
		var ib: int = int(id_to_idx[b_id])
		if ia < 0 or ib < 0 or ia >= n or ib >= n or ia == ib:
			continue
		var cap: float = max(0.0, float(r.get("capacity", 0.0)))
		var slot_a: int = int(degree[ia])
		if slot_a < _TRADE_MAX_NEIGHBORS:
			var idx_a: int = ia * _TRADE_MAX_NEIGHBORS + slot_a
			neigh_idx[idx_a] = ib
			neigh_cap[idx_a] = cap
			degree[ia] = slot_a + 1
		var slot_b: int = int(degree[ib])
		if slot_b < _TRADE_MAX_NEIGHBORS:
			var idx_b: int = ib * _TRADE_MAX_NEIGHBORS + slot_b
			neigh_idx[idx_b] = ia
			neigh_cap[idx_b] = cap
			degree[ib] = slot_b + 1

	_buf.ensure_buffer("soc_trade_neigh_idx", neigh_idx.to_byte_array().size(), neigh_idx.to_byte_array())
	_buf.ensure_buffer("soc_trade_neigh_cap", neigh_cap.to_byte_array().size(), neigh_cap.to_byte_array())

func _upload_politics(_world_seed_hash: int, pol: PoliticsStateModel) -> void:
	var n: int = _prov_ids.size()
	var unrest := PackedFloat32Array()
	unrest.resize(n)
	for i in range(n):
		var pid: String = _prov_ids[i]
		var pv: Variant = pol.provinces.get(pid, {})
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = pv as Dictionary
		unrest[i] = clamp(float(p.get("unrest", 0.0)), 0.0, 1.0)
	var b_unrest: RID = _buf.ensure_buffer("soc_pol_unrest", unrest.to_byte_array().size(), unrest.to_byte_array())
	_pol.bind_buffers(b_unrest)

var _last_local_state_id: String = ""

func _upload_npcs(_world_seed_hash: int, npc: NpcWorldStateModel, location: Dictionary) -> void:
	var n: int = _npc_ids.size()
	var needs := PackedFloat32Array()
	needs.resize(n * 4)
	var local_mask := PackedInt32Array()
	local_mask.resize(n)
	local_mask.fill(0)

	# Local scope: same political unit as current location (state/kingdom/empire).
	var local_state_id: String = _local_state_id_for_location(location)
	_last_local_state_id = local_state_id

	for i in range(n):
		var nid: String = _npc_ids[i]
		var vv: Variant = npc.important_npcs.get(nid, {})
		if typeof(vv) != TYPE_DICTIONARY:
			continue
		var nd: Dictionary = vv as Dictionary
		var ns: Dictionary = nd.get("needs", {})
		var base: int = i * 4
		needs[base + 0] = clamp(float(ns.get("hunger", 0.0)), 0.0, 1.0)
		needs[base + 1] = clamp(float(ns.get("thirst", 0.0)), 0.0, 1.0)
		needs[base + 2] = clamp(float(ns.get("safety", 0.0)), 0.0, 1.0)
		needs[base + 3] = clamp(float(ns.get("wealth", 0.0)), 0.0, 1.0)
		if String(nd.get("home_state_id", "")) == local_state_id and not local_state_id.is_empty():
			local_mask[i] = 1

	var b_needs: RID = _buf.ensure_buffer("soc_npc_needs", needs.to_byte_array().size(), needs.to_byte_array())
	var b_mask: RID = _buf.ensure_buffer("soc_npc_local_mask", local_mask.to_byte_array().size(), local_mask.to_byte_array())
	_npc.bind_buffers(b_needs, b_mask)

func update_local_scope(location: Dictionary, npc: NpcWorldStateModel) -> void:
	# Update only the local-mask buffer (cheap) when crossing political boundaries.
	var local_state_id: String = _local_state_id_for_location(location)
	if local_state_id == _last_local_state_id:
		return
	_last_local_state_id = local_state_id
	var n: int = _npc_ids.size()
	if n <= 0:
		return
	var local_mask := PackedInt32Array()
	local_mask.resize(n)
	local_mask.fill(0)
	for i in range(n):
		var nid: String = _npc_ids[i]
		var vv: Variant = npc.important_npcs.get(nid, {})
		if typeof(vv) != TYPE_DICTIONARY:
			continue
		var nd: Dictionary = vv as Dictionary
		if String(nd.get("home_state_id", "")) == local_state_id and not local_state_id.is_empty():
			local_mask[i] = 1
	var b_mask: RID = _buf.ensure_buffer("soc_npc_local_mask", local_mask.to_byte_array().size(), local_mask.to_byte_array())
	# Rebind uniform set (buffer RID may be reused/updated); safe for scaffolding.
	if _npc != null:
		var b_needs: RID = _buf.get_buffer("soc_npc_needs")
		if b_needs.is_valid():
			_npc.bind_buffers(b_needs, b_mask)

func _local_state_id_for_location(location: Dictionary) -> String:
	# Best-effort: derive state id from location and province mapping in CPU state (uploaded separately).
	# We intentionally keep politics metadata on CPU and only push numeric fields to GPU.
	return String(location.get("political_state_id", "")) if location.has("political_state_id") else ""

func _tick_wildlife(abs_day: int, dt_days: float) -> bool:
	return _wild.dispatch(_world_w, _world_h, abs_day, dt_days)

func _tick_civilization(abs_day: int, dt_days: float, civ: CivilizationStateModel, pol: PoliticsStateModel) -> bool:
	var emergence_day: int = int(civ.emergence_abs_day) if civ != null else 365 * 200
	var sx: int = int(civ.start_world_x) if civ != null else 0
	var sy: int = int(civ.start_world_y) if civ != null else 0
	var humans_emerged: bool = VariantCasts.to_bool(civ.humans_emerged) if civ != null else false
	if not humans_emerged and abs_day >= emergence_day:
		humans_emerged = true
		if civ != null:
			civ.humans_emerged = true
	var tech_level: float = clamp(float(civ.tech_level), 0.0, 1.0) if civ != null else 0.0
	var states_count: int = int(pol.states.size()) if pol != null else 0
	var wars_count: int = int(pol.wars.size()) if pol != null else 0
	var war_pressure: float = 0.0
	if states_count > 0:
		war_pressure = clamp(float(wars_count) / float(states_count), 0.0, 1.0)
	_civ_war_pressure = war_pressure
	# Scaffold warfare/devastation hook:
	# - war pressure increases devastation
	# - devastation decays slowly in peacetime
	_civ_global_devastation += (war_pressure * 0.18 - _civ_global_devastation * 0.05) * max(0.0, dt_days)
	_civ_global_devastation = clamp(_civ_global_devastation, 0.0, 1.0)
	if civ != null:
		civ.global_devastation = _civ_global_devastation
	var meta := PackedFloat32Array()
	meta.resize(4)
	meta[0] = 1.0 if humans_emerged else 0.0
	meta[1] = tech_level
	meta[2] = war_pressure
	meta[3] = _civ_global_devastation
	_buf.update_buffer("soc_civ_meta", meta.to_byte_array())
	return _civ.dispatch(_world_w, _world_h, abs_day, dt_days, emergence_day, sx, sy)

func _pop_buf_current() -> RID:
	return _buf.get_buffer("soc_civ_pop_a" if _pop_ping == 0 else "soc_civ_pop_b")

func _pop_buf_next() -> RID:
	return _buf.get_buffer("soc_civ_pop_b" if _pop_ping == 0 else "soc_civ_pop_a")

func _swap_pop_buffers() -> void:
	_pop_ping = 1 - _pop_ping
	var b_biome: RID = _buf.get_buffer("soc_world_biome")
	var b_wild: RID = _buf.get_buffer("soc_wild_density")
	var b_meta: RID = _buf.get_buffer("soc_civ_meta")
	var b_pop_cur: RID = _pop_buf_current()
	var b_pop_next: RID = _pop_buf_next()
	if b_biome.is_valid() and b_wild.is_valid() and b_pop_cur.is_valid():
		_wild.bind_buffers(b_biome, b_wild, b_pop_cur)
	if b_wild.is_valid() and b_meta.is_valid() and b_pop_cur.is_valid():
		_civ.bind_buffers(b_pop_cur, b_wild, b_meta)
	if b_wild.is_valid() and b_pop_cur.is_valid() and b_pop_next.is_valid():
		_migrate.bind_buffers(b_pop_cur, b_wild, b_pop_next)

func _tick_migration(abs_day: int, dt_days: float, civ: CivilizationStateModel) -> bool:
	# Slightly higher mobility early after emergence to help the first band spread.
	var move_rate: float = 0.06
	if civ != null:
		var since: int = int(abs_day) - int(civ.emergence_abs_day)
		if since >= 0 and since < 365:
			move_rate = 0.10
	var ok: bool = _migrate.dispatch(_world_w, _world_h, abs_day, dt_days, move_rate, 0.18)
	if ok:
		_swap_pop_buffers()
	return ok

func _tick_economy(abs_day: int, dt_days: float, civ: CivilizationStateModel) -> bool:
	var cc: int = min(_E_CONS, CommodityCatalog.keys().size())
	var em: Dictionary = EpochSystem.economy_multipliers(
		String(civ.epoch_id) if civ != null else "prehistoric",
		String(civ.epoch_variant) if civ != null else "stable"
	)
	var ok_e: bool = _econ.dispatch(
		_econ_ids.size(),
		cc,
		abs_day,
		dt_days,
		_civ_war_pressure,
		_civ_global_devastation,
		_ECO_SHOCK_SCALAR,
		float(em.get("prod_scale", 1.0)),
		float(em.get("cons_scale", 1.0)),
		float(em.get("scarcity_scale", 1.0)),
		float(em.get("price_speed", 1.0))
	)
	if not ok_e:
		return false
	# Route-aware redistribution pass (GPU, symbolic).
	var ok_t: bool = _trade.dispatch(_econ_ids.size(), cc, _TRADE_MAX_NEIGHBORS, abs_day, dt_days)
	if ok_t:
		_swap_economy_stock_buffers()
	return ok_t

func _tick_politics(abs_day: int, dt_days: float, civ: CivilizationStateModel) -> bool:
	var pm: Dictionary = EpochSystem.politics_multipliers(
		String(civ.epoch_id) if civ != null else "prehistoric",
		String(civ.epoch_variant) if civ != null else "stable"
	)
	return _pol.dispatch(
		_prov_ids.size(),
		abs_day,
		dt_days,
		float(pm.get("unrest_decay_scale", 1.0)),
		float(pm.get("unrest_drift", 0.0))
	)

func _tick_npcs(abs_day: int, dt_days: float, civ: CivilizationStateModel) -> bool:
	var nm: Dictionary = EpochSystem.npc_multipliers(
		String(civ.epoch_id) if civ != null else "prehistoric",
		String(civ.epoch_variant) if civ != null else "stable"
	)
	return _npc.dispatch(
		_npc_ids.size(),
		abs_day,
		dt_days,
		float(nm.get("need_gain_scale", 1.0)),
		float(nm.get("local_relief_scale", 1.0)),
		float(nm.get("remote_stress_scale", 1.0))
	)

func _snapshot_economy(econ: EconomyStateModel) -> void:
	var cc: int = min(_E_CONS, CommodityCatalog.keys().size())
	var n: int = _econ_ids.size()
	if n <= 0:
		return
	var bytes_stock: PackedByteArray = _buf.read_buffer("soc_econ_stock_a" if _econ_stock_ping == 0 else "soc_econ_stock_b")
	var bytes_prices: PackedByteArray = _buf.read_buffer("soc_econ_prices")
	var bytes_scar: PackedByteArray = _buf.read_buffer("soc_econ_scarcity")
	var stock: PackedFloat32Array = bytes_stock.to_float32_array()
	var prices: PackedFloat32Array = bytes_prices.to_float32_array()
	var scarcity: PackedFloat32Array = bytes_scar.to_float32_array()
	var coms: Array[String] = CommodityCatalog.keys()
	for i in range(n):
		var sid: String = _econ_ids[i]
		var stv: Variant = econ.settlements.get(sid, {})
		if typeof(stv) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = (stv as Dictionary).duplicate(true)
		var s: Dictionary = st.get("stockpile", {})
		var pr: Dictionary = st.get("prices", {})
		var sc: Dictionary = st.get("scarcity", {})
		for j in range(cc):
			var idx: int = i * cc + j
			var key: String = String(coms[j])
			if idx < stock.size():
				s[key] = float(stock[idx])
			if idx < prices.size():
				pr[key] = float(prices[idx])
			if idx < scarcity.size():
				sc[key] = float(scarcity[idx])
		st["stockpile"] = s
		st["prices"] = pr
		st["scarcity"] = sc
		econ.settlements[sid] = st

func _snapshot_politics(pol: PoliticsStateModel) -> void:
	var n: int = _prov_ids.size()
	if n <= 0:
		return
	var bytes_unrest: PackedByteArray = _buf.read_buffer("soc_pol_unrest")
	var unrest: PackedFloat32Array = bytes_unrest.to_float32_array()
	for i in range(n):
		if i >= unrest.size():
			break
		var pid: String = _prov_ids[i]
		var pv: Variant = pol.provinces.get(pid, {})
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = (pv as Dictionary).duplicate(true)
		p["unrest"] = float(unrest[i])
		pol.provinces[pid] = p

func _snapshot_npcs(npc: NpcWorldStateModel) -> void:
	var n: int = _npc_ids.size()
	if n <= 0:
		return
	var bytes_needs: PackedByteArray = _buf.read_buffer("soc_npc_needs")
	var needs: PackedFloat32Array = bytes_needs.to_float32_array()
	for i in range(n):
		var base: int = i * 4
		if base + 3 >= needs.size():
			break
		var nid: String = _npc_ids[i]
		var vv: Variant = npc.important_npcs.get(nid, {})
		if typeof(vv) != TYPE_DICTIONARY:
			continue
		var nd: Dictionary = (vv as Dictionary).duplicate(true)
		var ns: Dictionary = nd.get("needs", {})
		ns["hunger"] = float(needs[base + 0])
		ns["thirst"] = float(needs[base + 1])
		ns["safety"] = float(needs[base + 2])
		ns["wealth"] = float(needs[base + 3])
		nd["needs"] = ns
		npc.important_npcs[nid] = nd

func _snapshot_wildlife(wild: WildlifeStateModel) -> void:
	if wild == null:
		return
	var bytes: PackedByteArray = _buf.read_buffer("soc_wild_density")
	var arr: PackedFloat32Array = bytes.to_float32_array()
	wild.ensure_size(_world_w, _world_h, 0.65)
	if arr.size() == wild.density.size():
		wild.density = arr

func _snapshot_civilization(civ: CivilizationStateModel) -> void:
	if civ == null:
		return
	var bytes_pop: PackedByteArray = _buf.read_buffer("soc_civ_pop_a" if _pop_ping == 0 else "soc_civ_pop_b")
	var pop: PackedFloat32Array = bytes_pop.to_float32_array()
	civ.ensure_size(_world_w, _world_h)
	if pop.size() == civ.human_pop.size():
		civ.human_pop = pop
	var bytes_meta: PackedByteArray = _buf.read_buffer("soc_civ_meta")
	var meta: PackedFloat32Array = bytes_meta.to_float32_array()
	if meta.size() >= 2:
		civ.humans_emerged = meta[0] >= 0.5
		civ.tech_level = clamp(float(meta[1]), 0.0, 1.0)
		civ.global_devastation = clamp(float(meta[3]), 0.0, 1.0) if meta.size() >= 4 else 0.0
