# File: res://scripts/core/Simulation.gd
extends Node

class_name Simulation
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

var systems: Array = [] # Array of dictionaries {instance, cadence, tiles_per_tick, avg_cost_ms, use_time_debt, debt_days, force_next_run, max_catchup_days, max_runs_per_tick}
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
var max_runs_per_system_tick: int = 8
var _round_robin_start: int = 0
var max_emergency_runs_per_tick: int = 1

const _SMOOTH_ALPHA := 0.3
const _EPSILON_DAYS := 1e-6

func register_system(
		instance: Object,
		cadence: int = 1,
		tiles_per_tick: int = 0,
		use_time_debt: bool = true,
		max_catchup_days: float = 30.0,
		max_runs_per_tick: int = 8,
		priority: int = 0,
		emergency_override: bool = false,
		ema_alpha: float = _SMOOTH_ALPHA,
		prediction_floor_ms: float = 0.05
	) -> void:
	systems.append({
		"instance": instance,
		"cadence": max(1, cadence),
		"last_tick": -1,
		"tiles_per_tick": max(0, tiles_per_tick),
		"avg_cost_ms": 0.0,
		"use_time_debt": VariantCasts.to_bool(use_time_debt),
		"debt_days": 0.0,
		"force_next_run": false,
		"max_catchup_days": max(1e-6, float(max_catchup_days)),
		"max_runs_per_tick": max(1, int(max_runs_per_tick)),
		"priority": int(priority),
		"emergency_override": VariantCasts.to_bool(emergency_override),
		"ema_alpha": clamp(float(ema_alpha), 0.05, 0.95),
		"prediction_floor_ms": max(0.0, float(prediction_floor_ms)),
	})

func clear() -> void:
	systems.clear()
	tick_counter = 0
	_round_robin_start = 0

func accumulate_debt(dt_days: float) -> void:
	var dt: float = max(0.0, float(dt_days))
	if dt <= 0.0:
		return
	for s in systems:
		if VariantCasts.to_bool(s.get("use_time_debt", true)):
			s["debt_days"] = float(s.get("debt_days", 0.0)) + dt

func set_system_use_time_debt(instance: Object, enabled: bool) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["use_time_debt"] = VariantCasts.to_bool(enabled)
			s["debt_days"] = 0.0
			break

func set_system_catchup_max_days(instance: Object, max_days: float) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["max_catchup_days"] = max(1e-6, float(max_days))
			break

func set_system_max_runs_per_tick(instance: Object, max_runs: int) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["max_runs_per_tick"] = max(1, int(max_runs))
			break

func set_system_priority(instance: Object, priority: int) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["priority"] = int(priority)
			break

func set_system_emergency_override(instance: Object, enabled: bool) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["emergency_override"] = VariantCasts.to_bool(enabled)
			break

func set_system_ema_alpha(instance: Object, alpha: float) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["ema_alpha"] = clamp(float(alpha), 0.05, 0.95)
			break

func set_system_prediction_floor_ms(instance: Object, floor_ms: float) -> void:
	for s in systems:
		if s.get("instance", null) == instance:
			s["prediction_floor_ms"] = max(0.0, float(floor_ms))
			break

func set_max_emergency_runs_per_tick(n: int) -> void:
	max_emergency_runs_per_tick = clamp(int(n), 0, 8)

