# File: res://scripts/core/TimeSystem.gd
extends Node

signal tick(dt_days)

var running: bool = false
var time_scale: float = 0.2  # Slower time progression
var tick_days: float = 1.0 / 1440.0 # 1 minute per tick (much smaller time steps)
var simulation_time_days: float = 0.0
var days_per_year: float = 365.0  # Configurable year length

var _accum_days: float = 0.0
var _timer: Timer

func _ready() -> void:
	# Create a precise timer for 10 FPS simulation ticks
	_timer = Timer.new()
	_timer.wait_time = 0.1  # 10 FPS = 0.1 second intervals
	_timer.timeout.connect(_on_timer_tick)
	add_child(_timer)

func _on_timer_tick() -> void:
	if not running:
		return
	if time_scale <= 0.0 or tick_days <= 0.0:
		return
	
	# Apply time scale to simulation progression
	var scaled_tick_days = tick_days * time_scale
	emit_signal("tick", scaled_tick_days)
	simulation_time_days += scaled_tick_days

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
		emit_signal("tick", tick_days)
		simulation_time_days += tick_days

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
