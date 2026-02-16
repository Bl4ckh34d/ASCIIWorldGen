extends RefCounted
class_name CivilizationStateModel

# Civilization state is the "civilization layer" (humans and later other species).
# v0 scaffolding: per-world-tile human population + a tiny meta vector.
#
# GPU-first: authoritative state lives in GPU buffers during runtime; we snapshot
# only on explicit transitions (save/load).

const CURRENT_VERSION: int = 2

var version: int = CURRENT_VERSION

var world_w: int = 0
var world_h: int = 0

# PackedFloat32Array of length world_w * world_h. Units are arbitrary population points.
var human_pop: PackedFloat32Array = PackedFloat32Array()

# Whether humans have "emerged" yet in the simulation timeline.
var humans_emerged: bool = false

# Deterministic emergence control (absolute day index).
var emergence_abs_day: int = -1

# Deterministic starting tile for the first band.
var start_world_x: int = -1
var start_world_y: int = -1

# Coarse global tech level proxy (0..1 for now; later becomes multi-dimensional).
var tech_level: float = 0.0

# Global devastation proxy (0..1) driven by war pressure hooks.
# v0 scaffold: symbolic only, but persisted and fed into the GPU civ tick.
var global_devastation: float = 0.0

# Coarse epoch scaffold derived from tech/devastation.
var epoch_id: String = "prehistoric"
var epoch_index: int = 0
var epoch_progress: float = 0.0
var epoch_variant: String = "stable"
var last_epoch_change_abs_day: int = -1
var epoch_target_id: String = ""
var epoch_target_variant: String = ""
var epoch_shift_due_abs_day: int = -1
var epoch_shift_serial: int = 0

var last_tick_abs_day: int = -1

func reset_defaults() -> void:
	version = CURRENT_VERSION
	world_w = 0
	world_h = 0
	human_pop = PackedFloat32Array()
	humans_emerged = false
	emergence_abs_day = -1
	start_world_x = -1
	start_world_y = -1
	tech_level = 0.0
	global_devastation = 0.0
	epoch_id = "prehistoric"
	epoch_index = 0
	epoch_progress = 0.0
	epoch_variant = "stable"
	last_epoch_change_abs_day = -1
	epoch_target_id = ""
	epoch_target_variant = ""
	epoch_shift_due_abs_day = -1
	epoch_shift_serial = 0
	last_tick_abs_day = -1

func ensure_size(w: int, h: int) -> void:
	w = max(0, int(w))
	h = max(0, int(h))
	world_w = w
	world_h = h
	var size: int = w * h
	if size <= 0:
		human_pop = PackedFloat32Array()
		return
	if human_pop.size() == size:
		return
	human_pop = PackedFloat32Array()
	human_pop.resize(size)
	human_pop.fill(0.0)

func to_dict() -> Dictionary:
	var arr: Array = []
	arr.resize(human_pop.size())
	for i in range(human_pop.size()):
		arr[i] = float(human_pop[i])
	return {
		"version": version,
		"world_w": world_w,
		"world_h": world_h,
		"human_pop": arr,
		"humans_emerged": humans_emerged,
		"emergence_abs_day": emergence_abs_day,
		"start_world_x": start_world_x,
		"start_world_y": start_world_y,
		"tech_level": tech_level,
		"global_devastation": global_devastation,
		"epoch_id": epoch_id,
		"epoch_index": epoch_index,
		"epoch_progress": epoch_progress,
		"epoch_variant": epoch_variant,
		"last_epoch_change_abs_day": last_epoch_change_abs_day,
		"epoch_target_id": epoch_target_id,
		"epoch_target_variant": epoch_target_variant,
		"epoch_shift_due_abs_day": epoch_shift_due_abs_day,
		"epoch_shift_serial": epoch_shift_serial,
		"last_tick_abs_day": last_tick_abs_day,
	}

static func from_dict(data: Dictionary) -> CivilizationStateModel:
	var out := CivilizationStateModel.new()
	out.version = max(1, int(data.get("version", CURRENT_VERSION)))
	out.world_w = max(0, int(data.get("world_w", 0)))
	out.world_h = max(0, int(data.get("world_h", 0)))
	out.humans_emerged = VariantCasts.to_bool(data.get("humans_emerged", false))
	out.emergence_abs_day = int(data.get("emergence_abs_day", -1))
	out.start_world_x = int(data.get("start_world_x", -1))
	out.start_world_y = int(data.get("start_world_y", -1))
	out.tech_level = clamp(float(data.get("tech_level", 0.0)), 0.0, 1.0)
	out.global_devastation = clamp(float(data.get("global_devastation", 0.0)), 0.0, 1.0)
	out.epoch_id = String(data.get("epoch_id", _legacy_epoch_id_for_tech(out.tech_level)))
	out.epoch_index = max(0, int(data.get("epoch_index", _legacy_epoch_index_for_id(out.epoch_id))))
	out.epoch_progress = clamp(float(data.get("epoch_progress", 0.0)), 0.0, 1.0)
	out.epoch_variant = String(data.get("epoch_variant", "stable"))
	out.last_epoch_change_abs_day = int(data.get("last_epoch_change_abs_day", -1))
	out.epoch_target_id = String(data.get("epoch_target_id", ""))
	out.epoch_target_variant = String(data.get("epoch_target_variant", ""))
	out.epoch_shift_due_abs_day = int(data.get("epoch_shift_due_abs_day", -1))
	out.epoch_shift_serial = max(0, int(data.get("epoch_shift_serial", 0)))
	out.last_tick_abs_day = int(data.get("last_tick_abs_day", -1))
	var incoming: Variant = data.get("human_pop", [])
	if typeof(incoming) == TYPE_ARRAY:
		var a: Array = incoming
		out.human_pop = PackedFloat32Array()
		out.human_pop.resize(a.size())
		for i in range(a.size()):
			out.human_pop[i] = max(0.0, float(a[i]))
	return out

static func _legacy_epoch_id_for_tech(tech_level_value: float) -> String:
	tech_level_value = clamp(float(tech_level_value), 0.0, 1.0)
	if tech_level_value >= 0.95:
		return "singularity"
	if tech_level_value >= 0.82:
		return "space_age"
	if tech_level_value >= 0.65:
		return "modern"
	if tech_level_value >= 0.45:
		return "industrial"
	if tech_level_value >= 0.25:
		return "medieval"
	if tech_level_value >= 0.10:
		return "ancient"
	return "prehistoric"

static func _legacy_epoch_index_for_id(epoch_id_value: String) -> int:
	match String(epoch_id_value):
		"prehistoric":
			return 0
		"ancient":
			return 1
		"medieval":
			return 2
		"industrial":
			return 3
		"modern":
			return 4
		"space_age":
			return 5
		"singularity":
			return 6
		_:
			return 0
