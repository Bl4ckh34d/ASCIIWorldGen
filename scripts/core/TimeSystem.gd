# File: res://scripts/core/TimeSystem.gd
extends Node

signal tick(dt_days)

var running: bool = false
var time_scale: float = 1.0  # Base speed (1x)
var tick_days: float = 1.0 / 1440.0 # 1 minute per tick (much smaller time steps)
var simulation_time_days: float = 0.0
var days_per_year: float = 365.0  # Configurable year length
const MAX_SUBSTEP_DAYS: float = 6.0
const MAX_SUBSTEPS_PER_TIMER_TICK: int = 64
const MAX_ADVANCE_DAYS_PER_TIMER_TICK: float = MAX_SUBSTEP_DAYS * float(MAX_SUBSTEPS_PER_TIMER_TICK)

var _accum_days: float = 0.0
var _timer: Timer

func _ready() -> void:
	# Create a precise timer for 60 FPS simulation ticks
	_timer = Timer.new()
	_timer.wait_time = 1.0 / 60.0
	_timer.timeout.connect(_on_timer_tick)
	add_child(_timer)

func _on_timer_tick() -> void:
	if not running:
		return
	if time_scale <= 0.0 or tick_days <= 0.0:
		return
	
	# Apply time scale to simulation progression
	var scaled_tick_days: float = tick_days * time_scale
	if scaled_tick_days <= 0.0:
		return
	# Preserve integration fidelity by carrying overflow to future timer ticks
	# instead of forcing oversized substeps when speed is extreme.
	_accum_days += scaled_tick_days
	var advance_days: float = min(_accum_days, MAX_ADVANCE_DAYS_PER_TIMER_TICK)
	if advance_days <= 0.0:
		return
	_accum_days = max(0.0, _accum_days - advance_days)
	var substeps: int = max(1, int(ceil(advance_days / max(1e-6, MAX_SUBSTEP_DAYS))))
	substeps = clamp(substeps, 1, MAX_SUBSTEPS_PER_TIMER_TICK)
	var step_days: float = advance_days / float(substeps)
	for _i in range(substeps):
		emit_signal("tick", step_days)
		simulation_time_days += step_days

func _process(_delta: float) -> void:
	# Timer-based system handles all timing - process not needed
	pass

func start() -> void:
	running = true
	if _timer:
		_timer.start()

func pause() -> void:
	running = false
	if _timer:
		_timer.stop()

func reset() -> void:
	running = false
	simulation_time_days = 0.0
	_accum_days = 0.0
	if _timer:
		_timer.stop()

func step_once() -> void:
	# Manual single tick (useful for step button)
	if tick_days > 0.0:
		var advance_days: float = max(0.0, float(tick_days))
		var substeps: int = max(1, int(ceil(advance_days / max(1e-6, MAX_SUBSTEP_DAYS))))
		substeps = clamp(substeps, 1, MAX_SUBSTEPS_PER_TIMER_TICK)
		var step_days: float = advance_days / float(substeps)
		for _i in range(substeps):
			emit_signal("tick", step_days)
			simulation_time_days += step_days

func set_time_scale(v: float) -> void:
	time_scale = max(0.0, v)
	# Timer runs at constant 10 FPS regardless of time_scale
	# Time scale affects simulation progression speed, not tick frequency

func set_tick_days(v: float) -> void:
	tick_days = max(1e-6, v)

func get_year_float() -> float:
	return simulation_time_days / days_per_year

func get_day_of_year() -> float:
	return fposmod(simulation_time_days / days_per_year, 1.0)

func set_days_per_year(v: float) -> void:
	days_per_year = max(1.0, v)

func get_days_per_year() -> float:
	return days_per_year

func get_time_of_day() -> float:
	return fposmod(simulation_time_days, 1.0)

func get_pending_backlog_days() -> float:
	return max(0.0, _accum_days)
