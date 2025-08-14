# File: res://scripts/core/GPUPerformanceMonitor.gd
extends RefCounted

## GPU Performance Monitor for tracking compute timings and enforcing budgets
## Helps maintain target frame rates by monitoring GPU workload

class GPUTimer:
	var start_time: int = 0
	var end_time: int = 0
	var duration_ms: float = 0.0
	var operation_name: String = ""
	
	func start(name: String) -> void:
		operation_name = name
		start_time = Time.get_ticks_usec()
	
	func finish() -> float:
		end_time = Time.get_ticks_usec()
		duration_ms = float(end_time - start_time) / 1000.0
		return duration_ms

var _timers: Dictionary = {}
var _rolling_averages: Dictionary = {}
var _sample_count: int = 10  # Number of samples for rolling average

# Budget settings
var frame_budget_ms: float = 16.0  # 60 FPS target
var tick_budget_ms: float = 8.0   # Half frame budget for simulation
var current_tick_time_ms: float = 0.0

# Performance tracking
var _frame_start_time: int = 0
var _tick_start_time: int = 0

func start_frame() -> void:
	_frame_start_time = Time.get_ticks_usec()

func start_tick() -> void:
	_tick_start_time = Time.get_ticks_usec()
	current_tick_time_ms = 0.0

func finish_tick() -> void:
	var tick_end_time: int = Time.get_ticks_usec()
	current_tick_time_ms = float(tick_end_time - _tick_start_time) / 1000.0
	
	# Update rolling average for tick timing
	_update_rolling_average("tick_total", current_tick_time_ms)

func get_frame_time_ms() -> float:
	if _frame_start_time == 0:
		return 0.0
	var current_time: int = Time.get_ticks_usec()
	return float(current_time - _frame_start_time) / 1000.0

func start_operation(operation_name: String) -> void:
	if not _timers.has(operation_name):
		_timers[operation_name] = GPUTimer.new()
	var timer: GPUTimer = _timers[operation_name]
	timer.start(operation_name)

func finish_operation(operation_name: String) -> float:
	if not _timers.has(operation_name):
		return 0.0
	
	var timer: GPUTimer = _timers[operation_name]
	var duration: float = timer.finish()
	
	# Update rolling average
	_update_rolling_average(operation_name, duration)
	
	# Add to current tick time
	current_tick_time_ms += duration
	
	return duration

func _update_rolling_average(operation_name: String, new_value: float) -> void:
	if not _rolling_averages.has(operation_name):
		_rolling_averages[operation_name] = []
	
	var samples: Array = _rolling_averages[operation_name]
	samples.append(new_value)
	
	# Keep only the most recent samples
	if samples.size() > _sample_count:
		samples.pop_front()

func get_average_time_ms(operation_name: String) -> float:
	if not _rolling_averages.has(operation_name):
		return 0.0
	
	var samples: Array = _rolling_averages[operation_name]
	if samples.is_empty():
		return 0.0
	
	var total: float = 0.0
	for sample in samples:
		total += float(sample)
	
	return total / float(samples.size())

func can_afford_operation(operation_name: String, safety_margin_ms: float = 2.0) -> bool:
	# Check if we have budget remaining for this operation
	var estimated_cost: float = get_average_time_ms(operation_name)
	if estimated_cost == 0.0:
		estimated_cost = 1.0  # Conservative estimate for unknown operations
	
	var remaining_budget: float = tick_budget_ms - current_tick_time_ms - safety_margin_ms
	return estimated_cost <= remaining_budget

func get_budget_usage_ratio() -> float:
	# Return what fraction of the tick budget we've used (0.0 to 1.0+)
	if tick_budget_ms <= 0.0:
		return 0.0
	return current_tick_time_ms / tick_budget_ms

func should_skip_expensive_operations() -> bool:
	# Return true if we should skip expensive operations this tick
	return get_budget_usage_ratio() > 0.7  # Skip when >70% budget used

func adjust_quality_for_performance() -> Dictionary:
	# Return quality adjustments based on current performance
	var usage: float = get_budget_usage_ratio()
	var adjustments: Dictionary = {
		"convergence_threshold_multiplier": 1.0,
		"max_iterations_multiplier": 1.0,
		"roi_threshold_adjustment": 0.0,
		"skip_smoothing": false,
		"reduce_precision": false
	}
	
	if usage > 1.2:  # Significantly over budget
		adjustments["convergence_threshold_multiplier"] = 2.0  # Less precise convergence
		adjustments["max_iterations_multiplier"] = 0.5        # Fewer iterations
		adjustments["roi_threshold_adjustment"] = -0.2        # More aggressive ROI
		adjustments["skip_smoothing"] = true
		adjustments["reduce_precision"] = true
	elif usage > 0.9:  # Approaching budget limit
		adjustments["convergence_threshold_multiplier"] = 1.5
		adjustments["max_iterations_multiplier"] = 0.75
		adjustments["roi_threshold_adjustment"] = -0.1
	
	return adjustments

func get_performance_stats() -> Dictionary:
	var stats: Dictionary = {
		"frame_time_ms": get_frame_time_ms(),
		"tick_time_ms": current_tick_time_ms,
		"budget_usage": get_budget_usage_ratio(),
		"operations": {}
	}
	
	for op_name in _rolling_averages.keys():
		stats["operations"][op_name] = {
			"average_ms": get_average_time_ms(op_name),
			"samples": _rolling_averages[op_name].size()
		}
	
	return stats

func set_target_fps(fps: float) -> void:
	frame_budget_ms = 1000.0 / max(1.0, fps)
	tick_budget_ms = frame_budget_ms * 0.5  # Reserve half frame for simulation

func reset_stats() -> void:
	_rolling_averages.clear()
	current_tick_time_ms = 0.0

func log_performance_summary() -> void:
	var stats: Dictionary = get_performance_stats()
	print("GPU Performance Summary:")
	print("  Frame time: ", "%.2f" % stats["frame_time_ms"], "ms")
	print("  Tick time: ", "%.2f" % stats["tick_time_ms"], "ms") 
	print("  Budget usage: ", "%.1f" % (stats["budget_usage"] * 100.0), "%")
	
	if stats["operations"].size() > 0:
		print("  Operation timings:")
		for op_name in stats["operations"].keys():
			var op_stats: Dictionary = stats["operations"][op_name]
			print("    ", op_name, ": ", "%.2f" % op_stats["average_ms"], "ms (", op_stats["samples"], " samples)")