# File: res://scripts/core/Simulation.gd
extends Node

class_name Simulation

var systems: Array = [] # Array of dictionaries {instance, cadence, last_tick: int, tiles_per_tick: int}
var tick_counter: int = 0
var max_systems_per_tick: int = 3
var max_tick_time_ms: float = 6.0
var budget_mode_time_ms: bool = true # if true, enforce time-based budget, else count-based
var _last_tick_start_us: int = 0
var last_dirty_fields: PackedStringArray = PackedStringArray()

const _SMOOTH_ALPHA := 0.3

func register_system(instance: Object, cadence: int = 1, tiles_per_tick: int = 0) -> void:
	systems.append({
		"instance": instance,
		"cadence": max(1, cadence),
		"last_tick": -1,
		"tiles_per_tick": max(0, tiles_per_tick),
		"avg_cost_ms": 0.0,
	})

func clear() -> void:
	systems.clear()
	tick_counter = 0

func on_tick(dt_days: float, world: Object, gpu_ctx: Dictionary) -> void:
	tick_counter += 1
	var executed: int = 0
	var start_us: int = Time.get_ticks_usec()
	_last_tick_start_us = start_us
	var dirty_set := {}
	for s in systems:
		# Budget check (time or count)
		if budget_mode_time_ms:
			var now_us: int = Time.get_ticks_usec()
			var elapsed_ms: float = float(now_us - start_us) / 1000.0
			var predicted_ms: float = float(s.get("avg_cost_ms", 0.0))
			if elapsed_ms + predicted_ms > max(0.0, max_tick_time_ms):
				# Try to fit other systems this tick; skip this one
				continue
		else:
			if executed >= max(1, max_systems_per_tick):
				break
		# cadence filter
		var cadence: int = int(s["cadence"])
		if tick_counter % cadence != 0:
			continue
		if "tick" in s["instance"]:
			var st_us: int = Time.get_ticks_usec()
			var ret: Variant = s["instance"].tick(dt_days, world, gpu_ctx)
			var en_us: int = Time.get_ticks_usec()
			var cost_ms: float = float(en_us - st_us) / 1000.0
			# Update EMA cost
			var prev: float = float(s.get("avg_cost_ms", 0.0))
			s["avg_cost_ms"] = (1.0 - _SMOOTH_ALPHA) * prev + _SMOOTH_ALPHA * cost_ms
			# Collect dirty fields if system reported any
			if typeof(ret) == TYPE_DICTIONARY and ret.has("dirty_fields"):
				var df: PackedStringArray = ret["dirty_fields"]
				for f in df:
					dirty_set[f] = true
			executed += 1
	# Broadcast aggregated dirty fields to systems that opt-in via on_dirty
	var agg := PackedStringArray()
	for k in dirty_set.keys():
		agg.append(String(k))
	last_dirty_fields = agg
	if agg.size() > 0:
		for s2 in systems:
			if "on_dirty" in s2["instance"]:
				# Let systems react to dirty fields cheaply (they may no-op)
				s2["instance"].on_dirty(agg, world, gpu_ctx)

func update_cadence(instance: Object, cadence: int) -> void:
	var new_c: int = max(1, int(cadence))
	for s in systems:
		if s.get("instance", null) == instance:
			s["cadence"] = new_c
			break

func set_max_systems_per_tick(n: int) -> void:
	max_systems_per_tick = max(1, int(n))

func set_max_tick_time_ms(ms: float) -> void:
	max_tick_time_ms = max(0.0, float(ms))

func set_budget_mode_time(on: bool) -> void:
	budget_mode_time_ms = bool(on)
