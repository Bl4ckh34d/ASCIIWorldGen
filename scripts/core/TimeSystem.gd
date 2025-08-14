# File: res://scripts/core/TimeSystem.gd
extends Node

signal tick(dt_days)

var running: bool = false
var time_scale: float = 1.0
var tick_days: float = 1.0 / 120.0 # ~12 minutes per tick
var simulation_time_days: float = 0.0

var _accum_days: float = 0.0

func _process(delta: float) -> void:
	if not running:
		return
	if time_scale <= 0.0 or tick_days <= 0.0:
		return
	_accum_days += delta * time_scale
	while _accum_days >= tick_days:
		emit_signal("tick", tick_days)
		simulation_time_days += tick_days
		_accum_days -= tick_days

func start() -> void:
	running = true

func pause() -> void:
	running = false

func reset() -> void:
	running = false
	simulation_time_days = 0.0
	_accum_days = 0.0

func step_once() -> void:
	# Manual single tick (useful for step button)
	if tick_days > 0.0:
		emit_signal("tick", tick_days)
		simulation_time_days += tick_days

func set_time_scale(v: float) -> void:
	time_scale = max(0.0, v)

func set_tick_days(v: float) -> void:
	tick_days = max(1e-6, v)

func get_year_float() -> float:
	return simulation_time_days / 365.0

func get_day_of_year() -> float:
	return fposmod(simulation_time_days / 365.0, 1.0)

func get_time_of_day() -> float:
	return fposmod(simulation_time_days, 1.0)
