extends SceneTree
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

# Headless regression harness for regional seam behavior.
# This does not "prove" seams are good; it catches unintended changes by hashing
# deterministic sample strips across world-tile boundaries.
#
# Usage (Godot):
#   godot -s res://tools_regional_seam_regression.gd
#   godot -s res://tools_regional_seam_regression.gd -- --update
# Note: this harness runs GPU-only worldgen. On some systems, `--headless` disables RD.

const WORLD_W: int = 275
const WORLD_H: int = 62
const REGION_SIZE: int = 96
const CASE_SEEDS: Array = [1300716004, 7423911]

const BASELINE_PATH: String = "res://docs/perf/regional_seam_baseline.json"
const BASELINE_SCHEMA: String = "u32hex_v1"

func _cleanup_worldgen(gen: Object) -> void:
	if gen == null:
		return
	if gen.has_method("cleanup"):
		gen.call("cleanup")
	elif gen.has_method("clear"):
		gen.call("clear")

func _rolling_hash_u32(h: int, v: int) -> int:
	# Simple integer hash combiner (deterministic across runs).
	var x: int = int(v) & 0xFFFFFFFF
	x = int(x ^ (x >> 16)) & 0xFFFFFFFF
	x = int(x * 0x7FEB352D) & 0xFFFFFFFF
	x = int(x ^ (x >> 15)) & 0xFFFFFFFF
	x = int(x * 0x846CA68B) & 0xFFFFFFFF
	x = int(x ^ (x >> 16)) & 0xFFFFFFFF
	var out: int = int(h) & 0xFFFFFFFF
	out = int(out ^ x) & 0xFFFFFFFF
	out = int(out * 0x01000193) & 0xFFFFFFFF # FNV-ish prime
	return out

func _hash_hex(v: int) -> String:
	var u32: int = int(v) & 0xFFFFFFFF
	return "0x%08x" % u32

func _coerce_expected_hash_hex(v: Variant) -> String:
	if typeof(v) == TYPE_STRING:
		var s: String = String(v).strip_edges().to_lower()
		if s.begins_with("0x") and s.length() == 10:
			return s
		if s.length() == 8:
			return "0x" + s
		return ""
	if typeof(v) == TYPE_INT:
		var i: int = int(v)
		if i < 0 or i > 0xFFFFFFFF:
			return "" # Legacy oversized int baseline; requires --update.
		return _hash_hex(i)
	if typeof(v) == TYPE_FLOAT:
		var f: float = float(v)
		if f < 0.0 or f > float(0xFFFFFFFF):
			return ""
		return _hash_hex(int(round(f)))
	return ""

func _compute_case_hash(seed_value: int) -> Dictionary:
	var WG = load("res://scripts/WorldGenerator.gd")
	var RegionalChunkGenerator = load("res://scripts/gameplay/RegionalChunkGenerator.gd")
	var gen = WG.new()
	gen.apply_config({
		"seed": str(seed_value),
		"width": WORLD_W,
		"height": WORLD_H,
	})
	var land_mask: PackedByteArray = gen.generate()
	if land_mask.is_empty():
		_cleanup_worldgen(gen)
		return {"ok": false, "seed": seed_value, "error": "worldgen_failed"}
	var world_biomes: PackedInt32Array = gen.last_biomes
	if world_biomes.size() != WORLD_W * WORLD_H:
		_cleanup_worldgen(gen)
		return {"ok": false, "seed": seed_value, "error": "biomes_missing"}

	var rcg = RegionalChunkGenerator.new()
	rcg.configure(int(seed_value), WORLD_W, WORLD_H, world_biomes, REGION_SIZE)

	# Sample strips across a few vertical world-tile boundaries at a few Y tiles.
	# For each boundary bx, sample columns x=(bx*REGION_SIZE - 1) and x=(bx*REGION_SIZE).
	var cases: Array = [
		{"bx": 1, "ty": 0},
		{"bx": 2, "ty": 3},
		{"bx": 5, "ty": 10},
		{"bx": 12, "ty": 20},
	]

	var h_total: int = 2166136261
	for c in cases:
		var bx: int = int(c.get("bx", 1))
		var ty: int = int(c.get("ty", 0))
		var x0: int = bx * REGION_SIZE - 1
		var x1: int = bx * REGION_SIZE
		var y0: int = ty * REGION_SIZE
		var y1: int = y0 + REGION_SIZE - 1
		for gy in range(y0, y1 + 1):
			var a: Dictionary = rcg.sample_cell(x0, gy)
			var b: Dictionary = rcg.sample_cell(x1, gy)
			var ha: int = int(round(float(a.get("height_raw", 0.0)) * 10000.0))
			var hb: int = int(round(float(b.get("height_raw", 0.0)) * 10000.0))
			var ba: int = int(a.get("biome", 0))
			var bb: int = int(b.get("biome", 0))
			h_total = _rolling_hash_u32(h_total, ha)
			h_total = _rolling_hash_u32(h_total, ba)
			h_total = _rolling_hash_u32(h_total, hb)
			h_total = _rolling_hash_u32(h_total, bb)
	_cleanup_worldgen(gen)
	return {
		"ok": true,
		"seed": seed_value,
		"hash_u32": int(h_total) & 0xFFFFFFFF,
		"hash_hex": _hash_hex(h_total),
	}

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	return parsed

func _write_json(path: String, v: Variant) -> bool:
	var txt: String = JSON.stringify(v, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(txt)
	f.close()
	return true

func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	var update: bool = false
	for a in args:
		if String(a) == "--update":
			update = true

	var baseline: Variant = _read_json(BASELINE_PATH)
	if baseline == null:
		baseline = {}
	var baseline_dict: Dictionary = baseline if typeof(baseline) == TYPE_DICTIONARY else {}

	var out_baseline: Dictionary = {"_schema": BASELINE_SCHEMA}
	var failures: PackedStringArray = PackedStringArray()

	for seed_value in CASE_SEEDS:
		var r: Dictionary = _compute_case_hash(int(seed_value))
		if not VariantCasts.to_bool(r.get("ok", false)):
			failures.append("seed %d: %s" % [int(seed_value), String(r.get("error", "unknown"))])
			continue
		var key: String = "seed:%d" % int(seed_value)
		var got_hex: String = String(r.get("hash_hex", ""))
		out_baseline[key] = got_hex
		print("[REG-SEAM] " + key + " hash_u32=" + got_hex)
		if not update and baseline_dict.has(key):
			var expected_hex: String = _coerce_expected_hash_hex(baseline_dict.get(key, ""))
			if expected_hex.is_empty():
				failures.append("%s invalid legacy baseline value; run with --update" % key)
			elif expected_hex != got_hex:
				failures.append("%s mismatch: expected %s got %s" % [key, expected_hex, got_hex])

	if update:
		if _write_json(BASELINE_PATH, out_baseline):
			print("[REG-SEAM] baseline updated: " + BASELINE_PATH)
			quit(0)
			return
		push_error("[REG-SEAM] failed to write baseline: " + BASELINE_PATH)
		quit(1)
		return

	if baseline_dict.is_empty():
		push_error("[REG-SEAM] missing baseline: run with --update to write " + BASELINE_PATH)
		quit(1)
		return

	if failures.is_empty():
		print("[REG-SEAM] PASS (%d seeds)" % CASE_SEEDS.size())
		quit(0)
		return
	for f in failures:
		push_error("[REG-SEAM] " + f)
	quit(1)
