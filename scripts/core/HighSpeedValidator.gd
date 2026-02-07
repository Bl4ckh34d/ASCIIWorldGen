extends RefCounted
class_name HighSpeedValidator

var _last_total_debt_days: float = -1.0
var _last_skipped_systems: int = 0
var _last_sim_days: float = -1.0
var _consecutive_alerts: int = 0

func reset_state() -> void:
	_last_total_debt_days = -1.0
	_last_skipped_systems = 0
	_last_sim_days = -1.0
	_consecutive_alerts = 0

func collect_total_system_debt_days(simulation: Node) -> float:
	var total_debt: float = 0.0
	if simulation and "systems" in simulation:
		for sys_state in simulation.systems:
			total_debt += max(0.0, float(sys_state.get("debt_days", 0.0)))
	return total_debt

func run(
	simulation: Node,
	time_system: Node,
	generator: Object,
	sim_tick_counter: int,
	opts: Dictionary
) -> Dictionary:
	if simulation == null or time_system == null:
		return {}
	var min_scale: float = float(opts.get("min_scale", 1000.0))
	var interval_ticks: int = int(opts.get("interval_ticks", 30))
	var debt_growth_limit_base: float = float(opts.get("debt_growth_limit", 1.2))
	var debt_abs_limit_days: float = float(opts.get("debt_abs_limit_days", 365.0))
	var skip_delta_limit: int = int(opts.get("skip_delta_limit", 120))
	var budget_ratio_limit: float = float(opts.get("budget_ratio_limit", 1.15))
	var progress_ratio_limit: float = float(opts.get("progress_ratio_limit", 0.55))
	var backlog_days_limit: float = float(opts.get("backlog_days_limit", 365.0))
	var warning_interval: int = max(1, int(opts.get("warning_interval", 5)))
	var ts: float = max(1.0, float(time_system.time_scale)) if "time_scale" in time_system else 1.0
	if ts < min_scale:
		reset_state()
		return {}
	if (sim_tick_counter % interval_ticks) != 0:
		return {}
	if not ("get_performance_stats" in simulation):
		return {}
	var stats: Dictionary = simulation.get_performance_stats()
	var total_debt: float = collect_total_system_debt_days(simulation)
	var sim_days_now: float = float(time_system.simulation_time_days) if "simulation_time_days" in time_system else 0.0
	var skipped_now: int = int(stats.get("skipped_systems_count", 0))
	if _last_total_debt_days < 0.0 or _last_sim_days < 0.0:
		_last_total_debt_days = total_debt
		_last_skipped_systems = skipped_now
		_last_sim_days = sim_days_now
		return {}
	var sim_delta: float = max(1e-6, sim_days_now - _last_sim_days)
	var debt_delta: float = max(0.0, total_debt - _last_total_debt_days)
	var skipped_delta: int = max(0, skipped_now - _last_skipped_systems)
	var debt_growth_ratio: float = debt_delta / sim_delta
	var debt_growth_limit: float = _debt_growth_ratio_limit_for_scale(ts, debt_growth_limit_base)
	var avg_tick_ms: float = float(stats.get("avg_tick_time_ms", 0.0))
	var budget_ms: float = max(1e-3, float(stats.get("max_budget_ms", 1.0)))
	var budget_ratio: float = avg_tick_ms / budget_ms
	var expected_delta: float = _sim_days_per_tick_for_scale(ts) * float(interval_ticks)
	var progress_ratio: float = sim_delta / max(1e-6, expected_delta)
	var backlog_days: float = 0.0
	if "get_pending_backlog_days" in time_system:
		backlog_days = max(0.0, float(time_system.get_pending_backlog_days()))
	var numeric_ok: bool = _sample_runtime_numeric_sanity(generator)
	var debt_growth_pressure: bool = (
		total_debt > debt_abs_limit_days
		or budget_ratio > budget_ratio_limit
		or progress_ratio < progress_ratio_limit
		or skipped_delta > int(floor(float(skip_delta_limit) * 0.5))
	)
	var issues: Array = []
	if debt_growth_ratio > debt_growth_limit and debt_growth_pressure:
		issues.append("debt_growth")
	if skipped_delta > skip_delta_limit:
		issues.append("skip_pressure")
	if budget_ratio > budget_ratio_limit:
		issues.append("budget_pressure")
	if progress_ratio < progress_ratio_limit:
		issues.append("time_lag")
	if backlog_days > backlog_days_limit:
		issues.append("time_backlog")
	if not numeric_ok:
		issues.append("numeric")
	var warning_text: String = ""
	if not issues.is_empty():
		_consecutive_alerts += 1
		if _consecutive_alerts == 1 or (_consecutive_alerts % warning_interval) == 0:
			var issues_txt: String = ", ".join(issues)
			warning_text = (
				"High-speed validation @%.0fx: %s | debt=%.2f(+%.2f) sim=%.2f(+%.2f) skip+%d avg=%.2f/%.2fms backlog=%.2f" %
				[ts, issues_txt, total_debt, debt_delta, sim_days_now, sim_delta, skipped_delta, avg_tick_ms, budget_ms, backlog_days]
			)
	else:
		_consecutive_alerts = max(0, _consecutive_alerts - 1)
	_last_total_debt_days = total_debt
	_last_skipped_systems = skipped_now
	_last_sim_days = sim_days_now
	return {
		"warning": warning_text,
		"issues": issues,
		"total_debt": total_debt,
	}

func _sample_runtime_numeric_sanity(generator: Object) -> bool:
	if generator == null:
		return true
	if "last_height" in generator and generator.last_height is PackedFloat32Array:
		if not _sample_finite_f32(generator.last_height, 48):
			return false
	if "last_temperature" in generator and generator.last_temperature is PackedFloat32Array:
		if not _sample_finite_f32(generator.last_temperature, 48):
			return false
	if "last_moisture" in generator and generator.last_moisture is PackedFloat32Array:
		if not _sample_finite_f32(generator.last_moisture, 48):
			return false
	return true

func _sample_finite_f32(values: PackedFloat32Array, samples: int = 32) -> bool:
	var n: int = values.size()
	if n <= 0:
		return true
	var step: int = max(1, int(floor(float(n) / float(max(1, samples)))))
	var idx: int = 0
	var checked: int = 0
	while idx < n and checked < samples:
		var v: float = float(values[idx])
		if is_nan(v) or is_inf(v):
			return false
		idx += step
		checked += 1
	return true

func _debt_growth_ratio_limit_for_scale(time_scale: float, base_limit: float) -> float:
	var ts: float = max(1.0, float(time_scale))
	if ts >= 100000.0:
		return base_limit * 2.2
	if ts >= 10000.0:
		return base_limit * 1.9
	if ts >= 1000.0:
		return base_limit * 1.6
	return base_limit

func _sim_days_per_tick_for_scale(time_scale: float) -> float:
	return max(1.0, float(time_scale)) * (1.0 / 60.0)