func _extract_consumed_days(ret: Variant, dt_for_system: float, use_time_debt: bool) -> float:
	var consumed_days: float = dt_for_system if not use_time_debt else 0.0
	if typeof(ret) == TYPE_DICTIONARY:
		if ret.has("consumed_days"):
			consumed_days = clamp(float(ret["consumed_days"]), 0.0, dt_for_system)
		elif ret.has("consumed_dt"):
			consumed_days = dt_for_system if VariantCasts.to_bool(ret["consumed_dt"]) else 0.0
		elif use_time_debt and (ret as Dictionary).is_empty():
			# Empty result means no progress (common early-return failure path).
			consumed_days = 0.0
		else:
			# Non-empty dictionary is treated as successful progress unless overridden.
			consumed_days = dt_for_system
	elif not use_time_debt:
		consumed_days = dt_for_system
	return max(0.0, min(consumed_days, dt_for_system))

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
	var total_systems: int = systems.size()
	if total_systems <= 0:
		return
	var due_indices: Array = []
	for offset in range(total_systems):
		var idx0: int = (_round_robin_start + offset) % total_systems
		var s0 = systems[idx0]
		var cadence0: int = int(s0["cadence"])
		var force_due0: bool = VariantCasts.to_bool(s0.get("force_next_run", false))
		var cadence_due0: bool = (tick_counter % cadence0 == 0)
		if cadence_due0 or force_due0:
			due_indices.append(idx0)
	# Stable insertion sort by priority (higher first).
	for i in range(1, due_indices.size()):
		var key_idx: int = int(due_indices[i])
		var key_pri: int = int((systems[key_idx] as Dictionary).get("priority", 0))
		var j: int = i - 1
		while j >= 0:
			var j_idx: int = int(due_indices[j])
			var j_pri: int = int((systems[j_idx] as Dictionary).get("priority", 0))
			if j_pri >= key_pri:
				break
			due_indices[j + 1] = due_indices[j]
			j -= 1
		due_indices[j + 1] = key_idx
	var budget_exhausted: bool = false
	var emergency_runs: int = 0
	for idx_v in due_indices:
		if budget_exhausted:
			break
		var idx: int = int(idx_v)
		var s = systems[idx]
		var use_time_debt: bool = VariantCasts.to_bool(s.get("use_time_debt", true))
		var runs: int = 0
		var consumed_this_tick: float = 0.0
		var base_runs_cap: int = max(1, int(s.get("max_runs_per_tick", max_runs_per_system_tick)))
		var catchup_max: float = max(1e-6, float(s.get("max_catchup_days", 30.0)))
		var dt_incoming: float = max(0.0, float(dt_days))
		var min_runs_to_keep_up: int = 1
		if use_time_debt:
			min_runs_to_keep_up = int(ceil(dt_incoming / catchup_max))
		var runs_cap: int = clamp(max(base_runs_cap, min_runs_to_keep_up), 1, 128)
		while true:
			if budget_exhausted:
				break
			var dt_for_system: float = max(0.0, float(dt_days))
			if use_time_debt:
				var debt_days: float = max(0.0, float(s.get("debt_days", 0.0)))
				dt_for_system = min(debt_days, catchup_max)
				if dt_for_system <= _EPSILON_DAYS:
					s["force_next_run"] = false
					break
			# Budget check (time or count)
			if budget_mode_time_ms:
				var now_us: int = Time.get_ticks_usec()
				var elapsed_ms: float = float(now_us - start_us) / 1000.0
				var predicted_ms: float = max(
					float(s.get("avg_cost_ms", 0.0)),
					float(s.get("prediction_floor_ms", 0.05))
				)
				if elapsed_ms + predicted_ms > max(0.0, max_tick_time_ms):
					var emergency_ok: bool = VariantCasts.to_bool(s.get("emergency_override", false)) and emergency_runs < max_emergency_runs_per_tick
					# Starvation guard:
					# 1) Always allow one due system to run each tick.
					# 2) Mark skipped systems for immediate retry on the next tick.
					if executed > 0 and not emergency_ok:
						_skipped_systems_count += 1
						s["force_next_run"] = true
						break
					if emergency_ok:
						emergency_runs += 1
			else:
				if executed >= max(1, max_systems_per_tick):
					budget_exhausted = true
					break
			if "tick" not in s["instance"]:
				s["force_next_run"] = false
				break
			var st_us: int = Time.get_ticks_usec()
			var ret: Variant = s["instance"].tick(dt_for_system, world, gpu_ctx)
			var en_us: int = Time.get_ticks_usec()
			var cost_ms: float = float(en_us - st_us) / 1000.0
			# Update EMA cost
			var prev: float = float(s.get("avg_cost_ms", 0.0))
			var alpha: float = clamp(float(s.get("ema_alpha", _SMOOTH_ALPHA)), 0.05, 0.95)
			s["avg_cost_ms"] = (1.0 - alpha) * prev + alpha * cost_ms
			s["last_tick"] = tick_counter
			if use_time_debt:
				var consumed_days: float = _extract_consumed_days(ret, dt_for_system, use_time_debt)
				var remaining: float = max(0.0, float(s.get("debt_days", 0.0)) - consumed_days)
				s["debt_days"] = remaining
				s["force_next_run"] = remaining > _EPSILON_DAYS
				consumed_this_tick += consumed_days
				# Avoid infinite loops if a system made no progress.
				if consumed_days <= _EPSILON_DAYS:
					s["force_next_run"] = true
					# Ensure other systems still get a chance this tick.
					break
			else:
				s["force_next_run"] = false
			# Collect dirty fields if system reported any
			if typeof(ret) == TYPE_DICTIONARY and ret.has("dirty_fields"):
				var df: PackedStringArray = ret["dirty_fields"]
				for f in df:
					dirty_set[f] = true
			executed += 1
			runs += 1
			if not use_time_debt:
				break
			if runs >= runs_cap:
				break
			# After paying for at least one incoming tick worth of debt, move on for fairness.
			if consumed_this_tick + _EPSILON_DAYS >= dt_incoming:
				break
	_round_robin_start = (_round_robin_start + 1) % max(1, total_systems)
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
	budget_mode_time_ms = VariantCasts.to_bool(on)

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
			"cadence": s.get("cadence", 1),
			"priority": s.get("priority", 0),
			"emergency_override": s.get("emergency_override", false),
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
