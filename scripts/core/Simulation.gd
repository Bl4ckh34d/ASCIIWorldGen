# File: res://scripts/core/Simulation.gd
extends Node

class_name Simulation

var systems: Array = [] # Array of dictionaries {instance, cadence, tiles_per_tick, avg_cost_ms, use_time_debt, debt_days, force_next_run, max_catchup_days}
var tick_counter: int = 0
var max_systems_per_tick: int = 3
var max_tick_time_ms: float = 6.0
var budget_mode_time_ms: bool = true # if true, enforce time-based budget, else count-based
var _last_tick_start_us: int = 0
var last_dirty_fields: PackedStringArray = PackedStringArray()
var _total_tick_time_ms: float = 0.0
var _skipped_systems_count: int = 0
var _stats_window_size: int = 100
var _tick_time_history: Array = []

const _SMOOTH_ALPHA := 0.3

func register_system(instance: Object, cadence: int = 1, tiles_per_tick: int = 0, use_time_debt: bool = true, max_catchup_days: float = 30.0) -> void:
	systems.append({
		"instance": instance,
		"cadence": max(1, cadence),
		"last_tick": -1,
		"tiles_per_tick": max(0, tiles_per_tick),
		"avg_cost_ms": 0.0,
		"use_time_debt": bool(use_time_debt),
		"debt_days": 0.0,
		"force_next_run": false,
		"max_catchup_days": max(1e-6, float(max_catchup_days)),
	})

func clear() -> void:
	systems.clear()
	tick_counter = 0

func accumulate_debt(dt_days: float) -> void:
	var dt: float = max(0.0, float(dt_days))
	if dt <= 0.0:
		return
	for s in systems:
		if bool(s.get("use_time_debt", true)):
			s["debt_days"] = float(s.get("debt_days", 0.0)) + dt

func set_system_use_time_debt(instance: Object, enabled: bool) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["use_time_debt"] = bool(enabled)
			s["debt_days"] = 0.0
			break

func set_system_catchup_max_days(instance: Object, max_days: float) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["max_catchup_days"] = max(1e-6, float(max_days))
			break

func request_catchup(instance: Object = null) -> void:
	for s in systems:
		if instance == null or s.get("instance", null) == instance:
			s["force_next_run"] = true

func request_catchup_all() -> void:
	request_catchup(null)

func on_tick(dt_days: float, world: Object, gpu_ctx: Dictionary) -> void:
	tick_counter += 1
	accumulate_debt(dt_days)
	var executed: int = 0
	var start_us: int = Time.get_ticks_usec()
	_last_tick_start_us = start_us
	var dirty_set := {}
	for s in systems:
		var cadence: int = int(s["cadence"])
		var use_time_debt: bool = bool(s.get("use_time_debt", true))
		var force_due: bool = bool(s.get("force_next_run", false))
		var cadence_due: bool = (tick_counter % cadence == 0)
		if not cadence_due and not force_due:
			continue
		var dt_for_system: float = max(0.0, float(dt_days))
		if use_time_debt:
			var debt_days: float = max(0.0, float(s.get("debt_days", 0.0)))
			var catchup_max: float = max(1e-6, float(s.get("max_catchup_days", 30.0)))
			dt_for_system = min(debt_days, catchup_max)
			if dt_for_system <= 0.0:
				s["force_next_run"] = false
				continue
		# Budget check (time or count)
		if budget_mode_time_ms:
			var now_us: int = Time.get_ticks_usec()
			var elapsed_ms: float = float(now_us - start_us) / 1000.0
			var predicted_ms: float = float(s.get("avg_cost_ms", 0.0))
			if elapsed_ms + predicted_ms > max(0.0, max_tick_time_ms):
				# Try to fit other systems this tick; skip this one
				_skipped_systems_count += 1
				continue
		else:
			if executed >= max(1, max_systems_per_tick):
				break
		if "tick" in s["instance"]:
			var st_us: int = Time.get_ticks_usec()
			var ret: Variant = s["instance"].tick(dt_for_system, world, gpu_ctx)
			var en_us: int = Time.get_ticks_usec()
			var cost_ms: float = float(en_us - st_us) / 1000.0
			# Update EMA cost
			var prev: float = float(s.get("avg_cost_ms", 0.0))
			s["avg_cost_ms"] = (1.0 - _SMOOTH_ALPHA) * prev + _SMOOTH_ALPHA * cost_ms
			var consumed_dt: bool = true
			if typeof(ret) == TYPE_DICTIONARY and ret.has("consumed_dt"):
				consumed_dt = bool(ret["consumed_dt"])
			if use_time_debt:
				var remaining: float = max(0.0, float(s.get("debt_days", 0.0)))
				if consumed_dt:
					remaining = max(0.0, remaining - dt_for_system)
				s["debt_days"] = remaining
				s["force_next_run"] = remaining > 1e-6
			else:
				s["force_next_run"] = false
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
	
	# Track total tick time
	var end_us: int = Time.get_ticks_usec()
	_total_tick_time_ms = float(end_us - start_us) / 1000.0
	
	# Maintain rolling window of tick times for statistics
	_tick_time_history.append(_total_tick_time_ms)
	if _tick_time_history.size() > _stats_window_size:
		_tick_time_history.pop_front()

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

