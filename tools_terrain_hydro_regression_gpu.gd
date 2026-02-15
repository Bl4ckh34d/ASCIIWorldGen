extends SceneTree
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

class DummyWorld:
	extends RefCounted
	var simulation_time_days: float = 0.0
	var time_scale: float = 1.0

const WORLD_WIDTH: int = 275
const WORLD_HEIGHT: int = 62
const DT_DAYS: float = 14.0
const STEPS: int = 18
const CASE_SEEDS: Array = [1300716004, 7423911, 18924427]

const MAX_SLOPE_OUTLIER_RATIO: float = 0.42
const MAX_INLAND_RATIO: float = 0.32
const MAX_OCEAN_DRIFT: float = 0.20
const MAX_NET_HEIGHT_BIAS: float = 0.16

func _cleanup_if_supported(obj: Variant) -> void:
	if obj == null:
		return
	if obj is Object:
		var ref_obj: Object = obj as Object
		if ref_obj.has_method("cleanup"):
			ref_obj.call("cleanup")
		elif ref_obj.has_method("clear"):
			ref_obj.call("clear")

func _run_case(seed_value: int) -> Dictionary:
	var WG = load("res://scripts/WorldGenerator.gd")
	var PlateSystem = load("res://scripts/systems/PlateSystem.gd")
	var HydroUpdateSystem = load("res://scripts/systems/HydroUpdateSystem.gd")
	var gen = WG.new()
	gen.apply_config({
		"seed": str(seed_value),
		"width": WORLD_WIDTH,
		"height": WORLD_HEIGHT,
		"fixed_water_budget_enabled": true,
		"fixed_ocean_fraction_target": 0.56,
		"ocean_connectivity_gate_enabled": true,
	})
	var generated_land: PackedByteArray = gen.generate()
	if generated_land.is_empty():
		_cleanup_if_supported(gen)
		return {"ok": false, "seed": seed_value, "error": "generation_failed"}
	var plate = PlateSystem.new()
	plate.initialize(gen)
	var hydro = HydroUpdateSystem.new()
	hydro.initialize(gen)
	var world := DummyWorld.new()
	for _step in range(STEPS):
		world.simulation_time_days += DT_DAYS
		plate.tick(DT_DAYS, world, {})
		hydro.tick(DT_DAYS, world, {})
	var metrics: Dictionary = gen.sample_terrain_hydro_metrics()
	var water_stats: Dictionary = gen.water_budget_stats.duplicate()
	var tectonics: Dictionary = gen.tectonic_stats.duplicate()
	var out := {
		"ok": true,
		"seed": seed_value,
		"metrics": metrics,
		"water": water_stats,
		"tectonics": tectonics,
	}
	_cleanup_if_supported(plate)
	_cleanup_if_supported(hydro)
	_cleanup_if_supported(gen)
	return out

func _init() -> void:
	var failures: PackedStringArray = PackedStringArray()
	for seed_value in CASE_SEEDS:
		var result: Dictionary = _run_case(seed_value)
		if not VariantCasts.to_bool(result.get("ok", false)):
			failures.append("seed %d: %s" % [int(result.get("seed", seed_value)), String(result.get("error", "unknown_error"))])
			continue
		var metrics: Dictionary = result.get("metrics", {})
		var water: Dictionary = result.get("water", {})
		var tectonics: Dictionary = result.get("tectonics", {})
		if not VariantCasts.to_bool(metrics.get("ok", false)):
			failures.append("seed %d: gpu_metrics_unavailable" % int(result.get("seed", seed_value)))
			continue
		var total_cells: float = max(1.0, float(metrics.get("total_cells", 0.0)))
		var slope_ratio: float = float(metrics.get("slope_outlier_cells", 0.0)) / total_cells
		var inland_ratio: float = float(metrics.get("inland_ocean_cells", 0.0)) / total_cells
		var ocean_now: float = float(water.get("current_ocean_fraction", metrics.get("ocean_fraction", 0.0)))
		var ocean_target: float = float(water.get("target_ocean_fraction", ocean_now))
		var ocean_drift: float = abs(ocean_now - ocean_target)
		var net_bias: float = abs(float(tectonics.get("net_height_bias", 0.0)))
		var sample_count: int = int(tectonics.get("height_bias_samples", 0))
		var seed_label: int = int(result.get("seed", seed_value))
		print(
			"[TH-REG] seed=%d slope_ratio=%.4f inland_ratio=%.4f ocean_drift=%.4f net_bias=%.6f samples=%d"
			% [seed_label, slope_ratio, inland_ratio, ocean_drift, net_bias, sample_count]
		)
		if slope_ratio > MAX_SLOPE_OUTLIER_RATIO:
			failures.append("seed %d: slope_ratio %.4f > %.4f" % [seed_label, slope_ratio, MAX_SLOPE_OUTLIER_RATIO])
		if inland_ratio > MAX_INLAND_RATIO:
			failures.append("seed %d: inland_ratio %.4f > %.4f" % [seed_label, inland_ratio, MAX_INLAND_RATIO])
		if ocean_drift > MAX_OCEAN_DRIFT:
			failures.append("seed %d: ocean_drift %.4f > %.4f" % [seed_label, ocean_drift, MAX_OCEAN_DRIFT])
		if net_bias > MAX_NET_HEIGHT_BIAS:
			failures.append("seed %d: net_height_bias %.6f > %.6f" % [seed_label, net_bias, MAX_NET_HEIGHT_BIAS])
		if sample_count <= 0:
			failures.append("seed %d: no_tectonic_bias_samples" % seed_label)
	if failures.is_empty():
		print("[TH-REG] PASS (%d seeds)" % CASE_SEEDS.size())
		quit(0)
		return
	for f in failures:
		push_error("[TH-REG] " + f)
	quit(1)
