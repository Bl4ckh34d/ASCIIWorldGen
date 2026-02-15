extends RefCounted
class_name WildlifeStateModel

# Wildlife density is a coarse per-world-tile field (0..1) used to drive:
# - hunter-gatherer survival/migration
# - encounter pressure (later)
#
# GPU-first: authoritative state lives in GPU buffers during runtime; we snapshot
# only on explicit transitions (save/load).

const CURRENT_VERSION: int = 1

var version: int = CURRENT_VERSION

# PackedFloat32Array of length world_w * world_h, values in [0..1].
var density: PackedFloat32Array = PackedFloat32Array()

var world_w: int = 0
var world_h: int = 0

var last_tick_abs_day: int = -1

func reset_defaults() -> void:
	version = CURRENT_VERSION
	density = PackedFloat32Array()
	world_w = 0
	world_h = 0
	last_tick_abs_day = -1

func ensure_size(w: int, h: int, fill_value: float = 0.65) -> void:
	w = max(0, int(w))
	h = max(0, int(h))
	world_w = w
	world_h = h
	var size: int = w * h
	if size <= 0:
		density = PackedFloat32Array()
		return
	if density.size() == size:
		return
	density = PackedFloat32Array()
	density.resize(size)
	density.fill(clamp(float(fill_value), 0.0, 1.0))

func to_dict() -> Dictionary:
	var arr: Array = []
	arr.resize(density.size())
	for i in range(density.size()):
		arr[i] = float(density[i])
	return {
		"version": version,
		"world_w": world_w,
		"world_h": world_h,
		"density": arr,
		"last_tick_abs_day": last_tick_abs_day,
	}

static func from_dict(data: Dictionary) -> WildlifeStateModel:
	var out := WildlifeStateModel.new()
	out.version = max(1, int(data.get("version", CURRENT_VERSION)))
	out.world_w = max(0, int(data.get("world_w", 0)))
	out.world_h = max(0, int(data.get("world_h", 0)))
	out.last_tick_abs_day = int(data.get("last_tick_abs_day", -1))
	var incoming: Variant = data.get("density", [])
	if typeof(incoming) == TYPE_ARRAY:
		var a: Array = incoming
		out.density = PackedFloat32Array()
		out.density.resize(a.size())
		for i in range(a.size()):
			out.density[i] = clamp(float(a[i]), 0.0, 1.0)
	return out