func get_performance_stats() -> Dictionary:
	"""Get current performance statistics for monitoring and tuning"""
	var stats = {
		"current_tick_time_ms": _total_tick_time_ms,
		"max_budget_ms": max_tick_time_ms,
		"skipped_systems_count": _skipped_systems_count,
		"systems_count": systems.size(),
		"tick_counter": tick_counter,
		"budget_mode_time": budget_mode_time_ms
	}
	
	# Calculate rolling window statistics
	if _tick_time_history.size() > 0:
		var total = 0.0
		var min_time = _tick_time_history[0]
		var max_time = _tick_time_history[0]
		
		for time in _tick_time_history:
			total += time
			min_time = min(min_time, time)
			max_time = max(max_time, time)
		
		stats["avg_tick_time_ms"] = total / float(_tick_time_history.size())
		stats["min_tick_time_ms"] = min_time
		stats["max_tick_time_ms"] = max_time
		stats["window_size"] = _tick_time_history.size()
		
		# Performance health indicator
		var avg_time = stats["avg_tick_time_ms"]
		if avg_time > max_tick_time_ms * 0.9:
			stats["performance_status"] = "critical"
		elif avg_time > max_tick_time_ms * 0.7:
			stats["performance_status"] = "warning"
		else:
			stats["performance_status"] = "healthy"
	else:
		stats["avg_tick_time_ms"] = 0.0
		stats["performance_status"] = "no_data"
	
	# Per-system timing breakdown
	var system_stats = []
	for s in systems:
		system_stats.append({
			"name": str(s.get("instance", "unknown")),
			"avg_cost_ms": s.get("avg_cost_ms", 0.0),
			"cadence": s.get("cadence", 1)
		})
	stats["system_breakdown"] = system_stats
	
	return stats

func auto_tune_budget() -> void:
	"""Automatically adjust budget based on recent performance"""
	if _tick_time_history.size() < 10:
		return  # Need sufficient data
	
	var recent_avg = 0.0
	var recent_count = min(20, _tick_time_history.size())
	for i in range(_tick_time_history.size() - recent_count, _tick_time_history.size()):
		recent_avg += _tick_time_history[i]
	recent_avg /= float(recent_count)
	
	# If consistently under budget, try to increase performance
	if recent_avg < max_tick_time_ms * 0.5:
		max_tick_time_ms = max(3.0, max_tick_time_ms * 0.9)
	# If over budget, be more conservative
	elif recent_avg > max_tick_time_ms * 0.85:
		max_tick_time_ms = min(16.0, max_tick_time_ms * 1.1)

func reset_stats() -> void:
	"""Reset performance statistics"""
	_tick_time_history.clear()
	_skipped_systems_count = 0
	for s in systems:
		s["avg_cost_ms"] = 0.0
